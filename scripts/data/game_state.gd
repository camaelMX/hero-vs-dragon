extends Node
## ============================================================
## game_state.gd —— 全局运行状态（Autoload 单例，名字：GameState）
##
## 为什么需要它：灰盒 0-2 起，"村庄→选卡→战斗"跨场景进行。
## Godot 里 change_scene 会销毁当前场景，跨场景数据必须放在
## Autoload（引擎自动创建、全程存活的节点）里。
##
## 注册位置：project.godot [autoload] 段。
## 对应设计：GDD/05 SAN 与选择经济、GDD/06 怪卡系统。
## ============================================================

## 所在阶段：village=村庄整备 / journey=赶路选卡 / defeat=战败面板 / collapse=心防崩溃
var phase: String = "village"

## 是否处于"村庄→8步赶路"循环中（决定战斗场景读卡池还是读独立测试配置）
var in_run: bool = false

# ---- 第一幕叙事旗标（GDD/01 龙巢章节）----
var boss_pending: bool = false   # 8 步铺满 → 龙巢之门开启
var act1_cleared: bool = false   # 真相时刻已结算（觉醒或幻觉二选一）
var priest_dead: bool = false    # 牧师之死（被父王误杀）——之后队伍没有牧师
var awakened: bool = false       # 主角觉醒（SAN≥50 通过闸门）
var act2_gate: bool = false      # 第二幕·处刑台之门（回程 8 步铺满后开启）
var scale_reveal := false        # 幻觉结局演出已看过（循环回调）
var truth_beat: int = 0          # 真相时刻演出节拍（0-1=死亡与呼唤 2=闸门 3-6=觉醒线，见 run_scene._panel_truth）
var beats_seen: Array = []       # 第一幕路上已触发过的低语伏笔（GDD/01 固定节拍，一轮只演一次）
var dragon_defeats: int = 0      # 败给父王的次数（自动测试的退出判据；正式版可做"龙的怜悯"演出）

# ---- 第二幕·选择经济旗标（GDD/05 定稿 2026-11-07）----
var kill_sin: int = 0            # 杀孽：审判（处决降兵）+1 / 释放 +0 —— 复仇结局判定（GDD/07 第八节）
var demonized: bool = false      # 魔化：第二幕 SAN 归零 → 直接化身魔龙（新立绘+新技能组，血洗终章）
var demonize_resume: String = "" # 魔化演出结束后的去处（journey/act2_finale），跨场景重载要用全局存

var loop: int = 1          # 第几大轮（灰盒无限循环，0-3 会接入 Boss）
var step: int = 1          # 本轮第几步（1~8）
var dial: int = 2          # 挑战等级旋钮：1=祈祷 2=猎杀 3=血誓

# ---- SAN（GDD/05：第一幕 100 上限）----
var san: float = 100.0
var scale_marks: int = 0            # 鳞纹道数（安抚次数的视觉记号，伏笔资产）
var protag_hp_penalty: int = 0      # 安抚代价：主角永久扣减的最大生命

# ---- 资源 ----
var gold: int = 120
var san_items: int = 1              # 定神香（回 SAN）
var blood_potions: int = 2          # 血瓶（战斗内用）

# ---- 成长 ----
var exp_total: int = 0
var level: int = 1
var gear_atk: int = 0               # 灰盒占位"宝物"：直接加攻/防（正式版为遗物）
var gear_def: int = 0

# ---- 战斗衔接 ----
var pending_battle: Dictionary = {} # 本次要打的卡（cards_db 的一行）
var current_offers: Array = []      # 当前三选一的三张卡（场景重载后保持不变）
var last_result: String = ""        # combat 写回：victory / defeat / retreat
var party_hp: Dictionary = {}       # id -> 战斗间保留的 HP（GDD：胜不回血）
var road: Array = []                # 铺路：每步的卡 id（""=未打/撤退）


## 升级所需经验（累计值）：100 → 180 → 280 …（GDD/07 曲线）
func exp_threshold(lv: int) -> int:
	var t := 100
	var inc := 80
	for i in range(lv - 1):
		t += inc
		inc += 20
	return t


## 动态地板（GDD/06）：第 4~6 步最低 +1 档，第 7~8 步 +2 档
func floor_bonus() -> int:
	if step >= 7:
		return 2
	if step >= 4:
		return 1
	return 0


## 主角实际最大生命（=db 基础 - 安抚扣减 + 升级成长在战斗侧另算）
func protag_max_hp(base: int) -> int:
	return maxi(1, base - protag_hp_penalty)


## 开新一轮（幻觉/崩溃重开时调用）
func reset_run() -> void:
	phase = "village"
	in_run = false
	boss_pending = false
	act1_cleared = false
	priest_dead = false
	awakened = false
	act2_gate = false
	scale_reveal = false
	truth_beat = 0
	beats_seen = []
	dragon_defeats = 0
	kill_sin = 0
	demonized = false
	demonize_resume = ""
	loop = 1
	step = 1
	dial = 2
	san = 100.0
	scale_marks = 0
	protag_hp_penalty = 0
	gold = 120
	san_items = 1
	blood_potions = 2
	exp_total = 0
	level = 1
	gear_atk = 0
	gear_def = 0
	pending_battle = {}
	current_offers = []
	last_result = ""
	party_hp = {}
	road = []


## 冒烟测试加速旋钮：AUTOPLAY_FAST=1 时全局 8 倍速（Engine.time_scale），
## 只为 headless 冒烟测试提速，正常游玩不会设置这个环境变量。
func _ready() -> void:
	if OS.get_environment("AUTOPLAY_FAST") == "1":
		Engine.time_scale = 8.0


## 加经验并处理升级（模板自动成长在战斗场景生成单位时按 level 换算）
func add_exp(amount: int) -> Array:
	exp_total += amount
	var ups := 0
	while exp_total >= exp_threshold(level):
		exp_total -= exp_threshold(level)
		level += 1
		ups += 1
	return [ups, level] if ups > 0 else []
