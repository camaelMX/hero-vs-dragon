extends Node2D
## ============================================================
## combat_scene.gd —— 战斗主场景（灰盒阶段 0-1 的核心）
##
## 本场景验证什么？（GDD/08 开发计划 阶段0 步骤1）
##   1. 速度值排序的经典回合制
##   2. QTE 只属于"主角"：敌人打主角时，按主角的反应预设出判定条
##      - 防御：完美=免伤+反弹 / 普通=减伤50% / 失误=吃满
##      - 闪避：成功=免伤 / 失败=吃满+主角失去下回合
##   3. AI 队友按 party_ai.gd 的最小行为树行动
##
## 玩法：
##   空格 = 防御 QTE    F = 闪避 QTE
##   底部按钮 = 攻击 / 血瓶 / 切换反应预设 / 结束回合
##   胜负后按 R 重开
##
## 自动冒烟测试（不给它焦点也能跑，用来验证逻辑不报错）：
##   AUTOPLAY=1 godot --headless --path .
## ============================================================

## 战斗状态机（灰盒只需要这几个状态；以后加卡牌选择/演出再扩）
enum State { SETUP, RESOLVING, QTE, VICTORY, DEFEAT }

## 玩家点了底部按钮 → 发这个信号；战斗主循环 await 它拿到指令。
## action 是字典，例如 {"type":"attack","target":敌人} / {"type":"potion"} / {"type":"stance_dodge"} / {"type":"end"}
signal player_choice(action: Dictionary)

# ---- 脚本引用（preload 在加载时把脚本文件读进来，相当于"import"）----
const FighterScript := preload("res://scripts/combat/fighter.gd")
const QTERingScript := preload("res://scripts/combat/qte_ring.gd")
const PartyAI := preload("res://scripts/combat/party_ai.gd")
const DB := preload("res://scripts/data/units_db.gd")

## 插画风头像（tools/gen_cg_comfy.py portraits 产出，832x1216 原图缩用）
const PORTRAIT_FILES := {
	"hero": "res://assets/art/portraits/P03_hero.png",
	"priest": "res://assets/art/portraits/P04_priestess.png",
	"mage": "res://assets/art/portraits/P05_mage.png",
	"protag": "res://assets/art/portraits/P01_protag_squire.png",
	# 敌对单位（右上栏）：魔物系 + 第二幕人类系
	"slime": "res://assets/art/portraits/P13_slime_mat.png",
	"goblin": "res://assets/art/portraits/P09_goblin_scout.png",
	"wolf": "res://assets/art/portraits/P10_snow_wolf.png",
	"orc": "res://assets/art/portraits/P11_orc_hunter.png",
	"troll": "res://assets/art/portraits/P12_rage_troll.png",
	"guard": "res://assets/art/portraits/P07_royal_guard.png",
	"dragon": "res://assets/art/portraits/P14_dragon_father.png",
	"soldier": "res://assets/art/portraits/P15_border_soldier.png",
	"officer": "res://assets/art/portraits/P16_officer.png",
	"paladin": "res://assets/art/portraits/P17_holy_paladin.png",
	"inquisitor": "res://assets/art/portraits/P18_inquisitor.png",
	"hero_foe": "res://assets/art/portraits/P03_hero.png",
}

# ---- 参战单位 ----
var party: Array = []          # [勇者, 牧师, 法师, 主角]
var enemies: Array = []        # 灰盒：1 只哥布林
var protag: Node2D = null      # 主角引用（QTE 结算要频繁用到）
var turn_order: Array = []     # 按速度排好的行动序列
var turn_index: int = 0        # 当前轮到谁

# ---- 资源/状态 ----
var potion_count: int = 3
var state: int = State.SETUP
var autoplay := false          # AUTOPLAY=1 冒烟测试模式

# ---- UI 引用（_build_ui 创建）----
var ui_log: Label
var ui_result: Label
var ui_buttons: HBoxContainer
var ui_btn_attack: Button
var ui_btn_potion: Button
var ui_btn_terror: Button   # 魔龙咆哮（仅魔化形态可见，GDD/11）
var ui_btn_defend: Button
var ui_btn_dodge: Button
var ui_btn_end: Button
var ui_btn_retreat: Button
var ui_qte  # QTERing 实例（故意不写类型：静态类型下调用 begin() 会被解析器拦截）
var ui_turn_arrow: Label   # 行动指示箭头（世界坐标，跟着当前行动者）
var _log_lines: Array = []


func _ready() -> void:
	autoplay = OS.get_environment("AUTOPLAY") == "1"
	_register_inputs()
	_build_ui()
	_spawn_units()
	_init_audio()
	# BGM：Boss 战用专属曲（v2 的 Dm-Bb-Gm-A 悲怆进行），普通战用战斗曲
	_start_bgm("bgm_boss" if GameState.pending_battle.get("boss", false) else "bgm_battle")
	state = State.RESOLVING
	# 战斗主循环是协程：整个 while 循环里到处 await（等动画/等玩家/等 QTE），
	# 但引擎其他部分（画面渲染、输入）照常运转——这就是 Godot 的协程玩法。
	_run_battle()


# ============================================================
# 一、回合引擎（战斗主循环）
# ============================================================

func _run_battle() -> void:
	# 遭遇名 = 本场敌人按名字计数（"雪狼×3、哥布林斥候×1"）——编制一目了然
	var counts := {}
	for e in enemies:
		counts[e.display_name] = int(counts.get(e.display_name, 0)) + 1
	var parts := []
	for n in counts:
		parts.append("%s×%d" % [n, counts[n]])
	log_line("—— 遭遇：%s！（我方 %d 人 vs 敌方 %d）——" % ["、".join(parts), party.size(), enemies.size()])
	log_line("空格=防御QTE  F=闪避QTE（只对主角生效）")
	# 龙巢·父王开场（GDD/01「父王」节拍）：金瞳收缩 + 只有主角听懂的呼唤——
	# 玩家在 Boss 战开场就知道"这条龙不对劲"，觉醒时才回过味来
	if GameState.in_run and GameState.pending_battle.get("boss", false) \
			and not GameState.act1_cleared:
		for e in enemies:
			if e.id.begins_with("dragon"):
				log_line("龙睁开了眼。金瞳扫过讨伐队——看到你的一瞬，瞳孔猛地收缩。")
				log_line("整头龙都在发抖。不是恐惧。一个声音贯穿山腹，只有你听懂了：")
				log_line("「……小满？」")
				break
	while true:
		# 1. 每圈先查胜负
		if await _check_end():
			return
		# 2. 取下一个活着的行动者（死人跳过）
		var actor = _next_actor()
		# 行动指示箭头：一眼看清现在轮到谁
		ui_turn_arrow.visible = true
		ui_turn_arrow.position = actor.position + Vector2(-7, actor.arrow_y)
		# 3. 失衡单位（闪避失败）直接跳过一回合
		if actor.is_stunned:
			log_line("%s 失去了平衡，无法行动！" % actor.display_name)
			actor.is_stunned = false
			_advance()
			continue
		# 4. 拿到该单位的动作：玩家手动 / AI 判断
		var action: Dictionary
		if actor.role == "protag" and not autoplay:
			action = await _wait_player_command()
		elif actor.role == "protag":
			await _wait(0.15)
			action = _autoplay_action()
		else:
			await _wait(0.4)
			action = PartyAI.decide(actor, party, enemies)
		# 5. 结算动作。返回 true = 该回合结束，轮到下一个人。
		var ended: bool = await _resolve_action(actor, action)
		if ended:
			_advance()


## 行动序列指针前移（循环队列）
func _advance() -> void:
	var prev: int = turn_index
	turn_index = (turn_index + 1) % turn_order.size()
	# 不灭血脉（GDD/07 第九节）：指针绕回一圈 = 新回合开始，
	# 魔龙自愈 20% 最大生命——碾压行军里连"伤"都不该留下。
	if turn_index == 0 and prev == turn_order.size() - 1 \
			and GameState.demonized and protag != null and protag.is_alive() \
			and protag.hp < protag.max_hp:
		var amount: int = int(protag.max_hp * 0.2)
		protag.heal(amount)
		float_text(protag.position + Vector2(-14, protag.arrow_y + 40),
				"+%d" % amount, Color(0.75, 0.35, 0.9), 20)
		log_line("不灭血脉：黑焰舔过伤口，鳞甲下再无破绽。（+%d）" % amount)


## 跳过死人拿下一个活人。调用前已确保双方都有活人。
func _next_actor():
	while true:
		var f = turn_order[turn_index]
		if f.is_alive():
			return f
		_advance()


## 胜负判定：敌人全灭=胜利；小队全灭=失败。
## 结束时把队伍血量写回 GameState（GDD：胜负都保留伤势），
## 赶路模式下切回村庄/赶路场景。返回 true = 主循环终止。
func _check_end() -> bool:
	if enemies.all(func(e): return not e.is_alive()):
		return await _finish_battle("victory")
	if party.all(func(f): return not f.is_alive()):
		return await _finish_battle("defeat")
	return false


## 战斗收尾：写回状态 → 回赶路场景（或独立测试时原地显示结果）
func _finish_battle(result: String) -> bool:
	state = State.VICTORY if result == "victory" else State.DEFEAT
	if ui_turn_arrow != null:
		ui_turn_arrow.visible = false
	# 血量写回（GDD/05：伤势保留，胜不回血）。
	# 阵亡重整（用户实测 bug 修复 2026-11-07）：倒地的队员以 30% 最大生命
	# "拖着伤体重整"——原版只在战败分支生效，胜利时阵亡者会以 0 血写回，
	# 下一场以尸体状态进场、一路躺到回村（用户实测"下一场生命值为1"）。
	for f in party:
		if f.hp <= 0:
			GameState.party_hp[f.id] = maxi(1, int(f.max_hp * 0.3))
			log_line("%s 拖着伤体归队（HP %d/%d）"
					% [f.display_name, maxi(1, int(f.max_hp * 0.3)), f.max_hp])
		else:
			GameState.party_hp[f.id] = f.hp
	if not GameState.in_run:
		# 独立运行战斗场景（老冒烟测试路径）：原地显示结果
		log_line(">>> 胜利！" if result == "victory" else ">>> 战败……")
		_show_result("胜 利" if result == "victory" else "战 败",
				Color(1.0, 0.9, 0.4) if result == "victory" else Color(0.8, 0.3, 0.3))
		return true
	GameState.last_result = result
	match result:
		"defeat":
			GameState.san = maxf(0.0, GameState.san - 10.0)   # GDD/05：战败 -10（1000 局模拟校准：-20 会让"苟"策略八成心防崩溃，-10 才落进幻觉结局区间）
			log_line(">>> 战败……（SAN -10）")
		"retreat":
			GameState.san = maxf(0.0, GameState.san - 10.0)   # 撤退 -10
			log_line(">>> 撤退了……（SAN -10）")
		_:
			log_line(">>> 胜利！")
	await _wait(0.6)
	get_tree().change_scene_to_file("res://scenes/run/run_scene.tscn")
	return true


# ============================================================
# 二、动作结算
# ============================================================

## 结算一个动作。返回是否结束该单位的回合。
## （"切换反应预设"不消耗回合：设完继续等玩家下一个指令。）
func _resolve_action(actor, action: Dictionary) -> bool:
	match String(action["type"]):
		"attack":
			await _do_attack(actor, action["target"])
			return true
		"aoe":
			# 法师群攻：伤害=攻击力×0.7（跟随等级成长，单体 40 的 7 折基准）
			var aoe_dmg := int(actor.atk * 0.7)
			await actor.lunge_toward(Vector2(800, 380), 0.3)
			for e in enemies:
				if e.is_alive():
					e.take_damage(aoe_dmg)
					float_text(e.position + Vector2(-16, -110), str(aoe_dmg), Color.WHITE)
			play_sfx("se_hit")
			log_line("%s 的火焰风暴席卷全场！（%d 伤害）" % [actor.display_name, aoe_dmg])
			await actor.return_home()
			await _wait(0.15)
			return true
		"heal":
			var t = action["target"]
			t.heal(actor.heal_amount)
			play_sfx("se_heal")
			float_text(t.position + Vector2(-14, -110),
					"+%d" % actor.heal_amount, Color(0.45, 0.9, 0.5), 20)
			log_line("%s 治疗了 %s（+%d）" % [actor.display_name, t.display_name, actor.heal_amount])
			await _wait(0.3)
			return true
		"potion":
			potion_count -= 1
			GameState.blood_potions = potion_count   # 同步回全局库存
			play_sfx("se_heal")
			protag.heal(int(DB.QTE["potion_heal"]))
			log_line("主角喝下血瓶（+%d，剩 %d 瓶）" % [int(DB.QTE["potion_heal"]), potion_count])
			ui_btn_potion.text = "血瓶×%d" % potion_count
			await _wait(0.2)
			return true
		"terror":
			# 魔龙咆哮（GDD/11）：一场战斗一次——声浪过处，非 Boss 敌人
			# 半数当场溃逃，残存者被慑服（攻 -6）；恐惧免疫的 Boss 也要被
			# 震得气血翻涌（攻 -10）。溃逃用死亡淡出表现（灰盒演出复用）。
			protag.set_meta("roared", true)
			play_sfx("se_crit")
			_shake(10.0)
			log_line("魔龙的咆哮碾过雪原——人类的战意在这声音面前不值一提。")
			for e in enemies:
				if not e.is_alive():
					continue
				if e.id.begins_with("hero_foe") or e.id.begins_with("dragon"):
					e.atk = maxi(1, e.atk - 10)
					float_text(e.position + Vector2(-16, -120),
							"慑服 攻-10", Color(1.0, 0.6, 0.2), 18)
					log_line("%s 恐惧免疫，但被震得气血翻涌。（攻 -10）" % e.display_name)
				elif randf() < 0.5:
					log_line("%s 扔下武器，掉头溃逃！" % e.display_name)
					e.take_damage(e.hp)
				else:
					e.atk = maxi(1, e.atk - 6)
					float_text(e.position + Vector2(-16, -120),
							"慑服 攻-6", Color(1.0, 0.6, 0.2), 18)
					log_line("%s 被慑服了，握剑的手在抖。（攻 -6）" % e.display_name)
			await _wait(0.4)
			return true
		"retreat":
			# 撤退：卡作废，SAN -10（GDD/05），立刻离开战斗
			return await _finish_battle("retreat")
		"end":
			return true
	return true


## 一次攻击的完整流程：冲刺演出 → 命中 → 伤害飘字 → 回位
func _do_attack(attacker, target) -> void:
	# —— 魔化分流：魔龙的主攻 = 【灭世魔焰】全屏龙息（GDD/07 第九节）——
	# 无视防御、全图结算、杂兵直接蒸发："秒天秒地秒空气"要的是演出而不是数值刁难
	if attacker.role == "protag" and GameState.demonized:
		await _demon_sweep(attacker)
		return
	# —— 关键分流：敌人打主角 → 走 QTE 反应结算 ——
	if attacker.role == "enemy" and target.role == "protag":
		await _enemy_attack_on_protagonist(attacker)
		return

	# —— 普通结算：AI 互殴 / 主角打敌人，无 QTE（QTE 独属主角，GDD 铁律）——
	# ① 冲刺到目标半路（视觉上"这次是谁打谁"）
	await attacker.lunge_toward(target.position)
	var roll: Dictionary = attacker.roll_attack(target)
	if not bool(roll["hit"]):
		float_text(target.position + Vector2(-16, -110), "MISS", Color(0.7, 0.7, 0.75))
		await attacker.return_home()
		return
	# ② 命中：伤害飘字 + 音效 + 暴击震屏
	target.take_damage(int(roll["dmg"]))
	play_sfx("se_crit" if bool(roll["crit"]) else "se_hit")
	float_text(target.position + Vector2(-16, -110),
			str(int(roll["dmg"])) + ("！暴击" if bool(roll["crit"]) else ""),
			Color(1.0, 0.85, 0.3) if bool(roll["crit"]) else Color.WHITE,
			26 if bool(roll["crit"]) else 18)
	if bool(roll["crit"]):
		_shake(8.0)
	# —— Boss 狂化（GDD/07：60% / 30% 血量两档）——
	# 父王：旧伤迸裂攻+10；勇者：放下矜持攻+8。meta 防同档重复触发
	if GameState.in_run and GameState.pending_battle.get("boss", false) \
			and target.role == "enemy":
		var is_hero_foe: bool = target.id.begins_with("hero_foe")
		var rage_atk: int = 8 if is_hero_foe else 10
		var ratio := float(target.hp) / float(target.max_hp)
		if ratio <= 0.6 and not target.has_meta("rage1"):
			target.set_meta("rage1", true)
			target.atk += rage_atk
			target.speed += 2
			log_line(">>> %s！（攻 +%d）" % [
					"勇者的眼神彻底冷了——他动真格了" if is_hero_foe
					else "恶龙的旧伤迸裂——它狂化了", rage_atk])
		if ratio <= 0.3 and not target.has_meta("rage2"):
			target.set_meta("rage2", true)
			target.atk += rage_atk
			target.speed += 2
			log_line(">>> %s！（攻 +%d）" % [
					"剑锋开始嘶鸣——他想起教团的教诲" if is_hero_foe
					else "龙瞳里只剩血色——狂化再深", rage_atk])
	if bool(roll["crit"]):
		log_line("%s 对 %s 暴击！（%d 伤害）" % [attacker.display_name, target.display_name, int(roll["dmg"])])
	else:
		log_line("%s 攻击 %s（%d 伤害）" % [attacker.display_name, target.display_name, int(roll["dmg"])])
	await _wait(0.1)
	# ③ 回位
	await attacker.return_home()
	await _wait(0.12)


## 灭世魔焰（GDD/07 第九节）：魔龙主攻。全屏龙息，无视防御，
## 非 Boss 编制直接蒸发——碾压行军的"演出优先于数值"。
func _demon_sweep(attacker) -> void:
	await attacker.lunge_toward(Vector2(800, 380), 0.3)
	_shake(10.0)
	play_sfx("se_crit")
	log_line("灭世魔焰吞没了整片雪原——")
	for e in enemies:
		if e.is_alive():
			var dmg: int = attacker.atk   # 无视防御（60/(60+def) 公式在此不适用）
			e.take_damage(dmg)
			float_text(e.position + Vector2(-16, -130),
					"%d！" % dmg, Color(1.0, 0.42, 0.15), 26)
	await attacker.return_home()
	await _wait(0.2)


## 敌人攻击主角：本灰盒的心脏——预警演出 + 两种反应 QTE + 结算演出。
## 敌人攻击主角入口：按攻击段数拆成 QTE 链（审判官 hits=2，GDD/07 多段攻击）
func _enemy_attack_on_protagonist(attacker) -> void:
	var hits: int = maxi(1, attacker.multi_hit)
	if hits > 1:
		log_line("%s 宣读罪状——【审判之链】！" % attacker.display_name)
	for hi in range(hits):
		await _single_hit_on_protagonist(attacker, hi > 0)
	# ④ 预警解除，敌人退回原位（链尾统一回位）
	await attacker.return_home()
	await _wait(0.15)


## 单段攻击：预兆 → QTE → 结算。is_chain=连击后续段（不重新冲刺，就地再起手）
func _single_hit_on_protagonist(attacker, is_chain: bool) -> void:
	# ① 预警演出：敌人冲到主角半路【停住】，攻击者头顶挂大红"！"持续闪烁——
	#    QTE 窗口全程可见（用户 2026-11-07：飘字 0.6 秒就没了，看不清）
	if is_chain:
		await _wait(0.3)
		float_text(protag.position + Vector2(-4, protag.arrow_y + 4), "第二段！",
				Color(1.0, 0.5, 0.2), 20)
	else:
		await attacker.lunge_toward(protag.position, 0.45)
	float_text(protag.position + Vector2(-4, protag.arrow_y + 26), "!",
			Color(1.0, 0.3, 0.2), 32)
	attacker.flash_white()
	play_sfx("se_card_flip")   # 预警音（占位，正式版做成低频警告音）
	var warn := Label.new()
	warn.text = "!"
	warn.add_theme_font_size_override("font_size", 46)
	warn.add_theme_color_override("font_color", Color(1.0, 0.22, 0.16))
	warn.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	warn.add_theme_constant_override("shadow_offset_y", 3)
	warn.position = Vector2(-16, attacker.arrow_y - 46)
	warn.z_index = 60
	attacker.add_child(warn)
	var wt := warn.create_tween()
	wt.set_loops()   # 闪烁到结算完毕 queue_free 为止
	wt.tween_property(warn, "modulate:a", 0.45, 0.16)
	wt.tween_property(warn, "modulate:a", 1.0, 0.16)

	var roll: Dictionary = attacker.roll_attack(protag)
	if not bool(roll["hit"]):
		warn.queue_free()
		log_line("%s 的攻击落空了！" % attacker.display_name)
		float_text(protag.position + Vector2(-16, -110), "MISS", Color(0.7, 0.7, 0.75))
		return
	var raw_dmg := int(roll["dmg"])
	# 父王的"留手"（GDD/07 伏笔 Buff）：龙息对主角减半——
	# 它死也不肯伤他。玩家此时只会觉得"Boss 打人不疼"，觉醒后才恍然大悟。
	if attacker.id.begins_with("dragon"):
		raw_dmg = maxi(1, raw_dmg / 2)
		# GDD/01「父王」节拍：第一次留手把话说破一半——只说现象，不说原因
		if not attacker.has_meta("mercy_logged"):
			attacker.set_meta("mercy_logged", true)
			log_line("龙息贴着你的甲缘滑了过去——拼了命地避开要害。它死也不肯伤你。")

	# ② QTE 判定条登场（条上方有键位提示）
	state = State.QTE
	log_line("%s 扑向主角！" % attacker.display_name)
	var mode := QTERingScript.Mode.DODGE \
			if protag.pending_stance == "dodge" else QTERingScript.Mode.DEFEND
	var grade: int = await ui_qte.begin(mode)
	state = State.RESOLVING
	await _wait(0.15)   # 让"完美防御！"弹出字停一拍再结算

	# ③ 结算演出
	if protag.pending_stance == "dodge":
		if grade == QTERingScript.Grade.PERFECT:
			play_sfx("se_dodge")
			float_text(protag.position + Vector2(-16, -110), "回避！", Color(0.5, 0.9, 1.0), 24)
			# 闪避反击（2026-11-07 实测定稿）：成功=完全回避+立即反击，
			# 攻击力×1.2 无视防御——没有它闪避被完美防御全面压制（用户实测）
			var counter := int(protag.atk * float(DB.QTE["dodge_counter_mult"]))
			attacker.take_damage(counter)
			float_text(attacker.position + Vector2(-16, -120),
					"反击 %d" % counter, Color(0.5, 0.9, 1.0), 22)
			log_line(">>> 闪避成功！完全回避，顺势反击 %d 伤害。" % counter)
		else:
			play_sfx("se_dodge_fail")
			protag.take_damage(raw_dmg)
			_shake(7.0)
			float_text(protag.position + Vector2(-16, -110), str(raw_dmg), Color(1.0, 0.3, 0.2), 22)
			float_text(protag.position + Vector2(-16, -140), "失衡！", Color(1.0, 0.5, 0.2), 18)
			log_line(">>> 闪避失败！吃满 %d 伤害，且失去下回合行动。" % raw_dmg)
			protag.is_stunned = true   # 下一轮 _run_battle 会跳过主角
	else:
		match grade:
			QTERingScript.Grade.PERFECT:
				play_sfx("se_perfect_defend")
				var counter := int(protag.def * float(DB.QTE["counter_mult"]))
				_shake(9.0)
				float_text(protag.position + Vector2(-16, -110), "完美！", Color(1.0, 0.85, 0.3), 26)
				attacker.take_damage(counter)
				float_text(attacker.position + Vector2(-16, -120),
						"反弹 %d" % counter, Color(1.0, 0.85, 0.3), 22)
				log_line(">>> 完美防御！免伤，并反弹 %d 伤害。" % counter)
			QTERingScript.Grade.GOOD:
				play_sfx("se_normal_defend")
				protag.take_damage(raw_dmg / 2)
				float_text(protag.position + Vector2(-16, -110),
						str(raw_dmg / 2), Color(0.9, 0.6, 0.4), 18)
				log_line(">>> 普通防御。伤害减半（-%d）。" % (raw_dmg / 2))
			_:
				play_sfx("se_hit")
				protag.take_damage(raw_dmg)
				_shake(7.0)
				float_text(protag.position + Vector2(-16, -110),
						str(raw_dmg), Color(1.0, 0.3, 0.2), 22)
				log_line(">>> 防御失误！吃满 %d 伤害。" % raw_dmg)

	# ④ 预警解除（回位由链包装器统一处理）
	warn.queue_free()


# ============================================================
# 三、玩家指令 / AI 自动打（冒烟测试）
# ============================================================

## 打开按钮面板，等玩家点出"非切换预设"的指令。
## 切预设的按钮点了不消耗回合：设完状态后继续 await 下一次点击。
func _wait_player_command() -> Dictionary:
	ui_buttons.visible = true
	_refresh_stance_buttons()
	# 魔化形态的技能组分流（GDD/11）：普攻按钮即灭世魔焰，
	# 露出魔龙咆哮；血瓶/反应预设对 2400 血+每回合自愈的魔龙没有意义。
	if GameState.demonized:
		ui_btn_attack.text = "灭世魔焰"
		ui_btn_terror.visible = true
		ui_btn_terror.disabled = protag.has_meta("roared")
		ui_btn_potion.visible = false
		ui_btn_defend.visible = false
		ui_btn_dodge.visible = false
	else:
		ui_btn_attack.text = "攻击"
		ui_btn_terror.visible = false
		ui_btn_potion.visible = true
		ui_btn_defend.visible = true
		ui_btn_dodge.visible = true
	while true:
		var a: Dictionary = await player_choice
		var t := String(a["type"])
		if t == "stance_defend" or t == "stance_dodge":
			protag.pending_stance = "defend" if t == "stance_defend" else "dodge"
			log_line("反应预设 → %s（不消耗回合）" % ("防御" if t == "stance_defend" else "闪避"))
			_refresh_stance_buttons()
			continue
		ui_buttons.visible = false
		return a
	return {"type": "end"}  # 不可达，安抚类型检查


## 冒烟测试的"虚拟玩家"：随机决策，让战斗能自动打完。
func _autoplay_action() -> Dictionary:
	var r := randf()
	# 魔化形态：首回合必吼（一场一次的咆哮技能，自动测试确定性覆盖）
	if GameState.demonized and not protag.has_meta("roared"):
		return {"type": "terror"}
	if potion_count > 0 and protag.hp < protag.max_hp * 0.4 and r < 0.25:
		return {"type": "potion"}
	if r < 0.12:
		protag.pending_stance = "dodge" if randf() < 0.5 else "defend"
	return {"type": "attack", "target": _first_alive_enemy()}


func _first_alive_enemy():
	for e in enemies:
		if e.is_alive():
			return e
	return null


# ============================================================
# 四、搭建：输入映射 / UI / 单位
# ============================================================

## 键位注册：写代码注册而不是在 project.godot 里写序列化事件，
## 少一处容易手写出错的文本格式。
func _register_inputs() -> void:
	_ensure_action("qte_defend", KEY_SPACE)
	_ensure_action("qte_dodge", KEY_F)
	_ensure_action("restart", KEY_R)


func _ensure_action(action_name: String, key: Key) -> void:
	if InputMap.has_action(action_name):
		return
	InputMap.add_action(action_name)
	var ev := InputEventKey.new()
	ev.keycode = key
	InputMap.action_add_event(action_name, ev)


func _spawn_units() -> void:
	# 战斗背景：Boss 战用龙巢；否则按步骤段切换林地/雪线；独立运行退回林地。
	var bg_path := "res://assets/art/bg/bg_forest.png"
	if GameState.in_run and GameState.pending_battle.get("boss", false):
		bg_path = "res://assets/art/bg/bg_lair.png"
	elif GameState.in_run:
		# 前 3 步林地，第 4 步起进雪线一路走到龙巢（越走越冷，不再切回林地）
		var bg_idx: int = 0 if GameState.step <= 3 else 1
		bg_path = ["res://assets/art/bg/bg_forest.png", "res://assets/art/bg/bg_snow.png"][bg_idx]
	var bg := Sprite2D.new()
	bg.texture = load(bg_path)
	bg.centered = false
	# 等比放大铺满 1280x720（取较大缩放比 = COVERED，插画/像素图通吃）
	if bg.texture != null:
		var s: float = maxf(1280.0 / bg.texture.get_width(),
				720.0 / bg.texture.get_height())
		bg.scale = Vector2(s, s)
	else:
		bg.scale = Vector2(2, 2)
	add_child(bg)
	# 全屏轻压暗：插画背景上保证单位/文字可读
	var combat_dim := ColorRect.new()
	combat_dim.color = Color(0, 0, 0, 0.22)
	combat_dim.size = Vector2(1280, 720)
	combat_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(combat_dim)

	# 我方（左列）。升级成长/宝物/安抚代价都在这里结算：
	#   每级 = +18HP +4攻 +3防（模板自动成长，GDD/08）
	#   宝物（灰盒占位）= 主角直接 +攻/防
	#   安抚代价 = 主角最大生命 -5/次
	var lv: int = GameState.level if GameState.in_run else 1
	# 站位 2026-11-07 重排：原 mage(515)/protag 行压在战斗日志区（y≥430）上，
	# 三人队时主角输出全被日志盖住（QA 实测高优）。全列上移，给左下日志让位。
	# 第二幕·回程（用户定稿）：主角一个人往回打——勇者要处决他、
	# 法师放走了他、牧师死了。队友全部缺席。
	var layout := [
		["hero", Vector2(165, 240), Color(0.95, 0.8, 0.3), 1.6],
		["priest", Vector2(165, 360), Color(0.92, 0.92, 0.98), 1.6],
		["mage", Vector2(165, 480), Color(0.6, 0.4, 0.9), 1.6],
		["protag", Vector2(315, 360), Color(0.3, 0.55, 0.95), 1.6],
	]
	for item in layout:
		if GameState.act1_cleared and item[0] in ["hero", "mage"]:
			continue
		# 牧师已在龙巢陨落（GDD/01）：之后的战斗她不在队伍里
		if item[0] == "priest" and GameState.priest_dead:
			continue
		var uid: String = item[0]
		var f = FighterScript.new()
		# 魔化形态（GDD/07 第九节，用户 2026-11-07 定稿）：第二幕 SAN 归零后
		# 主角直接化身魔龙——贴图换 AI 插画魔龙（512px 绿幕抠图）、体型 Boss 级
		# （512 × 0.9 ≈ 460px 屏宽，略大于父王的 160×2.2=352px）。
		var is_demon: bool = uid == "protag" and GameState.demonized
		var tex_path := "res://assets/art/sprites/unit_demon_dragon.png" if is_demon \
				else "res://assets/art/sprites/unit_%s.png" % uid
		var body_scale: float = 0.9 if is_demon else float(item[3])
		f.setup(uid, DB.UNITS[uid], item[1], item[2], tex_path, body_scale)
		for i in range(lv - 1):
			# 主角每级 +22HP（其余 +18）——魔王血脉伏笔：他愈合得比谁都快。
			# 正式版配合剧情文案点破；灰盒只体现数值。
			f.max_hp += 22 if uid == "protag" else 18
			f.atk += 4
			f.def += 3
		if uid == "protag":
			f.max_hp = GameState.protag_max_hp(f.max_hp)
			f.atk += GameState.gear_atk if GameState.in_run else 0
			f.def += GameState.gear_def if GameState.in_run else 0
			# 低 SAN 命中惩罚（GDD/05：<50 -10%，<25 追加 -20%）
			if GameState.in_run:
				if GameState.san < 25.0:
					f.hit_chance -= 0.30
				elif GameState.san < 50.0:
					f.hit_chance -= 0.10
			# 魔化整体替换数值（在所有加减之后覆盖——人类形态的养成已无意义，
			# 龙的身体不需要坠饰和臂甲）：数值全部取 units_db "demon_dragon"
			if is_demon:
				var dd: Dictionary = DB.UNITS["demon_dragon"]
				f.max_hp = int(dd["max_hp"])
				f.hp = f.max_hp
				f.atk = int(dd["atk"])
				f.def = int(dd["def"])
				f.speed = int(dd["speed"])
				f.crit_chance = float(dd["crit"])
				f.hit_chance = float(dd["hit"])
				f.display_name = String(dd["name"])
				f.arrow_y = -310.0   # Boss 级体型 → 箭头悬停高度对齐恶龙
		# 战斗间血量保留（GDD：胜利不回血，教会才回）
		if GameState.in_run and GameState.party_hp.has(uid):
			f.hp = clampi(int(GameState.party_hp[uid]), 0, f.max_hp)
		f.hp_changed.connect(func(u): u._refresh_bar())
		f.died.connect(func(_u): play_sfx("se_faint"))
		add_child(f)
		# 头像栏（左上）：插画风头像 64x64 一字排开，阵亡变灰
		# 魔化时头像换 P19_protag_dragon（用户 2026-11-07 定稿：龙化后的主角）
		var p_path: String = PORTRAIT_FILES.get(uid, "")
		if uid == "protag" and GameState.demonized:
			p_path = "res://assets/art/portraits/P19_protag_dragon.png"
		if p_path != "" and ResourceLoader.exists(p_path):
			var pr := TextureRect.new()
			pr.texture = load(p_path)
			pr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			pr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
			pr.size = Vector2(64, 64)
			pr.position = Vector2(28 + party.size() * 72, 52)
			pr.tooltip_text = f.display_name
			add_child(pr)
			f.died.connect(func(_u): pr.modulate = Color(0.35, 0.35, 0.35))
		party.append(f)
		if uid == "protag":
			protag = f

	# 敌方（右侧）：从 GameState 读当前卡；独立跑战斗场景时退回单只哥布林。
	# 编制优先用混合 "group"（4v1 动作经济修正），旧字段 unit/count 兜底。
	var portrait_map := {}   # uid_e -> 已创建的右上头像（同型共享一个格）
	var card: Dictionary = GameState.pending_battle if GameState.in_run else {}
	var unit_ids: Array = []
	if card.has("group") and (card["group"] as Array).size() > 0:
		unit_ids = card["group"]
	else:
		var unit_id0: String = String(card.get("unit", "goblin"))
		var count: int = int(card.get("count", 1))
		if OS.get_environment("SMOKE_QTE") == "1":
			count = 1  # 测试钩子仍生效
		for i in range(count):
			unit_ids.append(unit_id0)
	var spots := _enemy_spots(unit_ids.size())
	for i in range(unit_ids.size()):
		var uid_e: String = String(unit_ids[i])
		var g = FighterScript.new()
		# Boss 龙用大尺寸贴图（AI 插画魔龙同款管线：绿幕抠图 512px，面朝左对我方）
		var scale := 1.6
		if uid_e == "dragon":
			scale = 0.8   # 512 × 0.8 ≈ 410px 屏宽，Boss 级体型（旧像素剪影 160×2.2=352px）
		elif uid_e in ["troll", "guard", "hero_foe"]:
			scale = 2.0
		# 箭头悬停高度随体型（龙最大）
		g.arrow_y = -310.0 if uid_e == "dragon" else (-170.0 if scale > 1.8 else -140.0)
		g.setup("%s_%d" % [uid_e, i], DB.UNITS[uid_e], spots[i],
				Color(0.35, 0.7, 0.3), "res://assets/art/sprites/unit_%s.png" % uid_e,
				scale)
		g.role = "enemy"   # 全体敌方统一 role（含 hero_foe——勇者的 AI 也走敌方分支）
		# 勇者镜像成长（用户定稿"成长要高"）：+20HP/+4攻/+2防 ×等级（队伍 +18/+4/+3）。
		# 实测校准：首版 +30/+5/+3 三维全面压制主角=中手法 0/4 必死（6 秒倒）；
		# 现版让 QTE 反弹成为胜负手——中手法 ~6 成胜率，手残打不过（终局设计）
		if GameState.in_run and uid_e == "hero_foe":
			for gi in range(lv - 1):
				g.max_hp += 20
				g.atk += 3
				g.def += 2
			g.hp = g.max_hp
		g.hp_changed.connect(func(u): u._refresh_bar())
		g.died.connect(func(_u): play_sfx("se_faint"))
		# 敌人阵亡：原地停留半拍 → 整体淡出（灰化姿态留在场上太脏，QA 反馈）
		g.died.connect(func(u: Fighter) -> void:
			var tw: Tween = u.create_tween()
			tw.tween_interval(0.5)
			tw.tween_property(u, "modulate:a", 0.0, 0.9))
		add_child(g)
		# 敌方头像栏（右上，与队伍左上对称）：多只同型只画一个，死亡变灰
		var e_path: String = PORTRAIT_FILES.get(uid_e, "")
		var pr_slot: TextureRect = null
		if e_path != "" and ResourceLoader.exists(e_path) and not portrait_map.has(uid_e):
			pr_slot = TextureRect.new()
			pr_slot.texture = load(e_path)
			pr_slot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			pr_slot.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
			pr_slot.size = Vector2(64, 64)
			pr_slot.position = Vector2(1280 - 28 - 64 - portrait_map.size() * 72, 52)
			pr_slot.tooltip_text = g.display_name
			add_child(pr_slot)
			portrait_map[uid_e] = pr_slot
		if pr_slot != null:
			g.died.connect(func(_u): pr_slot.modulate = Color(0.35, 0.35, 0.35))
		enemies.append(g)

	# 调试钩子：SMOKE_QTE=1 时把第一只敌人加厚，确保 QTE 分支被测到
	if OS.get_environment("SMOKE_QTE") == "1" and enemies.size() > 0:
		enemies[0].max_hp = 600
		enemies[0].hp = 600

	# 调试钩子：SMOKE_BOSS_HP=1 把敌人压到 1 血——冒烟测试快速通关龙巢，
	# 验证真相时刻/觉醒线演出（AUTOPLAY 虚拟 QTE 画像打不过真 Boss）
	if OS.get_environment("SMOKE_BOSS_HP") == "1":
		for e in enemies:
			e.max_hp = 1
			e.hp = 1

	# 调试钩子：FORCE_LOSS=1 让全队仅首战以 1 血进场——
	# 用于验证"战败 → 30% 重整 → 重试不再开局暴毙"链路（只生效一次，
	# 之后读 party_hp，否则钩子会覆盖重整结果导致测不出来）
	if OS.get_environment("FORCE_LOSS") == "1" and GameState.party_hp.is_empty():
		for f in party:
			f.hp = 1

	# 灰盒血瓶：战斗内数量与全局库存同步
	if GameState.in_run:
		potion_count = GameState.blood_potions
		ui_btn_potion.text = "血瓶×%d" % potion_count

	# 行动指示箭头（世界坐标节点：位置在 _run_battle 里跟随当前行动者）
	ui_turn_arrow = Label.new()
	ui_turn_arrow.text = "▼"
	ui_turn_arrow.modulate = Color(1.0, 0.85, 0.3)
	ui_turn_arrow.add_theme_font_size_override("font_size", 22)
	ui_turn_arrow.visible = false
	add_child(ui_turn_arrow)

	# 行动序列：按速度值从大到小（GDD/04：速度序，无 ATB）
	turn_order = party.duplicate()
	turn_order.append_array(enemies)
	turn_order.sort_custom(func(a, b): return a.speed > b.speed)
	# Boss 动作经济补偿：龙每轮额外行动一次（追加在回合末）。
	# 否则 1 v 4 它一轮只动一下，四个队员集火它毫无还手之力。
	if GameState.pending_battle.get("boss", false):
		for u in enemies:
			if u.id.begins_with("dragon"):
				turn_order.append(u)


## 敌人站位：1~4 只的阵型（第 4 档留扩展位）
func _enemy_spots(count: int) -> Array:
	match count:
		1: return [Vector2(950, 400)]
		2: return [Vector2(920, 330), Vector2(990, 480)]
		3: return [Vector2(880, 290), Vector2(970, 410), Vector2(880, 530)]
		_: return [Vector2(900, 260), Vector2(990, 360), Vector2(900, 460), Vector2(990, 560)]


## 伤害/治疗/判定飘字：向上漂移并淡出（打击感的最低配但最有效方案）
func float_text(pos: Vector2, s: String, col: Color, font_size := 18) -> void:
	var l := Label.new()
	l.text = s
	l.position = pos + Vector2(randf_range(-14.0, 14.0), 0)
	l.modulate = col
	l.add_theme_font_size_override("font_size", font_size)
	l.z_index = 50
	add_child(l)
	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(l, "position:y", l.position.y - 46.0, 0.65)
	t.tween_property(l, "modulate:a", 0.0, 0.65).set_delay(0.18)
	t.chain().tween_callback(l.queue_free)


## 屏幕震动：抖动场景根节点（CanvasLayer 上的 UI 不受影响，正好）
func _shake(strength := 6.0) -> void:
	var t := create_tween()
	for i in range(4):
		t.tween_property(self, "position",
				Vector2(randf_range(-strength, strength), randf_range(-strength, strength)),
				0.04)
	t.tween_property(self, "position", Vector2.ZERO, 0.05)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	# 标题：遭遇名（剧情战标出地点，普通战标出步骤；第二幕用"回程"）
	var title := Label.new()
	if GameState.pending_battle.get("act2", false):
		title.text = "处刑台 · %s" % String(GameState.pending_battle.get("name", "勇者"))
	elif GameState.pending_battle.get("boss", false):
		title.text = "龙巢 · %s" % String(GameState.pending_battle.get("name", "恶龙"))
	elif GameState.in_run and GameState.act1_cleared:
		title.text = "回程 · 第 %d/8 步 · %s" % [GameState.step,
				String(GameState.pending_battle.get("name", "遭遇战"))]
	elif GameState.in_run:
		title.text = "第 %d 轮 · 第 %d/8 步 · %s" % [GameState.loop, GameState.step,
				String(GameState.pending_battle.get("name", "遭遇战"))]
	else:
		title.text = "遭遇战"
	title.position = Vector2(24, 16)
	title.add_theme_font_size_override("font_size", 20)
	layer.add_child(title)

	# 战斗日志（左下，收窄让开队伍站位；8 行上限见 log_line）
	ui_log = Label.new()
	ui_log.position = Vector2(24, 545)
	ui_log.size = Vector2(520, 165)
	ui_log.add_theme_font_size_override("font_size", 13)
	layer.add_child(ui_log)

	# 大字结果（胜利/战败）
	ui_result = Label.new()
	ui_result.position = Vector2(520, 140)
	ui_result.size = Vector2(240, 80)
	ui_result.add_theme_font_size_override("font_size", 40)
	ui_result.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ui_result.visible = false
	layer.add_child(ui_result)

	# QTE 判定条（屏幕中央偏下；begin() 时显示由内部管理）
	ui_qte = QTERingScript.new()
	ui_qte.position = Vector2(340, 300)
	ui_qte.visible = false
	layer.add_child(ui_qte)

	# 底部按钮排（右移：左下角让给战斗日志）
	ui_buttons = HBoxContainer.new()
	ui_buttons.position = Vector2(620, 652)
	ui_buttons.add_theme_constant_override("separation", 10)
	layer.add_child(ui_buttons)

	ui_btn_attack = _make_button("攻击")
	ui_btn_attack.pressed.connect(func():
		player_choice.emit({"type": "attack", "target": _first_alive_enemy()}))
	ui_btn_potion = _make_button("血瓶×%d" % potion_count)
	ui_btn_potion.pressed.connect(func():
		if potion_count > 0:
			player_choice.emit({"type": "potion"}))
	ui_btn_terror = _make_button("魔龙咆哮")
	ui_btn_terror.visible = false   # 仅魔化形态（_wait_player_command 里露出）
	ui_btn_terror.pressed.connect(func():
		if protag != null and not protag.has_meta("roared"):
			player_choice.emit({"type": "terror"}))
	ui_btn_defend = _make_button("反应:防御")
	ui_btn_defend.pressed.connect(func(): player_choice.emit({"type": "stance_defend"}))
	ui_btn_dodge = _make_button("反应:闪避")
	ui_btn_dodge.pressed.connect(func(): player_choice.emit({"type": "stance_dodge"}))
	ui_btn_end = _make_button("结束回合")
	ui_btn_end.pressed.connect(func(): player_choice.emit({"type": "end"}))
	ui_btn_retreat = _make_button("撤退")
	ui_btn_retreat.pressed.connect(func(): player_choice.emit({"type": "retreat"}))

	ui_buttons.visible = false  # 轮到主角时才显示


func _make_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(96, 40)
	b.pressed.connect(func(): play_sfx("se_ui_click"))
	ui_buttons.add_child(b)
	return b


## 反应预设按钮高亮当前选择（切换预设不耗回合，所以要即时刷新）
func _refresh_stance_buttons() -> void:
	if protag == null:
		return
	var defending: bool = protag.pending_stance == "defend"
	ui_btn_defend.modulate = Color.WHITE if defending else Color(0.5, 0.5, 0.5)
	ui_btn_dodge.modulate = Color(0.5, 0.5, 0.5) if defending else Color.WHITE


# ============================================================
# 五、音频（占位资产：tools/gen_audio.py 程序化生成）
# ============================================================

var _sfx_pool: Array = []     # 6 个轮换播放器：同一帧多个音效不互抢
var _sfx_cache := {}          # 名字 -> AudioStream，只 load 一次
var _bgm: AudioStreamPlayer


func _init_audio() -> void:
	for i in 6:
		var p := AudioStreamPlayer.new()
		p.volume_db = -6.0
		add_child(p)
		_sfx_pool.append(p)
	_bgm = AudioStreamPlayer.new()
	_bgm.volume_db = -10.0
	add_child(_bgm)
	# WAV/OGG 默认不循环：播完一遍 finished 信号再从头播 = 手动无缝循环
	_bgm.finished.connect(_bgm.play)
	# 低 SAN 心跳循环（GDD/05 演出：SAN<50 时全程伴随）
	if GameState.in_run and GameState.san < 50.0:
		var hb := AudioStreamPlayer.new()
		hb.stream = load("res://assets/audio/sfx/se_heartbeat.wav")
		hb.volume_db = -4.0
		add_child(hb)
		hb.finished.connect(hb.play)
		hb.play()


## 按名字播音效（缺文件时静默跳过，不崩游戏）
func play_sfx(sfx_name: String) -> void:
	if not _sfx_cache.has(sfx_name):
		_sfx_cache[sfx_name] = load("res://assets/audio/sfx/%s.wav" % sfx_name)
	var stream: AudioStream = _sfx_cache[sfx_name]
	if stream == null:
		return
	for p in _sfx_pool:
		if not p.playing:
			p.stream = stream
			p.play()
			return


func _start_bgm(track: String) -> void:
	var stream: AudioStream = load("res://assets/audio/bgm/%s.ogg" % track)
	if stream == null:
		return
	_bgm.stream = stream
	_bgm.play()


# ============================================================
# 六、杂项：日志 / 计时 / 结束画面
# ============================================================

func log_line(s: String) -> void:
	_log_lines.append(s)
	if _log_lines.size() > 8:
		_log_lines.pop_front()   # 日志框只有 8 行高，防止文字溢出压到别的 UI
	ui_log.text = "\n".join(_log_lines)
	print(s)  # 同步打到终端，冒烟测试看这里


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _show_result(text: String, col: Color) -> void:
	ui_result.text = text
	ui_result.modulate = col
	ui_result.visible = true
	if autoplay:
		# 冒烟测试：打完自动退出进程，方便脚本判卷
		await _wait(0.8)
		get_tree().quit()


## 开发者快捷键（快速体验用，正式版删除）：F9 = 全体敌人秒杀清场
func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo \
			and ev.keycode == KEY_F9:
		for e in enemies:
			if e.is_alive():
				e.take_damage(e.hp)
		log_line("【DEV】清场。")


## 胜负后按 R 重开整场（重载当前场景 = 一切复位）。
## 仅独立试跑战斗场景时可用；赶路中的战斗胜负后 0.6 秒即自动切回村庄，
## 这窗口里按 R 会和场景切换赛跑，直接禁掉。
func _process(_delta: float) -> void:
	if (state == State.VICTORY or state == State.DEFEAT) and not GameState.in_run:
		if Input.is_action_just_pressed("restart"):
			get_tree().reload_current_scene()
