extends Node2D
## ============================================================
## title_scene.gd —— 标题画面 + 序章介绍（白鸦）
##
## 流程：标题(主视觉图+Logo+菜单) → 开始游戏 → 序章三页(点击推进)
##       → 进入村庄(run_scene)。跳过序章可直达。
##
## 素材：主视觉 = ComfyUI 生成的 TITLE_key_visual.png（logo 文字由
##       Godot 渲染——AI 写中文字不可靠，图文分离是定稿管线）。
## 字体：系统 Noto Serif CJK Bold（衬线，配"史书感"）。缺字体自动回退。
## ============================================================

const RUN_SCENE := "res://scenes/run/run_scene.tscn"
const TITLE_IMG := "res://assets/art/cg_ai/TITLE_key_visual.png"

## 序章文案（主角有限视角——严禁出现"魔王之子/真相"等任何剧透字眼！
## 伏笔只允许藏在画面里（鳞片/白鸦），不藏在旁白里）
const SLIDES := [
	{
		"img": "res://assets/art/cg_ai/CG01_white_raven.png",
		"text": "圣都的钟声，撞了七下。\n白鸦从彩窗上惊起，掠过晨光。\n\n今天是个好日子——\n勇者大人出征，讨伐那条吞了北境的恶龙。",
	},
	{
		"img": "res://assets/art/cg_ai/CG00_march.png",
		"text": "而我是队伍里的第四个人。\n没有显赫的家世，没有传说的佩剑，\n只有一门没用的天赋：听得懂魔物说的话。\n\n教团说：就当个警哨吧。",
	},
	{
		"img": "res://assets/art/cg_ai/CG15_departure.png",
		"text": "据说，那条龙二十年前的旧伤还没愈合。\n据说，北境的雪里埋着一整个王国的名字。\n\n据说而已。\n——出发吧。",
	},
]

var _intro_layer: CanvasLayer = null
var _slide := -1
var autoplay := false


func _ready() -> void:
	autoplay = OS.get_environment("AUTOPLAY") == "1"
	_build_title()
	_start_bgm()
	if autoplay:
		_autoplay_step()


# ============================================================
# 标题画面
# ============================================================

func _build_title() -> void:
	# 主视觉背景（覆盖全屏）
	var bg := TextureRect.new()
	bg.texture = load(TITLE_IMG)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.size = Vector2(1280, 720)
	add_child(bg)

	# 底部压暗条（菜单可读性）
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.45)
	shade.position = Vector2(0, 520)
	shade.size = Vector2(1280, 200)
	add_child(shade)

	# Logo：主标题 + 副题（衬线粗体 + 阴影，天窗留白处）
	var serif := SystemFont.new()
	serif.font_names = ["Noto Serif CJK SC"]
	var t := Label.new()
	t.text = "勇者斗恶龙"
	t.add_theme_font_override("font", serif)
	t.add_theme_font_size_override("font_size", 92)
	t.add_theme_color_override("font_color", Color(0.93, 0.86, 0.62))
	t.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	t.add_theme_constant_override("shadow_offset_x", 4)
	t.add_theme_constant_override("shadow_offset_y", 5)
	t.position = Vector2(0, 36)
	t.size = Vector2(1280, 110)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(t)

	var sub := Label.new()
	sub.text = "～ 复 仇 ～"
	sub.add_theme_font_override("font", serif)
	sub.add_theme_font_size_override("font_size", 38)
	sub.add_theme_color_override("font_color", Color(0.82, 0.28, 0.24))
	sub.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	sub.add_theme_constant_override("shadow_offset_y", 3)
	sub.position = Vector2(0, 152)
	sub.size = Vector2(1280, 50)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(sub)

	# 菜单（开始前重置全局状态：从村庄"回到标题"再进来时不能带着上一局进度）
	_menu_btn("开始游戏（含序章）", Vector2(90, 556), func():
		GameState.reset_run()
		_start_intro())
	_menu_btn("跳过序章，直接开始", Vector2(90, 616), func():
		GameState.reset_run()
		_go_run())
	_menu_btn("退出游戏", Vector2(90, 676), func(): get_tree().quit())

	# 版本角标
	var v := Label.new()
	v.text = "灰盒 v0.3 · 全资产本地生成"
	v.position = Vector2(1040, 692)
	v.add_theme_font_size_override("font_size", 13)
	v.modulate = Color(1, 1, 1, 0.55)
	add_child(v)


func _menu_btn(text: String, pos: Vector2, on_pressed: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.position = pos
	b.size = Vector2(300, 46)
	b.add_theme_font_size_override("font_size", 18)
	b.pressed.connect(on_pressed)
	add_child(b)


func _start_bgm() -> void:
	var p := AudioStreamPlayer.new()
	p.stream = load("res://assets/audio/bgm/bgm_village.ogg")
	p.volume_db = -10.0
	add_child(p)
	p.finished.connect(p.play)  # 手动无缝循环
	p.play()


# ============================================================
# 序章（三页点击推进）
# ============================================================

func _start_intro() -> void:
	_slide = 0
	_intro_layer = CanvasLayer.new()
	add_child(_intro_layer)
	_render_slide()


func _render_slide() -> void:
	for c in _intro_layer.get_children():
		c.queue_free()
	var s: Dictionary = SLIDES[_slide]

	# 关键：装饰性控件全部 mouse_filter=IGNORE（穿透），
	# 否则全屏底图会吃掉点击，_unhandled_input 永远收不到翻页事件
	var bgc := ColorRect.new()
	bgc.color = Color(0.02, 0.02, 0.04)
	bgc.size = Vector2(1280, 720)
	bgc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_intro_layer.add_child(bgc)

	var img_path: String = s["img"]
	if img_path != "" and ResourceLoader.exists(img_path):
		var img := TextureRect.new()
		img.texture = load(img_path)
		img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		img.size = Vector2(1280, 720)
		img.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_intro_layer.add_child(img)
		var dim := ColorRect.new()
		dim.color = Color(0, 0, 0, 0.4)   # 压暗保证文字可读
		dim.size = Vector2(1280, 720)
		dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_intro_layer.add_child(dim)

	var serif := SystemFont.new()
	serif.font_names = ["Noto Serif CJK SC"]
	var txt := Label.new()
	txt.text = s["text"]
	txt.add_theme_font_override("font", serif)
	txt.add_theme_font_size_override("font_size", 24)
	txt.add_theme_color_override("font_color", Color(0.92, 0.92, 0.9))
	txt.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	txt.add_theme_constant_override("shadow_offset_y", 3)
	txt.position = Vector2(240, 500)
	txt.size = Vector2(820, 180)
	txt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_intro_layer.add_child(txt)

	var hint := Label.new()
	hint.text = "▼ 点击继续（空格亦可）"
	hint.position = Vector2(1000, 668)
	hint.add_theme_font_size_override("font_size", 15)
	hint.modulate = Color(1, 1, 1, 0.6)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_intro_layer.add_child(hint)

	# 全屏透明接点按钮：点击任意处翻页（比事件穿透可靠，按钮必收点击）
	var catcher := Button.new()
	catcher.flat = true
	catcher.size = Vector2(1280, 720)
	catcher.modulate = Color(1, 1, 1, 0.001)   # 视觉隐形，仍接收输入
	catcher.focus_mode = Control.FOCUS_NONE
	catcher.pressed.connect(_advance_intro)
	_intro_layer.add_child(catcher)

	var skip := Button.new()
	skip.text = "跳过序章 ▶"
	skip.position = Vector2(1120, 20)
	skip.pressed.connect(_finish_intro)
	_intro_layer.add_child(skip)   # 后加入 = 在透明按钮之上，可正常点


func _advance_intro() -> void:
	_slide += 1
	if _slide >= SLIDES.size():
		_finish_intro()
	else:
		_render_slide()


func _finish_intro() -> void:
	_intro_layer = null
	_go_run()


func _go_run() -> void:
	get_tree().change_scene_to_file(RUN_SCENE)


## 序章推进：空格 / 回车（鼠标走透明按钮）
func _unhandled_input(ev: InputEvent) -> void:
	if _intro_layer == null:
		return
	var keyed: bool = ev is InputEventKey and ev.pressed \
			and (ev.keycode == KEY_SPACE or ev.keycode == KEY_ENTER)
	if keyed:
		_advance_intro()


# ============================================================
# 自动冒烟测试：标题 → 跳序章 → 交给 run_scene 的 AUTOPLAY 收尾
# ============================================================

func _autoplay_step() -> void:
	await get_tree().create_timer(0.5).timeout
	print("AUTOPLAY：标题画面 OK，跳序章进村庄。")
	# 测试钩子：AUTOPLAY_SKIP_TO_ACT2=1 直接以"觉醒后回程"状态开跑
	# （无头冒烟测试第二幕全链路：人类卡池→单人→处刑台勇者战）
	if OS.get_environment("AUTOPLAY_SKIP_TO_ACT2") == "1":
		GameState.reset_run()
		GameState.awakened = true
		GameState.act1_cleared = true
		GameState.priest_dead = true
		GameState.level = 6
		GameState.san = 80.0
		GameState.gold = 200
		print("AUTOPLAY：跳入第二幕回程（Lv.6 单人）。")
	_go_run()
