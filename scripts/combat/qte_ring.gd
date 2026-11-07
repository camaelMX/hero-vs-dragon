extends Control
## ============================================================
## qte_ring.gd —— QTE 判定条（灰盒版：横扫 + 判定区）
##
## 机制（GDD/04 战斗系统）：
##   * 针从左到右匀速扫过一条判定条（约 0.9 秒）
##   * 防御 QTE（空格）：
##       按中【完美区】   → 完全免伤 + 反弹（防御力 x counter_mult）
##       按中【普通区】   → 减伤 50%
##       按偏 / 超时      → 吃满伤害
##   * 闪避 QTE（F）：
##       窗口比防御小得多 —— 高风险高回报
##       按中【成功区】   → 完全免伤
##       按偏 / 超时      → 吃满伤害 + 主角失去下回合行动
##
## 使用方式（combat_scene 调用）：
##   var grade := await qte_ring.begin(QTERing.Mode.DEFEND)
##   begin() 会一直等到玩家按键或超时，直接把结果返回给你。
##
## 以后换美术：把三个 ColorRect 换成动画帧/Sprite2D 即可，判定逻辑不动。
## ============================================================

signal resolved(mode: int, grade: int)

## 数值表（AUTOPLAY 概率等）
const DB := preload("res://scripts/data/units_db.gd")

## 判定结果等级。注意：闪避模式下没有"普通"，只有 PERFECT(成功) / MISS。
enum Grade { PERFECT, GOOD, MISS }
## 两种反应 QTE
enum Mode { DEFEND, DODGE }

# —— 判定参数（2026-11-07 三调定稿：扫针回 0.9s（用户自评手速），判定区保持放宽版）——
const SWEEP_DURATION := 0.9     # 针扫完全程的秒数（越小越难）
const ZONE_CENTER := 0.78       # 判定区中心在进度条的哪一侧（靠右 = 留反应时间）
const DEFEND_GOOD_HALF := 0.16  # 防御：普通区半宽（进度比例）
const DEFEND_PERFECT_HALF := 0.06
const DODGE_SUCCESS_HALF := 0.10  # 闪避：成功区（0.05→0.08→0.10 三调，用户实测拍板；
								  # 仍比防御普通区窄+失败吃满失衡——高风险高收益守恒）

# —— 运行时状态 ——
var _mode: int = Mode.DEFEND
var _p: float = 0.0             # 针的位置，0→1
var _running := false

# —— 外观节点 ——
var _zone_good: ColorRect
var _zone_perfect: ColorRect
var _needle: ColorRect
var _mode_label: Label     # 条上方的键位提示（"按【空格】防御！"）
var _result_label: Label   # 判定结果弹出（"完美防御！"/"失误…"）


func _ready() -> void:
	# 搭灰盒判定条：底条 + 两个判定区色块 + 一根针
	var bg := ColorRect.new()
	bg.color = Color(0.1, 0.1, 0.12)
	bg.size = Vector2(600, 36)
	add_child(bg)

	_zone_good = ColorRect.new()     # 防御普通区（绿）
	_zone_good.color = Color(0.25, 0.65, 0.3)
	_zone_good.size = Vector2(0, 36)
	add_child(_zone_good)

	_zone_perfect = ColorRect.new()  # 完美/闪避成功区（黄）
	_zone_perfect.color = Color(0.95, 0.85, 0.3)
	_zone_perfect.size = Vector2(0, 36)
	add_child(_zone_perfect)

	_needle = ColorRect.new()        # 针（白）
	_needle.color = Color.WHITE
	_needle.size = Vector2(4, 36)
	add_child(_needle)

	# 键位提示（条上方）——玩家必须一眼知道现在要按什么
	_mode_label = Label.new()
	_mode_label.position = Vector2(0, -36)
	_mode_label.size = Vector2(600, 30)
	_mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mode_label.add_theme_font_size_override("font_size", 20)
	add_child(_mode_label)

	# 判定结果弹出（条中央，短暂显示后淡出）
	_result_label = Label.new()
	_result_label.position = Vector2(0, 2)
	_result_label.size = Vector2(600, 32)
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_label.add_theme_font_size_override("font_size", 22)
	_result_label.visible = false
	add_child(_result_label)


## 启动一次 QTE。**协程**：挂起直到玩家按键或超时，返回 Grade。
func begin(mode: int) -> int:
	_mode = mode
	_p = 0.0
	_running = true
	_layout_zones()
	_update_needle()
	# 键位提示：防御=空格（金） / 闪避=F（青）
	if mode == Mode.DEFEND:
		_mode_label.text = "防御 QTE —— 按【空格】！"
		_mode_label.modulate = Color(1.0, 0.85, 0.4)
	else:
		_mode_label.text = "闪避 QTE —— 按【F】！（窗口更小！）"
		_mode_label.modulate = Color(0.5, 0.9, 1.0)
	_result_label.visible = false

	# 自动测试模式（AUTOPLAY=1）：不等人，随机掷一个结果。
	# 只在命令行冒烟测试里生效，正常游玩走不到这个分支。
	if OS.get_environment("AUTOPLAY") == "1":
		await get_tree().create_timer(0.1).timeout
		var g := _autoplay_grade()
		_finish(g)
		return g

	# 正常游玩：等待 resolved 信号（由 _process 里按键/超时触发）。
	# await 一个多参数信号会返回"参数数组"，所以取 [1]。
	var result: Array = await resolved
	return int(result[1])


func _process(delta: float) -> void:
	if not _running:
		return
	# 自动测试模式不响应真实按键，避免测试时窗口抢焦点报错
	if OS.get_environment("AUTOPLAY") == "1":
		return
	_p += delta / SWEEP_DURATION
	_update_needle()
	# 1. 玩家按了对应的键 → 按针的位置判定。
	#    宽容输入（用户实测"见！就按=白给"）：针前半程的按键直接忽略、
	#    不判定不消耗——红"!"是预兆，玩家可以提前按住，等针进区再补按。
	var action_name := "qte_defend" if _mode == Mode.DEFEND else "qte_dodge"
	if Input.is_action_just_pressed(action_name):
		if _p < 0.45:
			return   # 太早：不判定（判定区最早也在 0.62 才开始）
		_finish(_grade_for_needle())
		return
	# 2. 针扫到底还没按 → 判 MISS
	if _p >= 1.0:
		_finish(Grade.MISS)


# ------------------------------------------------------------

func _finish(grade: int) -> void:
	_running = false
	# 判定结果弹出：文字 + 颜色，短暂停留后淡出（演出反馈的核心一环）
	_result_label.visible = true
	_result_label.modulate = Color.WHITE
	match grade:
		Grade.PERFECT:
			_result_label.text = "完美防御！" if _mode == Mode.DEFEND else "闪避成功！"
			_result_label.modulate = Color(1.0, 0.85, 0.3) if _mode == Mode.DEFEND \
					else Color(0.5, 0.9, 1.0)
		Grade.GOOD:
			_result_label.text = "普通防御"
			_result_label.modulate = Color.WHITE
		_:
			_result_label.text = "失误…"
			_result_label.modulate = Color(1.0, 0.35, 0.3)
	var t := create_tween()
	t.tween_interval(0.22)
	t.tween_property(_result_label, "modulate:a", 0.0, 0.2)
	resolved.emit(_mode, grade)


## 按针的位置给出判定
func _grade_for_needle() -> int:
	var dist: float = absf(_p - ZONE_CENTER)
	if _mode == Mode.DEFEND:
		if dist <= DEFEND_PERFECT_HALF:
			return Grade.PERFECT
		if dist <= DEFEND_GOOD_HALF:
			return Grade.GOOD
		return Grade.MISS
	else:
		# 闪避只有一个窄成功区
		return Grade.PERFECT if dist <= DODGE_SUCCESS_HALF else Grade.MISS


## 把判定区画到条上
func _layout_zones() -> void:
	if _mode == Mode.DEFEND:
		_place_zone(_zone_good, DEFEND_GOOD_HALF * 2.0)
		_place_zone(_zone_perfect, DEFEND_PERFECT_HALF * 2.0)
	else:
		_place_zone(_zone_good, 0.0)  # 闪避没有普通区
		_place_zone(_zone_perfect, DODGE_SUCCESS_HALF * 2.0)


func _place_zone(zone: ColorRect, width_ratio: float) -> void:
	zone.size.x = 600.0 * width_ratio
	zone.position.x = 600.0 * (ZONE_CENTER - width_ratio / 2.0)
	zone.visible = width_ratio > 0.0


func _update_needle() -> void:
	_needle.position.x = clampf(600.0 * _p, 0, 596)


## 冒烟测试用的随机判定（概率表见 units_db.AUTOPLAY_QTE）
func _autoplay_grade() -> int:
	var r := randf()
	if _mode == Mode.DEFEND:
		if r < DB.AUTOPLAY_QTE["defend"][0]:
			return Grade.PERFECT
		if r < DB.AUTOPLAY_QTE["defend"][1]:
			return Grade.GOOD
		return Grade.MISS
	else:
		return Grade.PERFECT if r < DB.AUTOPLAY_QTE["dodge"][0] else Grade.MISS
