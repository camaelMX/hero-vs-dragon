extends RefCounted
## ============================================================
## party_ai.gd —— AI 队友行为（灰盒最小行为树）
##
## GDD/04 第四节的行为逻辑灰盒化：
##   勇者：打血量最低的敌人（自保逻辑以后加）
##   牧师：有人 <35% 血 → 治疗；否则普攻
##   法师：敌人 ≥2 → AoE；否则单体法术
##
## 只"做决定"，不执行——执行在 combat_scene._resolve_action()。
## ============================================================


## 返回一个动作字典：
##   {"type":"attack", "target":Fighter}  普攻
##   {"type":"heal",   "target":Fighter}  治疗（牧师）
##   {"type":"aoe"}                        群攻（法师）
static func decide(actor, party: Array, enemies: Array) -> Dictionary:
	match String(actor.role):
		"enemy":
			# 敌 AI 目标选择（1000 局模拟校准，tools/sim_balance.py）：
			#   12% 狙牧师（猎杀治疗者——没有这个，"贪心"策略零风险）
			#   35% 偏向主角（顶在前面的人更常被打；v0.2 从 50% 下调）
			#   其余随机挑活着的队员
			var candidates := _alive(party)
			if candidates.is_empty():
				return {"type": "end"}
			var r := randf()
			if r < 0.12:
				for f in candidates:
					if f.role == "priest":
						return {"type": "attack", "target": f}
			elif r < 0.47:
				for f in candidates:
					if f.role == "protag":
						return {"type": "attack", "target": f}
			return {"type": "attack", "target": candidates.pick_random()}
		"priest":
			# 主要治疗（用户 2026-11-07 定稿）：牧师以奶为天职、伤害低；
			# 治疗线 40%（重伤才奶——实测 55% 线=每回合白嫖 60 血，第一幕零压力）
			var wounded = _lowest_ratio(party)
			if wounded != null and float(wounded.hp) / float(wounded.max_hp) <= 0.40:
				return {"type": "heal", "target": wounded}
			return {"type": "attack", "target": _lowest_hp(enemies)}
		"mage":
			var alive := enemies.filter(func(e): return e.is_alive())
			if alive.size() >= 2:
				return {"type": "aoe"}
			return {"type": "attack", "target": _lowest_hp(enemies)}
		_:
			# 勇者 & 其他我方：优先打残血（斩杀直觉）
			return {"type": "attack", "target": _lowest_hp(enemies)}


# ---- 工具：挑选目标 ----

static func _alive(list: Array) -> Array:
	return list.filter(func(f): return f.is_alive())


static func _lowest_hp(list: Array):
	var arr := _alive(list)
	if arr.is_empty():
		return null
	arr.sort_custom(func(a, b): return a.hp < b.hp)
	return arr[0]


static func _lowest_ratio(list: Array):
	var arr := _alive(list)
	if arr.is_empty():
		return null
	arr.sort_custom(func(a, b):
		return float(a.hp) / float(a.max_hp) < float(b.hp) / float(b.max_hp))
	return arr[0]


## 血量比例最低的"其他"队友（牧师治疗目标不含自己，v0.2）
static func _lowest_ratio_others(list: Array, exclude):
	var arr := _alive(list).filter(func(f): return f != exclude)
	if arr.is_empty():
		return null
	arr.sort_custom(func(a, b):
		return float(a.hp) / float(a.max_hp) < float(b.hp) / float(b.max_hp))
	return arr[0]
