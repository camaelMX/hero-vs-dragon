extends RefCounted
## ============================================================
## cards_db.gd —— 怪卡定义表（灰盒 0-2）
##
## 每张卡 = 一次可选的遭遇（GDD/06）：
##   star : 威胁星级（1~5），决定掉落档位与动态地板
##   unit : 对应 units_db.UNITS 的敌人 id
##   count: 出战数量（雪狼群=3 只，法师 AoE 的用武之地）
##   exp/gold : 奖励（凸增长：星级越高越肥，GDD/07 表）
##   drop : 掉落类别  "san_item"=定神香 / "gear"=宝物占位 / ""=无
##   drop_p: 掉落概率
## 卡面美术 = card_tier{1,2,3}.png（星级 1-2 用木框、3 用铁框、4-5 用血框）
## ============================================================

const CARDS := {
	# group = 出战编制（混合单位）——解决"我方 4 人 vs 敌方 1 人"的动作经济失衡：
	# 讨伐队的对手从来不是单只怪，而是成建制的猎队/狼群/亲卫小队（GDD/01：它们不撤退）
	"slime": {
		"name": "史莱姆苗床", "star": 1, "unit": "slime", "count": 1,
		"group": ["slime", "slime", "slime"],
		"exp": 35, "gold": 12, "drop": "san_item", "drop_p": 0.3,
	},
	"goblin": {
		"name": "哥布林斥候小队", "star": 2, "unit": "goblin", "count": 1,
		"group": ["goblin", "goblin", "goblin"],
		"exp": 70, "gold": 35, "drop": "", "drop_p": 0.0,
	},
	"wolves": {
		"name": "雪狼群", "star": 2, "unit": "wolf", "count": 3,
		"group": ["wolf", "wolf", "wolf"],
		"exp": 85, "gold": 30, "drop": "san_item", "drop_p": 0.3,
	},
	"orc": {
		"name": "兽人猎队", "star": 3, "unit": "orc", "count": 1,
		"group": ["orc", "orc", "goblin"],
		"exp": 130, "gold": 55, "drop": "gear", "drop_p": 0.5,
	},
	"troll": {
		"name": "暴怒巨魔", "star": 4, "unit": "troll", "count": 1,
		"group": ["troll", "goblin", "goblin"],
		"exp": 210, "gold": 90, "drop": "gear", "drop_p": 1.0,
	},
	"guard": {
		"name": "魔族亲卫", "star": 5, "unit": "guard", "count": 1,
		"group": ["guard", "wolf", "wolf"],
		"exp": 300, "gold": 130, "drop": "gear", "drop_p": 1.0,
	},
	# ---- 剧情卡：第一幕终 Boss（星 6 不会进普通抽卡池，走"龙巢之门"入口）----
	# Boss 动作经济补偿在 combat_scene：龙每轮行动两次
	"boss_dragon": {
		"name": "恶龙", "star": 6, "unit": "dragon", "count": 1,
		"exp": 0, "gold": 0, "drop": "", "drop_p": 0.0, "boss": true,
	},

	# ============================================================
	# 第二幕·回程卡池（觉醒后抽的只有人类——教团与王国的围剿）
	# ============================================================
	"deserters": {
		"name": "征讨军溃兵", "star": 3, "unit": "soldier", "count": 1,
		"group": ["soldier", "soldier", "soldier"],
		"exp": 130, "gold": 55, "drop": "san_item", "drop_p": 0.4,
	},
	"patrol": {
		"name": "边境巡逻队", "star": 4, "unit": "officer", "count": 1,
		"group": ["officer", "soldier"],
		"exp": 210, "gold": 90, "drop": "gear", "drop_p": 0.5,
	},
	"paladins": {
		"name": "圣骑士小队", "star": 4, "unit": "paladin", "count": 1,
		"group": ["paladin", "soldier"],
		"exp": 230, "gold": 95, "drop": "san_item", "drop_p": 0.4,
	},
	"inquisition": {
		"name": "审判庭特务", "star": 5, "unit": "inquisitor", "count": 1,
		"group": ["inquisitor", "paladin"],
		"exp": 300, "gold": 130, "drop": "gear", "drop_p": 1.0,
	},
	# ---- 第二幕终点：处刑台·勇者单挑（星 6 剧情卡，走"处刑台"入口）----
	"boss_hero": {
		"name": "勇者", "star": 6, "unit": "hero_foe", "count": 1,
		"exp": 0, "gold": 0, "drop": "", "drop_p": 0.0,
		"boss": true, "act2": true,
	},
}


## 第二幕·回程卡池 id（觉醒后 _draw_offers 只从这里抽）
const ACT2_CARDS := ["deserters", "patrol", "paladins", "inquisition"]


## 卡面框 tier：1=木(祈祷) 2=铁(猎杀) 3=血(血誓)
static func frame_tier(star: int) -> int:
	if star <= 2:
		return 1
	if star == 3:
		return 2
	return 3


## 按允许星级抽 3 张不同的卡（候选不足时允许重复补位）
## act2=false 第一幕（魔物池） / act2=true 第二幕回程（人类围剿池）
static func draw_offers(allowed_stars: Array, act2 := false) -> Array:
	var pool := []
	for id in CARDS:
		if (id in ACT2_CARDS) != act2:
			continue   # 两幕卡池严格隔离：第一幕不抽人类，第二幕不抽魔物
		if int(CARDS[id]["star"]) in allowed_stars:
			pool.append(id)
	if pool.is_empty():
		for id in CARDS:   # 兜底：理论不可达（allowed 至少含 1~5 之一）
			if (id in ACT2_CARDS) != act2:
				continue
			if CARDS[id].has("boss"):
				continue   # 剧情卡不走普通抽卡池
			pool.append(id)
	var offers := []
	while offers.size() < 3:
		var pick: String = pool[randi() % pool.size()]
		if not offers.has(pick) or pool.size() < 3:
			offers.append(pick)
	return offers
