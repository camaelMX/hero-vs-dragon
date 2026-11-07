extends Node2D
## ============================================================
## run_scene.gd —— 村庄 → 赶路 循环场景（灰盒 0-2 核心）
##
## 流程（GDD/06 怪卡系统 + GDD/05 SAN 经济）：
##   [村庄] 教会免费回满 → 设挑战等级(祈祷/猎杀/血誓)
##          → 买定神香 / 牧师安抚(SAN+15, 永久-5最大HP)
##   → [赶路] 每步三选一怪卡 → 进战斗场景（combat_scene）
##   → 战斗结束写回 GameState → 本场景 _ready 里结算奖励/战败
##   → 8 步铺满回到村庄 → 下一轮
##
## 注意：本场景每次战斗后会被重新加载（change_scene 回来），
## 所以全部 UI 在 _ready 里按 GameState.phase 重建——事件驱动，
## 不存在跨场景存活的协程。
## ============================================================

const CardsDB := preload("res://scripts/data/cards_db.gd")

# ---- UI 引用 ----
var ui_title: Label
var ui_san_fill: ColorRect
var ui_san_text: Label
var ui_res: Label          # 金币/物品/等级一行
var ui_road: Array = []    # 8 个路格 TextureRect
var ui_panel: Control      # 阶段面板（每阶段重建）
var ui_log: Label
var _log_lines: Array = []
var _bgm: AudioStreamPlayer
var _heartbeat: AudioStreamPlayer
var autoplay := false
var ui_debug: Control = null   # 开发者面板（F9 呼出，快速体验用）

# 旋钮档位名（提案，待定稿：GDD 待定项）
const DIAL_NAMES := {1: "祈祷", 2: "猎杀", 3: "血誓"}


func _ready() -> void:
	autoplay = OS.get_environment("AUTOPLAY") == "1"
	_build_static_ui()
	_process_battle_result()   # 从战斗场景回来时先结算
	_build_phase_panel()
	_start_bgm()
	_update_road()
	_refresh_status()
	_update_heartbeat()
	if autoplay:
		_autoplay_step()


# ============================================================
# 一、战斗结果结算（victory / defeat / retreat）
# ============================================================

func _process_battle_result() -> void:
	if not GameState.in_run or GameState.last_result == "":
		return
	var result := GameState.last_result
	GameState.last_result = ""
	var card: Dictionary = GameState.pending_battle
	match result:
		"victory":
			if card.has("act2"):
				# 处刑台·勇者战胜利 → 按 SAN 分流（用户定稿 2026-11-07：真结局只看 SAN）：
				#   SAN = 100（第二幕一滴没扣 = 一路全释放、零审判零追杀）→ 真结局《不染雪》
				#   SAN < 100（杀孽沾过手）→ 复仇线「第二幕·完」
				# 第二幕 SAN 只减不增、起点恰为 100，故 == 100 等价于零杀。
				GameState.phase = "act2_true" if GameState.san >= 100.0 else "act2_end"
			elif card.has("boss"):
				# 父王战胜利 → 真相时刻（不走奖励结算，GDD/01 龙巢章节）
				GameState.phase = "truth"
				GameState.truth_beat = 0
			else:
				_apply_victory(card)
				GameState.pending_battle = {}
		"defeat":
			# SAN -10 已在战斗侧扣过。pending_battle 保留：战败面板"原地重试"要用
			# SAN 归零（第一幕）= 提前坍缩 → 幻觉结局（GDD/05；1000 局模拟裁定：
			# "苟"的下场是活在循环里，而非中途心防崩溃）
			if GameState.pending_battle.has("act2") and GameState.pending_battle.has("boss"):
				# 处刑台战败 = 直接终局（用户定稿 2026-11-07：最终站没有第二次）
				GameState.phase = "act2_fail"
			elif GameState.act1_cleared:
				# 第二幕普通战败：SAN 归零不结算，直接化身魔龙（GDD/07 第九节）
				GameState.demonize_resume = "journey"
				if _enter_demonize():
					return
				GameState.phase = "defeat"
			elif GameState.san <= 0.0:
				GameState.phase = "collapse"
			else:
				GameState.phase = "defeat"
		"retreat":
			# 撤退：SAN -10 已扣。普通卡作废、路格留空、前进一步；
			# Boss 战撤退不能"前进一步"（路已铺满，step 已 >8）→ 退回村庄整备，
			# 龙巢之门保持开启（boss_pending 不清，出发直达山门）。
			if GameState.pending_battle.has("boss"):
				GameState.phase = "village"
				log_line("从龙巢撤了出来。山门的黑石还映在眼底——门，还开着。")
			else:
				_advance_step(true)
			GameState.pending_battle = {}
			# 第二幕撤退也可能把 SAN 退到 0 → 魔化（GDD/05：恢复手段=无）
			if GameState.act1_cleared:
				GameState.demonize_resume = GameState.phase if GameState.phase in ["journey", "act2_finale"] else "village"
				_enter_demonize()


func _apply_victory(card: Dictionary) -> void:
	play_sfx("se_card_stomp")
	var idx: int = GameState.step - 1
	if idx >= 0 and idx < 8:
		GameState.road[idx] = String(card.get("id", "?"))
	# 第二幕·回程（GDD/05 第三节）：经验来自"击败"，与杀不杀无关；
	# 杀不杀是胜利后战场抉择（审判/释放）的事，金币不再掉落——
	# "金币无用本身就是叙事"（GDD/05：你杀光了所有愿意跟你交易的人）
	if GameState.act1_cleared:
		var ups2: Array = GameState.add_exp(int(card.get("exp", 0)))
		log_line("击溃 %s：+%d 经验" % [card.get("name", "?"), int(card.get("exp", 0))])
		if not ups2.is_empty():
			log_line(">>> 升级！Lv.%d（下场战斗生效）" % int(ups2[1]))
		GameState.phase = "act2_choice"   # 战场抉择：审判 / 释放
		return
	# 奖励（凸增长，GDD/07）
	var ups: Array = GameState.add_exp(int(card.get("exp", 0)))
	GameState.gold += int(card.get("gold", 0))
	log_line("讨伐 %s：+%d 经验 +%d 金" % [card.get("name", "?"),
			int(card.get("exp", 0)), int(card.get("gold", 0))])
	if not ups.is_empty():
		log_line(">>> 升级！Lv.%d（全员 +18HP·主角+22HP / +4攻 / +3防，下场战斗生效）" % int(ups[1]))
	# 掉落判定
	var drop := String(card.get("drop", ""))
	var drop_p := float(card.get("drop_p", 0.0))
	if drop != "" and randf() < drop_p:
		match drop:
			"san_item":
				GameState.san_items += 1
				log_line("掉落：定神香 ×1")
			"gear":
				if randf() < 0.5:
					GameState.gear_atk += 3
					log_line("掉落：锐牙坠饰（主角攻 +3，灰盒占位宝物）")
				else:
					GameState.gear_def += 3
					log_line("掉落：鳞纹臂甲（主角防 +3，灰盒占位宝物）")
	_advance_step(false)


## 前进一步；走满 8 步 → 龙巢之门（第一幕）或 处刑台之门（第二幕·回程终点）
func _advance_step(leave_empty: bool) -> void:
	GameState.step += 1
	if GameState.step > 8:
		if not GameState.act1_cleared:
			# GDD/01：通往龙巢的路是空的——所有拦路的魔物都死绝了
			GameState.boss_pending = true
			GameState.phase = "boss_gate"
			log_line("—— 通往龙巢的路，是空的。——")
		else:
			# 第二幕：回程只有一个来回——终点是王都处刑台
			GameState.act2_gate = true
			GameState.phase = "act2_finale"
			log_line("—— 雪路的尽头，是处刑台。他们把勇者留在了那里等你。——")
	else:
		GameState.phase = "journey"
		GameState.current_offers = _draw_offers()


func _draw_offers() -> Array:
	# 第二幕回程：只抽人类卡池（教团与王国的围剿）
	if GameState.act1_cleared:
		var base2: int = GameState.dial + GameState.floor_bonus()
		var allowed2 := []
		for s in range(clampi(base2, 1, 5), clampi(base2 + 1, 1, 5) + 1):
			allowed2.append(s)
		return CardsDB.draw_offers(allowed2, true)
	# 允许星级 = 旋钮基准 + 动态地板（GDD/06：Boss 门前不出现哥布林）
	var base: int = GameState.dial + GameState.floor_bonus()
	var allowed := []
	for s in range(clampi(base, 1, 5), clampi(base + 1, 1, 5) + 1):
		allowed.append(s)
	return CardsDB.draw_offers(allowed)


# ============================================================
# 二、阶段面板
# ============================================================

func _build_phase_panel() -> void:
	ui_panel = Control.new()
	add_child(ui_panel)
	match GameState.phase:
		"village":
			_panel_village()
		"journey":
			_panel_journey()
		"defeat":
			_panel_defeat()
		"collapse":
			_panel_collapse()
		"boss_gate":
			_panel_boss_gate()
		"truth":
			_panel_truth()
		"act2_finale":
			_panel_act2_finale()
		"act2_end":
			_panel_act2_end()
		"act2_true":
			_panel_act2_true()
		"act2_fail":
			_panel_act2_fail()
		"act2_choice":
			_panel_act2_choice()
		"demonize":
			_panel_demonize()
		"act2_open":
			_panel_act2_open()


## —— 处刑台战败：终局（最终站没有第二次）——
func _panel_act2_fail() -> void:
	GameState.pending_battle = {}
	ui_title.text = "复仇 · 未竟"
	var img := TextureRect.new()
	img.texture = load("res://assets/art/cg_ai/CG13_white_raven_loop.png")
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	img.position = Vector2(320, 44)
	img.size = Vector2(640, 360)
	ui_panel.add_child(img)
	var serif := SystemFont.new()
	serif.font_names = ["Noto Serif CJK SC"]
	var l := Label.new()
	l.text = "剑落下的速度，和当年斩向父王时一模一样。\n白鸦从处刑台的栏杆上惊起——\n它见过这一切：第一次，和这一次。\n\n—— 复仇 · 未竟 ——"
	l.add_theme_font_override("font", serif)
	l.position = Vector2(320, 430)
	l.size = Vector2(640, 160)
	l.add_theme_font_size_override("font_size", 17)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("shadow_offset_y", 2)
	ui_panel.add_child(l)
	_btn("回到标题", Vector2(540, 640), func():
		GameState.reset_run()
		get_tree().change_scene_to_file("res://scenes/ui/title_scene.tscn"))


## —— 行商按钮组（村口/山门/处刑台通用；金币的主要去处）——
func _shop_buttons(x: int, y0: int) -> void:
	_btn("行商 · 定神香 50金（SAN+25）", Vector2(x, y0), func():
		if GameState.gold >= 50:
			GameState.gold -= 50
			GameState.san_items += 1
			play_sfx("se_card_flip")
			log_line("买了一柱定神香。")
			_refresh_status()
		else:
			log_line("金币不够……"))
	_btn("行商 · 锐牙坠饰 100金（主角攻+3）", Vector2(x, y0 + 52), func():
		if GameState.gold >= 100:
			GameState.gold -= 100
			GameState.gear_atk += 3
			play_sfx("se_card_stomp")
			log_line("坠贴上胸，齿锋微热。（主角攻 +%d）" % GameState.gear_atk)
			_refresh_status()
		else:
			log_line("金币不够……"))
	_btn("行商 · 鳞纹臂甲 100金（主角防+3）", Vector2(x, y0 + 104), func():
		if GameState.gold >= 100:
			GameState.gold -= 100
			GameState.gear_def += 3
			play_sfx("se_card_stomp")
			log_line("臂甲扣紧，鳞纹微温。（主角防 +%d）" % GameState.gear_def)
			_refresh_status()
		else:
			log_line("金币不够……"))
	_btn("行商 · 血瓶 60金（+1）", Vector2(x, y0 + 156), func():
		if GameState.gold >= 60:
			GameState.gold -= 60
			GameState.blood_potions += 1
			play_sfx("se_card_flip")
			log_line("血瓶沉甸甸地挂上腰间。（剩 %d 瓶）" % GameState.blood_potions)
			_refresh_status()
		else:
			log_line("金币不够……"))


## —— 龙巢之门（8 步铺满后，第一幕未结算时）——
func _panel_boss_gate() -> void:
	ui_title.text = "龙巢 · 山门"
	var t := Label.new()
	t.text = "最后一段路没有雪，只有黑石，和空气里烧焦的甜味。\n一路上再没有魔物袭击——它们不是没来拦，是全死了。\n\n山门前，一个不肯透露姓名的行商支起了摊子：\n「买点吧，勇士。里面那位——不好对付。」"
	t.position = Vector2(300, 185)
	t.size = Vector2(720, 130)
	t.add_theme_font_size_override("font_size", 15)
	ui_panel.add_child(t)
	_shop_buttons(240, 330)   # 决战前最后补给（用户定稿：打恶龙前必须能补给）
	_btn("步入龙巢 →", Vector2(820, 400), func():
		GameState.pending_battle = {
			"id": "dragon_boss", "name": "恶龙", "unit": "dragon",
			"count": 1, "star": 5, "exp": 0, "gold": 0,
			"drop": "", "drop_p": 0.0, "boss": true,
		}
		play_sfx("se_card_flip")
		get_tree().change_scene_to_file("res://scenes/combat/combat_scene.tscn"))


## —— 第二幕·开场（觉醒后，独行南下的告别）——
func _panel_act2_open() -> void:
	ui_title.text = "龙巢 · 雪停了"
	GameState.loop = 2
	GameState.step = 1
	_truth_text("法师往北去了。他说，别回头。\n牧师留在龙巢的雪里，念珠散了一地。\n勇者回了王都——他们要为「讨魔凯旋」办庆典。\n\n他替父亲合上那只能视千里的金瞳，\n把剑背上肩。一个人，往南。",
			"res://assets/art/cg_ai/CG08_ash_prayer.png")
	_btn("一个人，往南。", Vector2(540, 640), func():
		GameState.phase = "village"
		play_sfx("se_card_flip")
		_rebuild())


## —— 第二幕·处刑台之门（回程 8 步铺满后）——
func _panel_act2_finale() -> void:
	ui_title.text = "王都 · 处刑台"
	_truth_text("雪停了。处刑台的木头还是新的——\n他们当着全城的面，把你钉上过这根柱子。\n\n现在勇者一个人站在上面，剑尖垂着。\n「魔子。」他喊出那个他们瞒了你一路的词。\n\n这一战没有队友，没有退路。",
			"res://assets/art/cg_ai/CG06_beheading.png")
	_shop_buttons(60, 430)   # 决战前最后补给
	_btn("登上处刑台 →", Vector2(560, 640), func():
		var card: Dictionary = CardsDB.CARDS["boss_hero"].duplicate()
		GameState.pending_battle = card
		play_sfx("se_card_flip")
		get_tree().change_scene_to_file("res://scenes/combat/combat_scene.tscn"))


## —— 第二幕·战场抉择（GDD/05 第三节，用户 2026-11-07 定稿）——
## 审判 = 接过教团定他罪的那个词：杀孽+1、SAN-15、缴获战利品；
## 释放 = SAN 不变，可能得到报恩（血瓶/定神香/情报）。
## 经验已在胜利时全额发放（GDD/05：经验来自"击败"，与杀不杀无关）。
func _panel_act2_choice() -> void:
	var card: Dictionary = GameState.pending_battle
	ui_title.text = "回程 · %s 已被击溃 —— 审判，还是释放？" % String(card.get("name", "降兵"))
	var l := Label.new()
	l.text = "刀锋停在他们喉咙上方一寸的地方。\n降兵跪在雪里，不敢抬头看你的眼睛。\n\n教团定你罪的那个词，就压在舌尖上。"
	l.position = Vector2(420, 250)
	l.size = Vector2(560, 140)
	l.add_theme_font_size_override("font_size", 16)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("shadow_offset_y", 2)
	ui_panel.add_child(l)
	_btn("审判（杀孽 +1 / SAN -15 / 缴获战利品）", Vector2(300, 420), func():
		_do_judgment())
	_btn("释放（SAN 不变 / 或有报恩）", Vector2(640, 420), func():
		_do_release())


func _do_judgment() -> void:
	play_sfx("se_card_stomp")
	GameState.kill_sin += 1
	GameState.san = maxf(0.0, GameState.san - 15.0)
	log_line("「审判。」你念出他们给你的词。雪地上多了几具尸体。（杀孽 %d，SAN -15）"
			% GameState.kill_sin)
	if randf() < 0.5:
		GameState.gear_atk += 3
		log_line("缴获：锐牙坠饰（主角攻 +3）")
	else:
		GameState.gear_def += 3
		log_line("缴获：鳞纹臂甲（主角防 +3）")
	_after_act2_choice()


func _do_release() -> void:
	play_sfx("se_card_flip")
	match randi() % 3:
		0:
			GameState.blood_potions += 1
			log_line("你收了剑。一名溃兵从怀里掏出血瓶塞给你——「别再让我们看见你。」（血瓶 +1）")
		1:
			GameState.san_items += 1
			log_line("你侧过身，让开一条路。老兵回头放下一包定神香。（定神香 +1）")
		_:
			log_line("你收了剑。溃兵连滚带爬地消失在雪雾里，回头喊了句什么——\n\t大概是：前面的哨卡换防了。（情报）")
	log_line("（SAN 不变。但溃兵会带回消息——围剿只会越来越凶。）")
	_after_act2_choice()


func _after_act2_choice() -> void:
	GameState.pending_battle = {}
	# 先记下魔化苏醒后的去处（_advance_step 会改 phase，且魔化时不推进）
	GameState.demonize_resume = "act2_finale" if GameState.step >= 8 else "journey"
	if _enter_demonize():
		return
	_advance_step(false)
	_rebuild()


## 第二幕 SAN 归零 → 不结算，直接化身魔龙（GDD/03 魔化觉醒 / GDD/07 第九节）。
## 返回 true = 已进入魔化演出（调用方不要再推进流程）。
func _enter_demonize() -> bool:
	if not GameState.act1_cleared or GameState.demonized or GameState.san > 0.0:
		return false
	GameState.san = 0.0
	GameState.demonized = true
	GameState.phase = "demonize"
	log_line("手臂上的鳞纹在发烫——六道锁链，寸寸崩断。")
	_rebuild()
	return true


## —— 魔化觉醒演出（GDD/03【化身】：锁链崩断、鳞甲吞没全身）——
## 数值碾压不做平衡（GDD/07 第九节）：血洗终章是加冕不是挑战。
func _panel_demonize() -> void:
	ui_title.text = "化身"
	var img := TextureRect.new()
	img.texture = load("res://assets/art/cg_ai/CG14_dragon_awakening.png")
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	img.position = Vector2(320, 44)
	img.size = Vector2(640, 360)
	ui_panel.add_child(img)
	var edge := ColorRect.new()
	edge.color = Color(0.85, 0.8, 0.65, 0.35)
	edge.position = img.position - Vector2(2, 2)
	edge.size = img.size + Vector2(4, 4)
	edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_panel.add_child(edge)
	ui_panel.move_child(edge, img.get_index())
	var serif := SystemFont.new()
	serif.font_names = ["Noto Serif CJK SC"]
	var l := Label.new()
	l.text = "手臂上的六道鳞纹寸寸崩断——\n不，那不是崩断。是锁链终于认出了主人。\n\n视界褪成铁灰。人类的城市第一次显出\"原形\"——\n不过是另一个巢穴。\n\n—— 封印已碎。人形，到此为止。——"
	l.add_theme_font_override("font", serif)
	l.position = Vector2(320, 430)
	l.size = Vector2(640, 160)
	l.add_theme_font_size_override("font_size", 17)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("shadow_offset_y", 2)
	ui_panel.add_child(l)
	_btn("血洗终章 →", Vector2(540, 640), func():
		GameState.phase = GameState.demonize_resume if GameState.demonize_resume != "" else "village"
		if GameState.phase == "journey":
			GameState.current_offers = _draw_offers()
		play_sfx("se_card_flip")
		_rebuild())


## —— 第二幕·完 ——
func _panel_act2_end() -> void:
	ui_title.text = "第二幕 · 完"
	GameState.pending_battle = {}
	var serif := SystemFont.new()
	serif.font_names = ["Noto Serif CJK SC"]
	var img := TextureRect.new()
	img.texture = load("res://assets/art/cg_ai/CG10_blood_march.png")
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	img.position = Vector2(320, 44)
	img.size = Vector2(640, 360)
	ui_panel.add_child(img)
	var l := Label.new()
	l.text = "剑落进雪里，像二十年前那样安静。\n白鸦落在处刑台的栏杆上，歪头看你。\n山下的王都钟声撞了七下——这次，是丧钟。\n\n—— 第二幕 · 完 ——"
	l.add_theme_font_override("font", serif)
	l.position = Vector2(320, 430)
	l.size = Vector2(640, 160)
	l.add_theme_font_size_override("font_size", 17)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("shadow_offset_y", 2)
	ui_panel.add_child(l)
	_btn("回到标题", Vector2(540, 640), func():
		GameState.reset_run()
		get_tree().change_scene_to_file("res://scenes/ui/title_scene.tscn"))


## —— 真结局 ·《不染雪》（GDD/03 第二节）：SAN=100 = 第二幕零杀，胜利靠真相不靠刀 ——
func _panel_act2_true() -> void:
	ui_title.text = "真结局 · 不染雪"
	GameState.pending_battle = {}
	var serif := SystemFont.new()
	serif.font_names = ["Noto Serif CJK SC"]
	var img := TextureRect.new()
	img.texture = load("res://assets/art/cg_ai/CG11_unspoiled_snow.png")
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	img.position = Vector2(320, 44)
	img.size = Vector2(640, 360)
	ui_panel.add_child(img)
	var l := Label.new()
	l.text = "剑抵着勇者的咽喉——然后收了。\n他转身面向圣都，只说了一句：「叫他们自己来看。」\n\n人群分开，拄杖的身影走出来——法师没有死。\n他带回教团的罪证：造「容器」的名册、栽赃北境的原始手令。\n真相在王庭自内炸开。没有屠城，没有加冕。\n\n雪停时，他回到龙巢，在巢穴口种下一株白桦——\n牧师的念珠，埋在树根下。\n\n—— 全剧情 · 完 ——"
	l.add_theme_font_override("font", serif)
	l.position = Vector2(320, 408)
	l.size = Vector2(640, 225)
	l.add_theme_font_size_override("font_size", 16)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("shadow_offset_y", 2)
	ui_panel.add_child(l)
	_btn("回到标题", Vector2(540, 640), func():
		GameState.reset_run()
		get_tree().change_scene_to_file("res://scenes/ui/title_scene.tscn"))


## —— 真相时刻：七节拍演出 + SAN 闸门（GDD/01 觉醒之夜，血肉版）——
## 节拍 0-1 全员可见（牧师之死、那声呼唤）；节拍 2 = SAN 闸门分流：
## ≥50 进觉醒线（3-6：封印碎裂/斩首/挡刀/灰烬），<50 幻觉结局《白鸦》。
## 判定点=牧师之死后（GDD/01 定稿）。
func _panel_truth() -> void:
	match int(GameState.truth_beat):
		0:
			ui_title.text = "龙巢 · 终战之后"
			_truth_text("龙尾的余波，扫在牧师推开的那个位置。\n念珠散了一地，雪地上滚出很远，一颗一颗，像散落的白骨。\n\n「不恨他……」她躺在主角怀里，声音已经散了。\n「他也是……被选中的……」\n「安抚……好了……这次，睡吧……」\n\n她的手，从主角的额头上滑落。",
					"res://assets/art/cg_ai/CG04_beads.png")
			_btn("雪，落了下来", Vector2(540, 640), func(): _truth_advance())
		1:
			ui_title.text = "龙巢 · 那声呼唤"
			_truth_text("垂死的龙看到主角——金瞳猛地收缩，整头龙都在发抖。不是恐惧。\n\n二十年的记忆轰然对位：魔物的低语、亲卫的军令、\n避开的利爪、温热的族徽、「王座的味道」——\n\n它用那种只有你听得懂的、破碎的齿音，喊了一个名字：\n\n「……小满。」",
					"res://assets/art/cg_ai/CG02_warm_scale.png")
			_btn("……", Vector2(560, 640), func(): _truth_advance())
		2:
			_panel_truth_gate()
		3:
			ui_title.text = "龙巢 · 封印碎裂"
			_truth_text("封印碎了。不是轰然巨响，是极静的一瞬——\n像二十年来一直压在耳上的水，忽然被人拿开。\n\n他听见了一切：雪落的声音、龙的心跳、\n勇者怀里四枚火漆密信烧着的轻响。\n\n手臂上的鳞纹一道一道亮起来，连成甲。\n他跪在牧师身边，用那口从没被人听懂过的齿音开口：\n\n「……父王。」\n\n龙巨大的头垂下来，额头抵住他的额头。\n像很多年前做过、他不记得的那样。",
					"res://assets/art/cg_ai/CG05_awakening.png")
			_btn("……", Vector2(560, 640), func(): _truth_advance())
		4:
			ui_title.text = "龙巢 · 斩首"
			_truth_text("勇者的剑就是在这一刻落下的。\n没有犹豫，没有宣言。教团密令早在信里：\n\n「容器破封。就地处决。」\n\n龙尾横扫挡在中间——二十年旧伤的身体撑到了极限——\n剑锋透鳞而入。\n\n父王的头颅，落在雪里。\n和牧师的念珠，滚在同一个坑里。",
					"")
			_btn("……", Vector2(560, 640), func(): _truth_advance())
		5:
			ui_title.text = "龙巢 · 挡刀"
			_truth_text("「容器污染。」勇者提着剑走过来，语气平得像念祷文。\n「就地处决。」\n\n剑光起——一面冰镜横在中间，碎成三千片。\n\n法师站在主角身前，兜帽落了。\n他回过头，说了整部游戏里最长的一句话：\n\n「跑。往北。别回头。」",
					"res://assets/art/cg_ai/CG07_ice_mirror.png")
			_btn("雪崩把两个人隔在了两侧", Vector2(540, 640), func(): _truth_advance())
		6:
			ui_title.text = "第一幕终 · 灰烬"
			_truth_text("主角在龙巢最深处醒来。身边是父王未凉的尸体。\n魔物语言像母语一样，从他嘴里流出来。\n\n他跪在父王身边，把二十年来第一句完整的话，\n说给一具尸体听：\n\n「我叫……」\n他想起那个在火里喊过他的名字。\n\n「……我回家了。」",
					"res://assets/art/cg_ai/CG08_ash_prayer.png")
			_btn("一个人，往南 →", Vector2(540, 640), func(): _awaken_to_village())


## 剧情文本 + 大幅配图（正式插画 CG，1344x768）：
## 上半屏等比铺图 + 下方衬线文案，电影分镜式排版。
func _truth_text(s: String, cg_path: String = "") -> void:
	if cg_path != "":
		var img := TextureRect.new()
		img.texture = load(cg_path)
		img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		img.position = Vector2(320, 44)
		img.size = Vector2(640, 360)
		ui_panel.add_child(img)
		var edge := ColorRect.new()   # 细边框收住画面
		edge.color = Color(0.85, 0.8, 0.65, 0.35)
		edge.position = img.position - Vector2(2, 2)
		edge.size = img.size + Vector2(4, 4)
		edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ui_panel.add_child(edge)
		ui_panel.move_child(edge, img.get_index())   # 边框垫在图下
	var serif := SystemFont.new()
	serif.font_names = ["Noto Serif CJK SC"]
	var l := Label.new()
	l.text = s
	l.add_theme_font_override("font", serif)
	l.position = Vector2(320, 430)
	l.size = Vector2(640, 180)
	l.add_theme_font_size_override("font_size", 17)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("shadow_offset_y", 2)
	ui_panel.add_child(l)


func _truth_advance() -> void:
	GameState.truth_beat += 1
	_rebuild()


## 节拍 2：SAN 闸门——判定点在牧师之死后（GDD/01）。
## ≥50 → 封印在响，按下去进觉醒线（节拍 3-6）；<50 → 幻觉结局《白鸦》
func _panel_truth_gate() -> void:
	if GameState.san >= 50.0:
		ui_title.text = "真相时刻 · SAN %d ≥ 50 → 封印在响" % int(GameState.san)
		_truth_text("耳朵里那层压了二十年的水，忽然晃了一下。\n有什么东西，要从里面出来了。\n\n—— 封印，在响。——",
				"")
		_btn("封印碎裂 →", Vector2(540, 640), func():
			GameState.truth_beat = 3
			_rebuild())
	else:
		ui_title.text = "真相时刻 · SAN %d < 50 → 封印撑住了" % int(GameState.san)
		_truth_text("教团说他受了刺激，给他派了新的安抚师。\n晨祷堂，钟声撞了七下——一切和最开始一模一样。\n只有他手臂上的鳞纹，比那时多了一道。\n\n—— 幻觉结局 ·《白鸦》——",
				"res://assets/art/cg_ai/CG13_white_raven_loop.png")
		_btn("（重新开始）", Vector2(540, 640), func():
			GameState.reset_run()
			_rebuild())


## 觉醒结算：牧师之死生效、进第二幕开场（独行南下）
func _awaken_to_village() -> void:
	GameState.priest_dead = true
	GameState.awakened = true
	GameState.act1_cleared = true
	GameState.boss_pending = false
	GameState.loop += 1
	GameState.step = 1
	GameState.phase = "act2_open"
	GameState.pending_battle = {}
	_rebuild()


## —— 村庄：教会回血 / 挑战等级 / 定神香 / 安抚 / 出发 ——
## 第二幕·回程：同一套机制，皮换成"山间补给点"（不再显示轮数——回程只有一个来回）
func _panel_village() -> void:
	if GameState.act1_cleared:
		ui_title.text = "回程 · 山间补给点（伤势已处理）"
	elif GameState.awakened:
		ui_title.text = "第 %d 轮 · 村口" % GameState.loop
	else:
		ui_title.text = "第 %d 轮 · 村庄（教会免费回满了队伍）" % GameState.loop
	# 标题写了"免费回满"，机制就必须同步：进村即清伤势残留
	#（否则玩家不点祈祷按钮就出发，会带着上场的残血赶路）
	GameState.party_hp.clear()

	_btn("教会祈祷（已回满）", Vector2(700, 150), func():
		play_sfx("se_heal")
		log_line("教会的钟声平复了伤势。全队回满。" if not GameState.act1_cleared
				else "破庙的烛火里，伤口自己合上了。回满。"))
	if GameState.in_run:
		# 挑战等级开局定死（用户 2026-11-07 定稿）：出发过一次就锁，
		# 村庄只显示已定的祝祷——roguelite 的构建要做在起点
		var locked := Label.new()
		locked.text = "祝祷已定：【%s】（出发后不可更改）" % DIAL_NAMES[GameState.dial]
		locked.position = Vector2(700, 208)
		locked.add_theme_font_size_override("font_size", 15)
		locked.modulate = Color(1, 1, 1, 0.65)
		ui_panel.add_child(locked)
	else:
		for d in ( [1, 2, 3] as Array):
			var dial := int(d)
			var b := _btn("挑战等级：%s" % DIAL_NAMES[dial], Vector2(700, 200 + (dial - 1) * 52), func():
				GameState.dial = dial
				log_line("祝祷定为【%s】——本轮遭遇将偏向%s。" % [DIAL_NAMES[dial],
						"安全" if dial == 1 else ("均衡" if dial == 2 else "凶险")])
				_refresh_status())
			b.modulate = Color.WHITE if GameState.dial == dial else Color(0.55, 0.55, 0.55)
	var depart := _btn("出发 →", Vector2(700, 400), func():
		GameState.in_run = true
		if GameState.boss_pending:
			# 败给父王后退回村整备的情况：路已铺满，出发直达龙巢
			GameState.phase = "boss_gate"
			log_line("你再次站到了山门前。")
		elif GameState.act2_gate:
			# 处刑台战败后退回补给点：直接再挑战
			GameState.phase = "act2_finale"
			log_line("处刑台就在路的尽头。")
		else:
			GameState.step = 1
			GameState.phase = "journey"
			GameState.road = ["", "", "", "", "", "", "", ""]
			GameState.current_offers = _draw_offers()
		play_sfx("se_card_flip")
		_rebuild())
	depart.modulate = Color(1.0, 0.95, 0.7)
	_btn("回到标题画面", Vector2(700, 460), func():
		play_sfx("se_ui_click")
		get_tree().change_scene_to_file("res://scenes/ui/title_scene.tscn"))

	# —— 左栏：行商（金币的主要去处：消耗品 + 主角装具）——
	_shop_buttons(380, 150)
	if not GameState.act1_cleared:
		_btn("牧师安抚（SAN+15 / 主角最大生命-5）", Vector2(380, 358), func():
			if GameState.priest_dead:
				log_line("她的座位空着。没有人再能安抚你了。")
				return
			if GameState.scale_marks >= 6:
				# 鳞纹 6 道封顶（GDD 伏笔：6/6=鳞纹爬满手臂）。
				# 无上限时"战败-10/安抚+15"净赚 5 点，SAN 永远掉不进幻觉区间，
				# 结局分流失效（实测 7 连败 SAN 纹丝不动）。
				log_line("牧师的手停住了。六道鳞纹已经爬满手臂——再安抚，就要盖住心了。")
				return
			if GameState.san >= 100.0:
				log_line("主角的心智已经很安稳，不需要安抚。")
				return
			GameState.san = minf(100.0, GameState.san + 15.0)
			GameState.protag_hp_penalty += 5
			GameState.scale_marks += 1
			play_sfx("se_heal")
			log_line("牧师的手掌覆上额头……温暖流过。手臂上又多了一道鳞纹。（%d/6）"
					% mini(GameState.scale_marks, 6))
			_refresh_status()
			_update_heartbeat())


## —— 赶路：三选一怪卡 ——
func _panel_journey() -> void:
	if GameState.act1_cleared:
		ui_title.text = "回程 · 第 %d/8 步 —— 围剿，三选一" % GameState.step
	else:
		ui_title.text = "第 %d 轮 · 第 %d/8 步 —— 前方遭遇，三选一" % [GameState.loop, GameState.step]
	if GameState.current_offers.is_empty():
		GameState.current_offers = _draw_offers()

	for i in range(GameState.current_offers.size()):
		var card_id: String = GameState.current_offers[i]
		var card: Dictionary = CardsDB.CARDS[card_id]
		var star: int = int(card["star"])
		var b := Button.new()
		b.position = Vector2(300 + i * 200, 230)
		b.size = Vector2(170, 250)
		b.pressed.connect(func(): _choose_card(card_id))
		ui_panel.add_child(b)

		var frame := TextureRect.new()
		frame.texture = load("res://assets/art/ui/card_tier%d.png" % CardsDB.frame_tier(star))
		frame.position = Vector2(25, 10)
		frame.stretch_mode = TextureRect.STRETCH_KEEP
		b.add_child(frame)

		var name_l := Label.new()
		name_l.text = String(card["name"])
		name_l.position = Vector2(25, 12)
		name_l.add_theme_font_size_override("font_size", 13)
		b.add_child(name_l)

		var star_l := Label.new()
		star_l.text = "★".repeat(star)
		star_l.position = Vector2(25, 172)
		star_l.modulate = Color(1.0, 0.85, 0.35)
		star_l.add_theme_font_size_override("font_size", 14)
		b.add_child(star_l)

		var info_l := Label.new()
		info_l.text = "经验%d 金%d\n%s×%d" % [int(card["exp"]), int(card["gold"]),
				String(card["name"]), int(card["count"])]
		info_l.position = Vector2(25, 192)
		info_l.add_theme_font_size_override("font_size", 12)
		b.add_child(info_l)

	# 途中用品
	_btn("定神香 SAN+25（剩%d）" % GameState.san_items, Vector2(300, 510), func():
		_use_san_item())

	# 第一幕·路上的低语（GDD/01 固定节拍）：伏笔只藏在"发生了什么"里，
	# 旁白不点破——剧透纪律见 title_scene 序章注释
	if not GameState.act1_cleared:
		_act1_whisper()


## 第一幕固定节拍低语：每个步位只演一次（beats_seen 记录）。
## 文案全部出自 GDD/01 第一二章——魔物的声音只有主角听得懂，
## 玩家此刻只觉得诡异，龙巢真相时刻才回过味来。
const ACT1_BEATS := {
	2: "夜里你睡不着。那些声音太密了，一句一句，像接力：\n「在人类的队伍里……」「王子还活着。」\n「别伤他。谁都不许伤他。」",
	4: "混战里，一道洪钟般的意志贯穿全场：\n「亲卫队听令：殿下在人类手里。夺回来。活要见人。」\n回过神时，你跪在雪里——你用那种破碎的齿音，答了一声：「在。」",
	6: "梦里全是火。火里有个很大的影子俯下来，用同样的音节喊你——\n喊的不是「圣骑士」，\n是一个你不认识的、两个字的名字。",
	7: "沼泽对面的巨魔立在苇丛深处，不攻击，不后退。\n它隔着整整一条泥河看着你——\n然后，冲你低了低头。像行礼。",
}


func _act1_whisper() -> void:
	if not ACT1_BEATS.has(GameState.step):
		return
	var key := "beat_%d" % GameState.step
	if GameState.beats_seen.has(key):
		return
	GameState.beats_seen.append(key)
	print("低语伏笔触发：beat_%d（GDD/01 固定节拍）" % GameState.step)
	var w := Label.new()
	w.text = String(ACT1_BEATS[GameState.step])
	w.position = Vector2(300, 158)
	w.size = Vector2(720, 66)
	w.add_theme_font_size_override("font_size", 12)
	w.add_theme_color_override("font_color", Color(0.75, 0.75, 0.85))
	w.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	w.add_theme_constant_override("shadow_offset_y", 2)
	ui_panel.add_child(w)
	play_sfx("se_heartbeat")


func _choose_card(card_id: String) -> void:
	play_sfx("se_card_flip")
	# CARDS 是 const（只读），duplicate 后再加 id 字段
	GameState.pending_battle = CardsDB.CARDS[card_id].duplicate()
	GameState.pending_battle["id"] = card_id
	log_line("选择了【%s】……" % String(GameState.pending_battle["name"]))
	get_tree().change_scene_to_file("res://scenes/combat/combat_scene.tscn")


## —— 战败面板：重试（损金）或弃卡前进；败给父王则回村整备 ——
func _panel_defeat() -> void:
	ui_title.text = "队伍败退……（SAN -20 已结算）"
	var is_boss: bool = GameState.pending_battle.has("boss")
	_btn("原地重试（损失 30 金，伤势保留）", Vector2(500, 300), func():
		GameState.gold = maxi(0, GameState.gold - 30)
		log_line("咽下耻辱，重新整顿……（-30 金）")
		_refresh_status()
		get_tree().change_scene_to_file("res://scenes/combat/combat_scene.tscn"))
	if is_boss:
		if GameState.act1_cleared:
			# 处刑台战败：退回补给点，台上的门一直开着
			_btn("退回补给点（处刑台仍在等你）", Vector2(500, 360), func():
				GameState.pending_battle = {}
				GameState.phase = "village"
				log_line("你从刑台的血泊里退了出来。剑痕还在木柱上。")
				_rebuild())
		else:
			# 败给父王：路已经铺满，回村庄整备后可从"出发"直接再入龙巢
			_btn("退回村庄整备（龙巢之门保持开启）", Vector2(500, 360), func():
				GameState.pending_battle = {}
				GameState.phase = "village"
				log_line("雪崩封住了退路的一角——但龙巢的门，还开着。")
				_rebuild())
	else:
		_btn("放弃此卡，继续前进（路格留空）", Vector2(500, 360), func():
			_advance_step(true)
			_rebuild())


## —— 心防崩溃（第一幕 SAN=0，GDD/05）——
func _panel_collapse() -> void:
	ui_title.text = "……"
	var big := Label.new()
	big.text = "心防崩塌了。\n那些声音不再可怕——这才是最可怕的事。\n\n—— 幻觉结局 · 提前坍缩 ——\n（晨祷堂，钟声撞了七下。一切和最开始一模一样。）"
	big.position = Vector2(400, 260)
	big.add_theme_font_size_override("font_size", 20)
	ui_panel.add_child(big)
	_btn("重新开始", Vector2(580, 420), func():
		GameState.reset_run()
		_rebuild())


# ============================================================
# 三、通用 UI
# ============================================================

func _build_static_ui() -> void:
	# 村庄背景（等比 COVERED 铺满，像素/插画资产通吃）+ 压暗层保证 UI 可读
	var bg := TextureRect.new()
	bg.texture = load("res://assets/art/bg/bg_village.png")
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.size = Vector2(1280, 720)
	add_child(bg)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.size = Vector2(1280, 720)
	add_child(dim)

	ui_title = Label.new()
	ui_title.position = Vector2(24, 14)
	ui_title.add_theme_font_size_override("font_size", 20)
	add_child(ui_title)

	# SAN 条（GDD/09 UI-03：正式版做鳞纹样式，灰盒用色条）
	var san_bg := ColorRect.new()
	san_bg.color = Color(0.1, 0.1, 0.12)
	san_bg.position = Vector2(24, 52)
	san_bg.size = Vector2(204, 18)
	add_child(san_bg)
	ui_san_fill = ColorRect.new()
	ui_san_fill.position = Vector2(26, 54)
	ui_san_fill.size = Vector2(200, 14)
	add_child(ui_san_fill)
	ui_san_text = Label.new()
	ui_san_text.position = Vector2(236, 48)
	ui_san_text.add_theme_font_size_override("font_size", 14)
	add_child(ui_san_text)

	ui_res = Label.new()
	ui_res.position = Vector2(24, 78)
	ui_res.add_theme_font_size_override("font_size", 14)
	add_child(ui_res)

	# 铺路条（8 格）
	for i in range(8):
		var t := TextureRect.new()
		t.texture = load("res://assets/art/ui/tile_road.png")
		t.position = Vector2(40 + i * 72, 120)
		t.scale = Vector2(2, 2)
		t.stretch_mode = TextureRect.STRETCH_KEEP
		t.modulate = Color(0.35, 0.35, 0.4)   # 未踩过的路格调暗
		add_child(t)
		ui_road.append(t)

	ui_log = Label.new()
	ui_log.position = Vector2(24, 560)
	ui_log.size = Vector2(700, 150)
	ui_log.add_theme_font_size_override("font_size", 13)
	add_child(ui_log)


## ============================================================
## 开发者面板（F9 呼出/收起）——快速体验用，正式版整体删除
## ============================================================

func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and ev.keycode == KEY_F9 \
			and not ev.echo:
		_toggle_debug()


func _toggle_debug() -> void:
	if ui_debug != null:
		ui_debug.queue_free()
		ui_debug = null
		return
	ui_debug = Control.new()
	add_child(ui_debug)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.82)
	bg.size = Vector2(1280, 720)
	ui_debug.add_child(bg)
	var t := Label.new()
	t.text = "—— 开发者面板（F9 关闭）——"
	t.position = Vector2(60, 24)
	t.add_theme_font_size_override("font_size", 18)
	ui_debug.add_child(t)
	var items := [
		["跳到第二幕（觉醒 · Lv6 · SAN 80）", func():
			GameState.awakened = true
			GameState.act1_cleared = true
			GameState.priest_dead = true
			GameState.level = 6
			GameState.san = 80.0
			GameState.gold = 200
			GameState.loop = 2
			GameState.step = 1
			GameState.in_run = false
			GameState.boss_pending = false
			GameState.act2_gate = false
			GameState.phase = "act2_open"
			_close_debug_and_reload()],
		["直接龙巢之门（路铺满，父王在等）", func():
			GameState.boss_pending = true
			GameState.phase = "boss_gate"
			GameState.step = 8
			GameState.road = ["x", "x", "x", "x", "x", "x", "x", "x"]
			GameState.in_run = true
			_close_debug_and_reload()],
		["直接处刑台（勇者单挑）", func():
			GameState.awakened = true
			GameState.act1_cleared = true
			GameState.priest_dead = true
			GameState.level = maxi(GameState.level, 6)
			GameState.act2_gate = true
			GameState.phase = "act2_finale"
			GameState.in_run = true
			_close_debug_and_reload()],
		["SAN +25", func():
			GameState.san = minf(100.0, GameState.san + 25.0)
			_refresh_status()],
		["SAN -25", func():
			GameState.san = maxf(0.0, GameState.san - 25.0)
			_refresh_status()],
		["升级 +1（全员成长下场生效）", func():
			GameState.add_exp(GameState.exp_threshold(GameState.level) - GameState.exp_total)
			_refresh_status()],
		["金币 +200 / 定神香+1 / 血瓶+2", func():
			GameState.gold += 200
			GameState.san_items += 1
			GameState.blood_potions += 2
			_refresh_status()],
		["魔化开关（化身魔龙 · 血洗终章形态）", func():
			GameState.demonized = not GameState.demonized
			if GameState.demonized:
				GameState.san = 0.0
			log_line("魔化 = %s" % ("ON——鳞甲吞没全身" if GameState.demonized else "OFF"))
			_close_debug_and_reload()],
		["回到标题画面", func():
			ui_debug.queue_free()
			ui_debug = null
			GameState.reset_run()
			get_tree().change_scene_to_file("res://scenes/ui/title_scene.tscn")],
	]
	for i in range(items.size()):
		var b := Button.new()
		b.text = String(items[i][0])
		b.position = Vector2(60, 70 + i * 56)
		b.size = Vector2(420, 44)
		b.pressed.connect(items[i][1])
		ui_debug.add_child(b)
	var hint := Label.new()
	hint.text = "战斗内快捷键：F9 = 秒杀清场"
	hint.position = Vector2(520, 70)
	hint.modulate = Color(1, 1, 1, 0.6)
	hint.add_theme_font_size_override("font_size", 14)
	ui_debug.add_child(hint)


func _close_debug_and_reload() -> void:
	if ui_debug != null:
		ui_debug.queue_free()
		ui_debug = null
	_rebuild()


func _btn(text: String, pos: Vector2, on_pressed: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.position = pos
	b.size = Vector2(280, 40)
	b.pressed.connect(func(): play_sfx("se_ui_click"))
	b.pressed.connect(on_pressed)
	ui_panel.add_child(b)
	return b


func _update_road() -> void:
	for i in range(8):
		var filled: String = GameState.road[i] if i < GameState.road.size() else ""
		if filled != "":
			ui_road[i].modulate = Color.WHITE
			# Boss 档位的格子用暗红路砖（视觉预告终点）
			if i == 7:
				ui_road[i].texture = load("res://assets/art/ui/tile_road_boss.png")
		else:
			ui_road[i].modulate = Color(0.35, 0.35, 0.4)
			# 新一轮铺路前要把上一轮的暗红 Boss 砖换回普通路砖
			ui_road[i].texture = load("res://assets/art/ui/tile_road.png")


func _refresh_status() -> void:
	var ratio := GameState.san / 100.0
	ui_san_fill.size.x = 200.0 * ratio
	ui_san_fill.color = Color(0.9, 0.25, 0.25).lerp(Color(0.35, 0.8, 0.45), ratio)
	ui_san_text.text = "SAN %d" % int(GameState.san)
	ui_res.text = ("金 %d   定神香×%d   血瓶×%d   Lv.%d（exp %d/%d）   主角最大HP-%d"
			% [GameState.gold, GameState.san_items, GameState.blood_potions,
			GameState.level, GameState.exp_total, GameState.exp_threshold(GameState.level),
			GameState.protag_hp_penalty])


func _use_san_item() -> void:
	if GameState.san_items <= 0:
		log_line("没有定神香了。")
		return
	GameState.san_items -= 1
	GameState.san = minf(100.0, GameState.san + 25.0)
	play_sfx("se_heal")
	log_line("点燃定神香。那些声音退远了。（SAN +25）")
	_refresh_status()
	_update_heartbeat()


func _update_heartbeat() -> void:
	var need := GameState.san < 50.0
	if need and _heartbeat == null:
		_heartbeat = AudioStreamPlayer.new()
		_heartbeat.stream = load("res://assets/audio/sfx/se_heartbeat.wav")
		_heartbeat.volume_db = -4.0
		add_child(_heartbeat)
		_heartbeat.finished.connect(_heartbeat.play)
	if need and not _heartbeat.playing:
		_heartbeat.play()
	elif not need and _heartbeat != null and _heartbeat.playing:
		_heartbeat.stop()


func _start_bgm() -> void:
	_bgm = AudioStreamPlayer.new()
	_bgm.volume_db = -10.0
	add_child(_bgm)
	_bgm.finished.connect(_bgm.play)
	# 真相时刻用村庄曲（安魂曲式的平静比战斗曲更压得住这场戏）
	var track := "bgm_village" if GameState.phase in ["village", "truth"] else "bgm_battle"
	_bgm.stream = load("res://assets/audio/bgm/%s.ogg" % track)
	_bgm.play()


func _rebuild() -> void:
	get_tree().reload_current_scene()


func log_line(s: String) -> void:
	_log_lines.append(s)
	if _log_lines.size() > 9:
		_log_lines.pop_front()
	ui_log.text = "\n".join(_log_lines)
	print(s)


func play_sfx(sfx_name: String) -> void:
	var stream: AudioStream = load("res://assets/audio/sfx/%s.wav" % sfx_name)
	if stream == null:
		return
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = -6.0
	add_child(p)
	p.play()
	p.finished.connect(p.queue_free)


# ============================================================
# 四、自动冒烟测试（AUTOPLAY=1）：自动跑 2 轮后退出
# ============================================================

func _autoplay_step() -> void:
	# 场景可能在上一轮 await 里被切走（快节奏重载竞态）：不在树里就别碰 get_tree()
	if not is_inside_tree():
		return
	await get_tree().create_timer(0.25).timeout
	# 场景可能在 await 期间被切换/销毁——过期协程直接退场，防止对已释放节点操作
	if not is_inside_tree():
		return
	# 跑满 2 轮自动收工（判定点放在最前：任何阶段到达第 3 轮入口即退出）
	if GameState.loop > 2:
		print("AUTOPLAY：完成 %d 轮，冒烟测试通过，退出。" % (GameState.loop - 1))
		get_tree().quit()
		return
	match GameState.phase:
		"village":
			GameState.dial = 2
			if GameState.san < 60.0:
				GameState.san = minf(100.0, GameState.san + 15.0)
				GameState.protag_hp_penalty += 5
			if GameState.gold >= 50 and GameState.san_items < 2:
				GameState.gold -= 50
				GameState.san_items += 1
			GameState.party_hp.clear()
			GameState.in_run = true
			if GameState.boss_pending:
				# 败给父王后退回村：别再跑一整轮，直接回山门再战
				GameState.phase = "boss_gate"
			elif GameState.act2_gate:
				GameState.phase = "act2_finale"
			else:
				GameState.step = 1
				GameState.phase = "journey"
				GameState.road = ["", "", "", "", "", "", "", ""]
				GameState.current_offers = _draw_offers()
			_rebuild()
		"act2_finale":
			var hero_card: Dictionary = CardsDB.CARDS["boss_hero"].duplicate()
			GameState.pending_battle = hero_card
			get_tree().change_scene_to_file("res://scenes/combat/combat_scene.tscn")
		"act2_choice":
			# 自动测试：AUTOPLAY_SPARE=1 → 全程释放（验证真结局分支：SAN=100 零杀线）；
			# 否则 SAN>25 走审判（测 -15 与杀孽），否则释放——两条路都能踩到
			if OS.get_environment("AUTOPLAY_SPARE") == "1" or GameState.san <= 25.0:
				_do_release()
			else:
				_do_judgment()
		"demonize":
			# 自动测试：看完演出继续血洗终章
			GameState.phase = GameState.demonize_resume if GameState.demonize_resume != "" else "village"
			if GameState.phase == "journey":
				GameState.current_offers = _draw_offers()
			_rebuild()
		"act2_open":
			GameState.phase = "village"
			_rebuild()
		"journey":
			var pick: String = GameState.current_offers[randi() % GameState.current_offers.size()]
			_choose_card(pick)
		"boss_gate":
			GameState.pending_battle = {
				"id": "dragon_boss", "name": "恶龙", "unit": "dragon",
				"count": 1, "star": 5, "exp": 0, "gold": 0,
				"drop": "", "drop_p": 0.0, "boss": true,
			}
			get_tree().change_scene_to_file("res://scenes/combat/combat_scene.tscn")
		"truth":
			# 逐节拍自动推进；闸门（节拍 2）处按 SAN 走两个分支
			# 测试钩子：FORCE_LOW_SAN=1 强制低 SAN，验证幻觉结局分支
			if OS.get_environment("FORCE_LOW_SAN") == "1":
				GameState.san = 30.0
			if GameState.truth_beat == 2:
				if GameState.san >= 50.0:
					GameState.truth_beat = 3
					_rebuild()
				else:
					print("AUTOPLAY：幻觉结局触发，冒烟测试通过，退出。")
					get_tree().quit()
			elif GameState.truth_beat < 6:
				GameState.truth_beat += 1
				_rebuild()
			else:
				_awaken_to_village()
		"defeat":
			if GameState.pending_battle.has("boss"):
				# 自动测试：同一剧情战连败两次视为"对最差玩家过高"，退出
				GameState.dragon_defeats += 1
				if GameState.dragon_defeats >= 2:
					print("AUTOPLAY：两次败给剧情 Boss（%s），难度对最差玩家过高，测试退出。"
							% String(GameState.pending_battle.get("name", "?")))
					get_tree().quit()
					return
				GameState.pending_battle = {}
				GameState.phase = "village"
				_rebuild()
			elif GameState.gold >= 30:
				GameState.gold -= 30
				get_tree().change_scene_to_file("res://scenes/combat/combat_scene.tscn")
			else:
				_advance_step(true)
				_rebuild()
		"collapse":
			GameState.reset_run()
			_rebuild()
		"act2_fail":
			# 自动测试：处刑台战败=终局，报难度信号退出
			print("AUTOPLAY：处刑台战败（终局）——勇者战对最差玩家偏难，测试退出。")
			get_tree().quit()
		"act2_end":
			print("AUTOPLAY：第二幕·完（复仇线到达终点），冒烟测试通过，退出。")
			get_tree().quit()
		"act2_true":
			print("AUTOPLAY：真结局《不染雪》达成（SAN=100 零杀线），测试通过，退出。")
			get_tree().quit()
