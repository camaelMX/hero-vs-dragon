class_name Fighter
extends Node2D
## ============================================================
## fighter.gd —— 战斗单位基类（勇者/牧师/法师/主角/敌人通用）
##
## 一个 Fighter = 数据（hp/atk/def...） + 灰盒外观（色块 + 名字 + 血条）。
## 灰盒阶段用纯代码画色块，以后换成像素图时只需要改 _build_visual()，
## 战斗逻辑一行都不用动——这就是"数据/逻辑/表现"分层的好处。
##
## 伤害公式（占位，见 GDD/07）：
##   伤害 = max(1, 攻击力 - 目标防御力)；暴击 x1.5
## ============================================================

signal hp_changed(fighter: Fighter)   # 血量变化时广播（血条监听它刷新）
signal died(fighter: Fighter)         # 倒下时广播

# ---- 数值字段（由 setup() 填入）----
var id: String = ""
var display_name: String = "?"
var max_hp: int = 1
var hp: int = 1
var atk: int = 0
var def: int = 0
var speed: int = 0
var crit_chance: float = 0.0
var hit_chance: float = 0.95
var role: String = "enemy"        # protag / hero / priest / mage / enemy
var heal_amount: int = 0          # >0 表示会治疗（牧师）
var multi_hit: int = 1            # 攻击段数（>1 = 连击，每段独立 QTE——审判官 GDD/07）

# ---- 状态标记 ----
var is_stunned: bool = false      # 闪避 QTE 失败 → 失去下回合行动（GDD 04）
var pending_stance: String = "defend"  # 主角的反应预设："defend" / "dodge"

# ---- 灰盒外观（_build_visual 创建）----
var _body: ColorRect
var _hp_fill: ColorRect
var _hp_label: Label
var _name_label: Label
var _home: Vector2 = Vector2.ZERO   # 站位原点（冲刺演出后要回到这）
var arrow_y := -140.0               # 行动指示箭头的悬停高度（按体型在生成时覆盖）


## 用数值表里的一行初始化自己。
## pos = 站位（像素坐标），col = 无贴图时的色块颜色。
## tex_path 给定则用像素图代替色块（贴图脚底对齐站位原点）。
func setup(unit_id: String, db_row: Dictionary, pos: Vector2, col: Color,
		tex_path: String = "", sprite_scale: float = 1.6) -> void:
	id = unit_id
	display_name = db_row["name"]
	max_hp = int(db_row["max_hp"])
	hp = max_hp
	atk = int(db_row["atk"])
	def = int(db_row["def"])
	speed = int(db_row["speed"])
	crit_chance = float(db_row["crit"])
	hit_chance = float(db_row["hit"])
	role = String(db_row["role"])
	heal_amount = int(db_row["heal"])
	multi_hit = int(db_row.get("hits", 1))
	position = pos
	_color = col
	_tex_path = tex_path
	_sprite_scale = sprite_scale
	name = unit_id  # 场景树里显示可读名，方便调试


var _color: Color = Color.WHITE
var _tex_path: String = ""
var _sprite_scale: float = 1.6


func _ready() -> void:
	_home = position
	_build_visual()
	_refresh_bar()


## 冲刺演出：向目标方向扑到"半路"停住（不碰到对方），等调用方决定后续。
## reach = 冲到路程的百分比（0.28=普通攻击，0.45=Boss 预警冲得更近）
func lunge_toward(target_pos: Vector2, reach := 0.28) -> void:
	var mid := _home.lerp(target_pos, reach)
	var t := create_tween()
	t.tween_property(self, "position", mid, 0.12) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	await t.finished


## 演出结束，回到自己的站位
func return_home() -> void:
	var t := create_tween()
	t.tween_property(self, "position", _home, 0.16) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await t.finished


## 受击/预警用的白闪（modulate 拉高再弹回）
func flash_white() -> void:
	modulate = Color(2.2, 2.2, 2.2)
	var t := create_tween()
	t.tween_property(self, "modulate", Color.WHITE, 0.18)


## 是否还活着（存活判断全场到处用）
func is_alive() -> bool:
	return hp > 0


## 受击。amount 是已经算好防御减免之前的最终值。
func take_damage(amount: int) -> void:
	hp = maxi(0, hp - amount)
	hp_changed.emit(self)
	if hp <= 0:
		# 倒下：灰盒处理 = 变灰。以后换成倒地动画帧（GDD/09 MO 表的死亡帧）。
		modulate = Color(0.4, 0.4, 0.4)
		died.emit(self)
	else:
		_flash_hurt()


## 治疗（牧师治疗 / 血瓶共用）
func heal(amount: int) -> void:
	hp = mini(max_hp, hp + amount)
	hp_changed.emit(self)


## 发起一次攻击判定（掷命中、掷暴击、算伤害）。
## 注意：这里只"算"，不改目标血量——改血是 combat_scene 的职责，
## 因为命中/暴击/完美防御的结算流程都在那边。
##
## 伤害公式（1000 局模拟选定，tools/sim_act1.py，2026-11-07）：
##   伤害 = 攻击力 × 60 / (60 + 目标防御)，下限 1，暴击 ×1.5
## 乘法减伤：防御永远有意义，但不会把伤害压到 0——
##   def 6（哥布林）→ ×0.91；def 28（父王）→ ×0.68；def 60 → ×0.50
## 旧公式 atk−def 在高等级时趋零（def 成长跑赢固定数值敌人），已废弃。
func roll_attack(target: Fighter) -> Dictionary:
	var hit := randf() < hit_chance
	if not hit:
		return {"hit": false, "crit": false, "dmg": 0}
	var crit := randf() < crit_chance
	var dmg := int(maxf(1.0, atk * 60.0 / (60.0 + target.def)))
	if crit:
		dmg = int(dmg * 1.5)
	return {"hit": true, "crit": crit, "dmg": dmg}


# ------------------------------------------------------------
# 以下全是灰盒外观（色块小人），换美术资产时整体替换
# ------------------------------------------------------------

func _build_visual() -> void:
	# 有贴图就用像素小人（tools/gen_sprites.py 生成的占位美术），
	# 贴图缺失时退回色块——保证任何情况下场景都能跑。
	var tex: Texture2D = null
	if _tex_path != "":
		tex = load(_tex_path)
	if tex != null:
		var s := Sprite2D.new()
		s.texture = tex
		s.centered = false
		# 贴图脚底贴在站位原点上：向左偏移半宽、向上偏移全高
		s.offset = Vector2(-tex.get_width() / 2.0, float(-tex.get_height()))
		s.scale = Vector2(_sprite_scale, _sprite_scale)
		add_child(s)
	else:
		# 身体色块 48x64（与 GDD/09 约定的角色像素尺寸一致）
		_body = ColorRect.new()
		_body.color = _color
		_body.size = Vector2(48, 64)
		_body.position = Vector2(-24, -64)  # 以脚底为原点，向上画
		add_child(_body)

	# 名字牌
	_name_label = Label.new()
	_name_label.text = display_name
	_name_label.position = Vector2(-30, -92)
	_name_label.add_theme_font_size_override("font_size", 14)
	add_child(_name_label)

	# 血条：底 + 填充两层色块
	var bar_bg := ColorRect.new()
	bar_bg.color = Color(0.12, 0.12, 0.14)
	bar_bg.size = Vector2(96, 8)
	bar_bg.position = Vector2(-48, -16)
	add_child(bar_bg)

	_hp_fill = ColorRect.new()
	_hp_fill.color = Color(0.9, 0.25, 0.25)
	_hp_fill.size = Vector2(96, 8)
	_hp_fill.position = bar_bg.position
	add_child(_hp_fill)

	# 数字血量（调试期直观）
	_hp_label = Label.new()
	_hp_label.position = Vector2(-30, -10)
	_hp_label.add_theme_font_size_override("font_size", 11)
	add_child(_hp_label)


## 血量变化 → 重画血条。连接在 hp_changed 信号上。
func _refresh_bar() -> void:
	if _hp_fill == null:
		return
	var ratio := float(hp) / float(max_hp)
	_hp_fill.size.x = 96.0 * ratio
	_hp_label.text = "%d/%d" % [hp, max_hp]


## 受击闪红（0.12 秒，用 Tween 补间动画实现）
func _flash_hurt() -> void:
	modulate = Color(1.0, 0.3, 0.3)
	var t := create_tween()
	t.tween_property(self, "modulate", Color.WHITE, 0.12)
