extends Node
## ============================================================
## playtest_bot.gd —— 真人操作级试玩机器人（开发自测用，不进游戏体验）
##
## 与 AUTOPLAY=1 的区别：AUTOPLAY 在游戏逻辑层直接调函数（跳过 UI）；
## 本机器人走玩家走的路——合成鼠标事件点按钮（完整命中管线）、
## 合成键盘事件按 QTE（真实判定），像人一样读屏幕做决策。
##
## 注册：临时挂到 project.godot [autoload]（测完移除）。
## 开关（环境变量）：
##   BOT=1                     启用（不设则完全休眠，零开销）
##   BOT_STRATEGY=balanced|greedy|coward   选卡策略（默认 balanced）
##   BOT_QTE=good|mid|sloppy   QTE 手法画像（默认 mid）
##   BOT_TEST_RETREAT=1        第一场战斗测试撤退按钮
##   BOT_TEST_RETRY=1          第一次普通战败时测"原地重试"
##   BOT_INTRO_CLICK=1         序章用鼠标点击推进（否则用空格键）
##   BOT_CONTINUE=1            觉醒后继续验证第二幕循环一圈
##   BOT_BOSS_ONLY=1           跳过赶路，直奔 Boss 连打 N 场测胜率
##   BOT_BOSS_RUNS=6           Boss 专测场数
##   BOT_SHOTS=/tmp/bot_shots  截图目录
## 输出：BOT> 过程行；结束打印 BOT_RESULT {...} 后退出。
## ============================================================

const CardsDB := preload("res://scripts/data/cards_db.gd")

var enabled := false
var strategy := "balanced"
var qte_skill := "mid"
var test_retreat := false
var test_retry := false
var intro_click := false
var continue_after := false
var boss_only := false
var boss_runs := 6

var _cooldown := 0.0          # 两次点击之间的间隔（拟人手速）
var _t := 0.0
var _shots_dir := "/tmp/bot_shots"
var _shot_idx := 0
var _last_scene_path := ""
var _last_phase := ""
var _combat_busy_until := 0.0
var _qte_pressed := false     # 本次 QTE 是否已按键
var _key_release_pending := false
var _last_key: Key = KEY_SPACE
var _battle_count := 0        # 进入战斗场景的次数
var _stanced_battle := -1     # 本场战斗是否已切过反应预设
var _boss_wins := 0
var _boss_losses := 0
var _retries := 0
var _retreats := 0
var _used_retry_test := false
var _used_retreat_test := false
var _title_started := false
var _title_started_t := 0.0
var _space_logged := false
var _awakened_seen := false
var _result_printed := false
var _log_path := ""
var _log_f: FileAccess = null


## 直写文件日志：stdout 有缓冲，进程被杀时丢尾部；句柄常开 + 逐行 flush
func _log(msg: String) -> void:
	print(msg)
	if _log_path == "":
		return
	if _log_f == null:
		_log_f = FileAccess.open(_log_path, FileAccess.WRITE)
	if _log_f != null:
		_log_f.store_string(msg + "\n")
		_log_f.flush()


func _ready() -> void:
	enabled = OS.get_environment("BOT") == "1"
	if not enabled:
		set_process(false)
		return
	_log_path = OS.get_environment("BOT_LOG")
	if _log_path == "":
		_log_path = "/tmp/bot_live.log"
	randomize()
	var s := OS.get_environment("BOT_STRATEGY")
	if s != "":
		strategy = s
	var q := OS.get_environment("BOT_QTE")
	if q != "":
		qte_skill = q
	test_retreat = OS.get_environment("BOT_TEST_RETREAT") == "1"
	test_retry = OS.get_environment("BOT_TEST_RETRY") == "1"
	intro_click = OS.get_environment("BOT_INTRO_CLICK") == "1"
	continue_after = OS.get_environment("BOT_CONTINUE") == "1"
	boss_only = OS.get_environment("BOT_BOSS_ONLY") == "1"
	if OS.get_environment("BOT_BOSS_RUNS") != "":
		boss_runs = int(OS.get_environment("BOT_BOSS_RUNS"))
	if OS.get_environment("BOT_SHOTS") != "":
		_shots_dir = OS.get_environment("BOT_SHOTS")
	DirAccess.make_dir_recursive_absolute(_shots_dir)
	_log("BOT> 启动 strategy=%s qte=%s boss_only=%s shots=%s"
			% [strategy, qte_skill, boss_only, _shots_dir])
	if boss_only:
		_setup_boss_only()


## Boss 专测开局：等标题起来后，预置状态直奔龙巢山门（或处刑台）
func _setup_boss_only() -> void:
	await get_tree().create_timer(0.6).timeout
	var hero_kind: bool = OS.get_environment("BOT_BOSS_KIND") == "hero"
	GameState.reset_run()
	GameState.in_run = true
	GameState.level = 6 if hero_kind else 5
	GameState.san = 100.0
	GameState.gold = 300
	GameState.blood_potions = 2
	if hero_kind:
		# 第二幕处刑台：觉醒后回程终点，Lv.6 单人
		GameState.awakened = true
		GameState.act1_cleared = true
		GameState.priest_dead = true
		GameState.act2_gate = true
		GameState.phase = "act2_finale"
	else:
		GameState.boss_pending = true
		GameState.phase = "boss_gate"
	GameState.road = ["goblin", "goblin", "wolf", "wolf", "orc", "orc", "troll", "troll"]
	get_tree().change_scene_to_file("res://scenes/run/run_scene.tscn")
	print("BOT> BOSS_ONLY 专测：%s（第 %d/%d 场）"
			% ["Lv.6 处刑台·勇者" if hero_kind else "Lv.5 龙巢·父王",
			_boss_wins + _boss_losses + 1, boss_runs])


func _process(delta: float) -> void:
	_t += delta
	_cooldown = maxf(0.0, _cooldown - delta)
	if _key_release_pending:
		_key_release_pending = false
		_send_key(_last_key, false)
	# 看门狗：12 分钟硬超时
	if _t > 720.0:
		_finish("TIMEOUT")
		return
	var cs := get_tree().current_scene
	if cs == null:
		return
	# 用场景文件路径（.tscn）分发——脚本路径是 .gd，match 的 case 对不上
	var sp: String = cs.scene_file_path
	if sp != _last_scene_path:
		if _last_scene_path != "" and sp.ends_with("combat_scene.tscn"):
			_battle_count += 1
			_stanced_battle = -1
		_last_scene_path = sp
		_qte_pressed = false
		_combat_busy_until = 0.0
		_shot("scene_" + sp.get_file().get_basename())
		_log("BOT> 场景 → %s（t=%.0fs）" % [sp.get_file(), _t])
	# QTE 每帧盯针（不受点击冷却限制——玩家也是实时反应的）
	if sp.ends_with("combat_scene.tscn"):
		_tick_qte(cs)
	if _cooldown > 0.0:
		return
	match sp.get_file():
		"title_scene.tscn":
			_tick_title(cs)
		"run_scene.tscn":
			_tick_run(cs)
		"combat_scene.tscn":
			_tick_combat(cs)


# ============================================================
# 一、标题 / 序章
# ============================================================

func _tick_title(cs: Node) -> void:
	if boss_only:
		return
	# 自愈：点了开始 6 秒后场景还没变（点击没生效或按键路径失灵）→ 重置重试。
	# 重试的鼠标点击若落在序章透明全屏按钮上=翻页，两种失败都覆盖。
	if _title_started and _t - _title_started_t > 6.0:
		_log("BOT? 标题 6 秒未推进，重试点击路径")
		_title_started = false
	if not _title_started:
		var start := _find_btn(cs, "开始游戏（含序章）")
		if start != null:
			_title_started = true
			_title_started_t = _t
			_log("BOT> 点击【开始游戏（含序章）】")
			_click(start)
		return
	# 序章翻页：一律走鼠标点全屏透明按钮（实测有效）；
	# 键盘注入（parse_input_event）在本环境到不了 _unhandled_input，弃用
	var catcher := _find_btn_by_size(cs, Vector2(1280, 720))
	if catcher != null:
		_click(catcher)


# ============================================================
# 二、村庄 / 赶路 / 结局面板
# ============================================================

func _tick_run(cs: Node) -> void:
	var ph: String = GameState.phase
	if ph != _last_phase:
		_last_phase = ph
		_shot("phase_%s_%d" % [ph, _shot_idx])
		_log("BOT> 阶段 → %s loop=%d step=%d san=%d lv=%d 金=%d（t=%.0fs）"
				% [ph, GameState.loop, GameState.step, int(GameState.san),
				GameState.level, GameState.gold, _t])
		# 觉醒后继续跑：第二幕回程直达 act2_end（ACT2_END 收工）
		if ph == "truth" and int(GameState.truth_beat) == 2 and GameState.san >= 50.0:
			_awakened_seen = true
	if ph == "village" and GameState.awakened and not continue_after:
		_log("BOT> ★ 觉醒结局达成，回村（第二幕循环不测）")
		_finish("AWAKENED")
		return
	_match_phase_actions(cs, ph)


func _match_phase_actions(cs: Node, ph: String) -> void:
	match ph:
		"village":
			if boss_only:
				var d := _find_btn_prefix(cs, "出发")
				if d != null:
					_click(d)
				return
			# 顺序：定挑战等级 → 安抚（低 SAN 时）→ 买香 → 出发
			# 注意：按钮高亮是建面板时写死的，点击后不刷新——
			# 所以用 GameState.dial 判断是否已选，别看 modulate
			var want_dial := 2 if strategy == "balanced" \
					else (3 if strategy == "greedy" else 1)
			if GameState.dial != want_dial:
				var dial_name := "猎杀" if want_dial == 2 \
						else ("血誓" if want_dial == 3 else "祈祷")
				var dial_btn := _find_btn(cs, "挑战等级：" + dial_name)
				if dial_btn != null:
					_click(dial_btn)
					return
			if GameState.san < 75.0 and not GameState.priest_dead:
				var soothe := _find_btn_prefix(cs, "牧师安抚")
				if soothe != null:
					_log("BOT> 牧师安抚（SAN %d → +15）" % int(GameState.san))
					_click(soothe)
					return
			if GameState.gold >= 120 and GameState.san_items < 2:
				var buy := _find_btn_prefix(cs, "行商 · 定神香")
				if buy != null:
					_click(buy)
					return
			# 金币≥260：买装具提属性（行商上线后的主力消费）
			if GameState.gold >= 260:
				var gear := _find_btn_prefix(cs, "行商 · 锐牙坠饰")
				if GameState.gear_atk > GameState.gear_def:
					gear = _find_btn_prefix(cs, "行商 · 鳞纹臂甲")
				if gear != null:
					_click(gear)
					return
			var dep := _find_btn_prefix(cs, "出发")
			if dep != null:
				_log("BOT> 点击出发（金=%d 香=%d）" % [GameState.gold, GameState.san_items])
				_click(dep)
		"journey":
			if GameState.san < 45.0 and GameState.san_items > 0:
				var inc := _find_btn_prefix(cs, "定神香")
				if inc != null:
					_click(inc)
					return
			_pick_card(cs)
		"defeat":
			var is_boss: bool = GameState.pending_battle.has("boss")
			if is_boss:
				_boss_losses += 1
				print("BOT> 败给剧情Boss【%s】（累计 %d 胜 / %d 负）"
						% [String(GameState.pending_battle.get("name", "?")), _boss_wins, _boss_losses])
				if boss_only and _boss_wins + _boss_losses >= boss_runs:
					_finish("BOSS_STATS")
					return
				var back := _find_btn_prefix(cs, "退回")
				if back != null:
					_click(back)
			else:
				var want_retry := (GameState.gold >= 60)
				if test_retry and not _used_retry_test:
					want_retry = true
				var r := _find_btn_prefix(cs, "原地重试")
				if r != null and want_retry:
					_used_retry_test = true
					_retries += 1
					_log("BOT> 战败 → 原地重试（第 %d 次）" % _retries)
					_click(r)
				else:
					var drop := _find_btn_prefix(cs, "放弃此卡")
					if drop != null:
						_log("BOT> 战败 → 放弃此卡前进")
						_click(drop)
		"collapse":
			_shot("ending_collapse")
			_log("BOT> ★ 结局：心防崩溃（提前坍缩）")
			_finish("COLLAPSE")
		"boss_gate":
			var go := _find_btn_prefix(cs, "步入龙巢")
			if go != null:
				print("BOT> 第 %d 场父王战（lv=%d 血瓶=%d SAN=%d）"
						% [_boss_wins + _boss_losses + 1, GameState.level,
						GameState.blood_potions, int(GameState.san)])
				_click(go)
		"act2_open":
			var south := _find_btn_prefix(cs, "一个人，往南")
			if south != null:
				print("BOT> 第二幕开场：独行南下")
				_click(south)
		"act2_finale":
			var go2 := _find_btn_prefix(cs, "登上处刑台")
			if go2 != null:
				print("BOT> 第 %d 场勇者战（lv=%d 血瓶=%d SAN=%d）"
						% [_boss_wins + _boss_losses + 1, GameState.level,
						GameState.blood_potions, int(GameState.san)])
				_click(go2)
		"act2_fail":
			if boss_only:
				_boss_losses += 1
				print("BOT> 勇者战败（累计 %d 胜 / %d 负）" % [_boss_wins, _boss_losses])
				if _boss_wins + _boss_losses >= boss_runs:
					_finish("BOSS_STATS")
				else:
					_setup_boss_only()
			else:
				_shot("ending_act2_fail")
				print("BOT> ★ 处刑台战败——复仇·未竟（终局）")
				_finish("ACT2_FAIL")
		"act2_end":
			if boss_only:
				_boss_wins += 1
				print("BOT> 勇者战胜（累计 %d 胜 / %d 负）" % [_boss_wins, _boss_losses])
				if _boss_wins + _boss_losses >= boss_runs:
					_finish("BOSS_STATS")
				else:
					_setup_boss_only()
			else:
				_shot("ending_act2_end")
				print("BOT> ★ 第二幕·完——处刑台勇者战胜利")
				_finish("ACT2_END")
		"truth":
			if int(GameState.truth_beat) < 2:
				for txt in ["雪，落了下来", "……"]:
					var b := _find_btn(cs, txt)
					if b != null:
						_click(b)
						return
			else:
				_shot("ending_gate_san%d" % int(GameState.san))
				if GameState.san >= 50.0:
					_log("BOT> ★ 觉醒结局达成（SAN=%d，t=%.0fs）"
							% [int(GameState.san), _t])
					if boss_only:
						_boss_wins += 1
						_log("BOT> 父王战胜（累计 %d 胜 / %d 负）"
								% [_boss_wins, _boss_losses])
						if _boss_wins + _boss_losses >= boss_runs:
							_finish("BOSS_STATS")
						else:
							_setup_boss_only()
					elif continue_after:
						var back := _find_btn(cs, "回到村口")
						if back != null:
							_click(back)
					else:
						_finish("AWAKENED")
				else:
					_log("BOT> ★ 幻觉结局《白鸦》（SAN=%d）" % int(GameState.san))
					_finish("ILLUSION")


func _pick_card(cs: Node) -> void:
	# 赶路三选一：卡按钮 = size(170,250)，按 x 排序与 current_offers 一一对应
	var cards := _btns_with_size(cs, Vector2(170, 250))
	var offers: Array = GameState.current_offers
	if cards.is_empty() or offers.size() < cards.size():
		return
	cards.sort_custom(func(a, b): return a.position.x < b.position.x)
	var pick_i := 0
	if strategy != "balanced":
		var best_star := 99 if strategy == "coward" else -1
		for i in range(min(offers.size(), cards.size())):
			var star: int = int(CardsDB.CARDS[String(offers[i])]["star"])
			if strategy == "coward" and star < best_star:
				best_star = star
				pick_i = i
			elif strategy == "greedy" and star > best_star:
				best_star = star
				pick_i = i
	else:
		pick_i = randi() % cards.size()   # 均衡玩家：随机挑
	var card: Dictionary = CardsDB.CARDS[String(offers[pick_i])]
	_log("BOT> 选卡【%s】★%d" % [String(card["name"]), int(card["star"])])
	_click(cards[pick_i])


# ============================================================
# 三、战斗
# ============================================================

func _tick_combat(cs: Node) -> void:
	var buttons: Control = cs.ui_buttons
	if buttons == null:
		return
	if not buttons.visible:
		_combat_busy_until = 0.0
		return
	if _t < _combat_busy_until:
		return
	var protag = cs.protag
	# 1) 撤退测试钩子（第一场战斗的第一次指令）
	if test_retreat and not _used_retreat_test and _battle_count <= 1:
		_used_retreat_test = true
		_retreats += 1
		_log("BOT> 测试：点击撤退按钮")
		_combat_busy_until = _t + 1.5
		_click(cs.ui_btn_retreat)
		return
	# 2) 危险先嗑药
	if protag.hp < int(protag.max_hp * 0.35) and cs.potion_count > 0:
		_log("BOT> 主角 %.0f%% → 喝血瓶" % [100.0 * protag.hp / protag.max_hp])
		_combat_busy_until = _t + 1.0
		_click(cs.ui_btn_potion)
		return
	# 3) 每场战斗第一回合切一次反应预设（高手爱闪避；Boss 战稳健防御不切）
	if qte_skill == "good" and _stanced_battle != _battle_count \
			and not GameState.pending_battle.get("boss", false):
		_stanced_battle = _battle_count
		_log("BOT> 反应预设 → 闪避")
		_combat_busy_until = _t + 0.8
		_click(cs.ui_btn_dodge)
		return
	# 4) 默认进攻
	_combat_busy_until = _t + 1.0
	_click(cs.ui_btn_attack)


func _tick_qte(cs: Node) -> void:
	var qte = cs.ui_qte
	if qte == null or not qte._running:
		_qte_pressed = false
		return
	_shot("qte_active")   # QTE 窗口期截图（验证红"！"预警渲染）
	if _qte_pressed:
		return
	var p: float = qte._p
	var mode: int = qte._mode   # 0=防御(空格) 1=闪避(F)
	var center: float = qte.ZONE_CENTER
	var key := KEY_SPACE if mode == 0 else KEY_F
	# 画像=先掷骰定这一发的目标档位，再按针位置执行——
	# 与 sim_act1.py 的玩家画像一致（旧版按位置压线=从不失手，数据偏乐观）
	if not qte.has_meta("bot_grade"):
		var r := randf()
		match qte_skill:
			"good":
				qte.set_meta("bot_grade", 0 if r < 0.85 else 1)     # 完美85%/普通15%
			"mid":
				qte.set_meta("bot_grade", 0 if r < 0.25 else (1 if r < 0.70 else 2))
				# 完美25%/普通45%/失误30%（=模拟的中等手法画像）
			_:
				qte.set_meta("bot_grade", 0 if r < 0.10 else (1 if r < 0.40 else 2))
				# 手残：完美10%/普通30%/失误60%
	var target: int = qte.get_meta("bot_grade")
	var press_now := false
	match target:
		0: press_now = absf(p - center) <= 0.03          # 等完美区（半宽 0.04）
		1: press_now = p >= center - 0.10 and p < center - 0.045  # 普通区（半宽 0.12）
		_: press_now = p >= 0.25                          # 随手一按=失误
	if press_now:
		_qte_pressed = true
		_last_key = key
		_send_key(key, true)
		_key_release_pending = true


# ============================================================
# 四、输入合成 / 查找 / 截图 / 收尾
# ============================================================

func _click(btn: Button) -> void:
	if btn == null or not btn.visible or not btn.is_inside_tree():
		return
	var pos := btn.get_global_rect().get_center()
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	ev.position = pos
	ev.global_position = pos
	get_viewport().push_input(ev, true)
	var rel := InputEventMouseButton.new()
	rel.button_index = MOUSE_BUTTON_LEFT
	rel.pressed = false
	rel.position = pos
	rel.global_position = pos
	get_viewport().push_input(rel, true)
	_cooldown = 0.45


func _send_key(key: Key, down: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = key
	ev.physical_keycode = key
	ev.pressed = down
	Input.parse_input_event(ev)


func _find_btn(node: Node, text: String) -> Button:
	for c in node.get_children():
		if c is Button and c.text == text:
			return c
		var found := _find_btn(c, text)
		if found != null:
			return found
	return null


func _find_btn_prefix(node: Node, prefix: String) -> Button:
	for c in node.get_children():
		if c is Button and String(c.text).begins_with(prefix):
			return c
		var found := _find_btn_prefix(c, prefix)
		if found != null:
			return found
	return null


func _btns_with_size(node: Node, sz: Vector2) -> Array:
	var out: Array = []
	for c in node.get_children():
		if c is Button and c.size == sz:
			out.append(c)
		out.append_array(_btns_with_size(c, sz))
	return out


func _find_btn_by_size(node: Node, sz: Vector2) -> Button:
	for c in node.get_children():
		if c is Button and c.size == sz:
			return c
		var found := _find_btn_by_size(c, sz)
		if found != null:
			return found
	return null


func _shot(tag: String) -> void:
	if DisplayServer.get_name() == "headless":
		return   # 无头模式没有可读的帧缓冲，跳过截图
	var tex := get_viewport().get_texture()
	if tex == null:
		return
	var img := tex.get_image()
	if img == null:
		return
	_shot_idx += 1
	var path := "%s/%03d_%s.png" % [_shots_dir, _shot_idx, tag.replace("/", "_")]
	img.save_png(path)


func _finish(ending: String) -> void:
	if _result_printed:
		return
	_result_printed = true
	var summary := {
		"ending": ending,
		"strategy": strategy,
		"qte": qte_skill,
		"battles": _battle_count,
		"retries": _retries,
		"retreats": _retreats,
		"boss_wins": _boss_wins,
		"boss_losses": _boss_losses,
		"level": GameState.level,
		"san": int(GameState.san),
		"gold": GameState.gold,
		"loop": GameState.loop,
		"duration_s": int(_t),
	}
	_log("BOT_RESULT " + JSON.stringify(summary))
	_shot("final_" + ending.to_lower())
	get_tree().quit(0)
