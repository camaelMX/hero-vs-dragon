#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sim_act1.py —— 第一幕数值模拟（GDD/08 阶段0 第4步）

目的：
  1. 验证"选怪卡难度"机制是否成立——三种玩家策略在 1000 局下的表现：
     无脑苟(祈祷/选最低星) / 均衡(猎杀/随机) / 贪心(血誓/选最高星)
  2. 对比三种伤害公式，选出"高等级不趋零"的那一版：
     A: atk - def（现状，高等级趋 0）
     B: atk*2 - def（线性放大）
     C: atk * 60/(60+def)（乘法减伤，def 永远有意义）

验收标准（GDD/06 数值方法论）：
  * 贪心：Boss 胜率最高但战败率显著
  * 无脑苟：Boss 胜率 < 30%（选择弱怪惩罚成立）
  * 均衡：曲线平滑，胜率约 60~75%

运行：python3 tools/sim_act1.py   （在项目根目录执行）
"""
import random
import statistics
import sys

RUNS = 1000
QTE = (0.25, 0.45)          # (完美, 普通) 概率，剩余=失误（中等手法画像）
COUNTER = 1.6               # 完美防御反弹 = 主角防御 × 此系数
POTIONS = 2                 # 血瓶 2×60
POTION_HEAL = 60
REVIVE_RATIO = 0.3          # 战败重整比例（本次实测修正）
MAX_RETRY = 5               # 每张卡最多重试次数（之后放弃）
ROUNDS_CAP = 200            # 单场回合上限（保险丝）

# —— 单位基础值（与 scripts/data/units_db.gd 同步）——
BASE = {
    "hero":   dict(name="勇者", hp=220, atk=38, df=20, sp=14),
    "priest": dict(name="牧师", hp=120, atk=15, df=12, sp=11),
    "mage":   dict(name="法师", hp=110, atk=40, df=8,  sp=9),
    "protag": dict(name="主角", hp=150, atk=25, df=15, sp=10),
    "slime":  dict(name="史莱姆苗床", hp=40,  atk=12, df=2,  sp=6),
    "goblin": dict(name="哥布林斥候", hp=80,  atk=22, df=6,  sp=8),
    "wolf":   dict(name="雪狼",      hp=60,  atk=16, df=4,  sp=12),
    "orc":    dict(name="兽人猎手",  hp=140, atk=38, df=10, sp=9),
    "troll":  dict(name="暴怒巨魔",  hp=260, atk=58, df=14, sp=7),
    "guard":  dict(name="魔族亲卫",  hp=340, atk=72, df=18, sp=11),
    "dragon": dict(name="父王·恶龙", hp=2600, atk=75, df=28, sp=12),
}
GROW = dict(hp=18, atk=4, df=3)   # 每级成长

# —— 怪卡（与 scripts/data/cards_db.gd 同步）——
CARDS = {
    "slime":  dict(star=1, unit="slime", count=1, exp=20,  gold=8),
    "goblin": dict(star=2, unit="goblin", count=1, exp=50,  gold=25),
    "wolves": dict(star=2, unit="wolf", count=3, exp=65,  gold=20),
    "orc":    dict(star=3, unit="orc", count=1, exp=95,  gold=40),
    "troll":  dict(star=4, unit="troll", count=1, exp=170, gold=70),
    "guard":  dict(star=5, unit="guard", count=1, exp=240, gold=100),
}
PARTY_IDS = ["hero", "priest", "mage", "protag"]

STRATEGIES = {
    "无脑苟": dict(dial=1, pick="min"),
    "均衡":   dict(dial=2, pick="rand"),
    "贪心":   dict(dial=3, pick="max"),
}
FORMULAS = ["A:atk-def", "B:atk*2-def", "C:atk*60/(60+def)"]


# —— 可调参数（调参扫值用）：python3 tools/sim_act1.py <dragon_atk> <dragon_hp> [tg] ——
_DA = int(sys.argv[1]) if len(sys.argv) > 1 else 75
_DH = int(sys.argv[2]) if len(sys.argv) > 2 else 2600
BASE["dragon"].update(atk=_DA, hp=_DH)  # v0.2 基线：priest120/mage110/protag150
if len(sys.argv) > 3 and sys.argv[3] == "tg":
    BASE["troll"].update(hp=300, atk=66)
    BASE["guard"].update(hp=420, atk=84)


def exp_threshold(lv):
    t, inc = 100, 80
    for _ in range(lv - 1):
        t += inc
        inc += 20
    return t


def floor_bonus(step):
    return 2 if step >= 7 else (1 if step >= 4 else 0)


def damage(atk, df, formula, rng):
    """三种公式的统一入口；含 5% 暴击 ×1.5"""
    if formula.startswith("A"):
        base = atk - df
    elif formula.startswith("B"):
        base = atk * 2 - df
    else:
        base = atk * 60.0 / (60.0 + df)
    base = max(1.0, base)
    if rng.random() < 0.05:
        base *= 1.5
    return base


def make_party(level, hp_map):
    """按等级生成我方四人；血量沿用战斗间保留值"""
    party = []
    for uid in PARTY_IDS:
        b = BASE[uid]
        hp_grow = 22 if uid == "protag" else GROW["hp"]   # v0.2：主角愈合更快（血脉伏笔）
        u = dict(id=uid, side="p", name=b["name"],
                 max_hp=b["hp"] + hp_grow * (level - 1),
                 atk=b["atk"] + GROW["atk"] * (level - 1),
                 df=b["df"] + GROW["df"] * (level - 1),
                 sp=b["sp"], heal=60 if uid == "priest" else 0)
        u["hp"] = hp_map.get(uid, u["max_hp"])
        if uid == "protag":
            u["df"] += 0   # 宝物在模拟中忽略（方差小，不影响结论）
        party.append(u)
    return party


def make_enemies(card, rng):
    out = []
    b = BASE[card["unit"]]
    for i in range(card["count"]):
        out.append(dict(id="%s_%d" % (card["unit"], i), side="e",
                        name=b["name"], uid=card["unit"],
                        max_hp=b["hp"], hp=b["hp"], atk=b["atk"],
                        df=b["df"], sp=b["sp"], heal=0))
    return out


def fight(party, enemies, rng, formula):
    """回合制战斗简化复刻。返回 'win'/'lose'。直接改party/enemies的hp。"""
    potions = POTIONS
    order = sorted(party + enemies, key=lambda u: -u["sp"])
    for _ in range(ROUNDS_CAP * len(order)):
        alive_p = [u for u in party if u["hp"] > 0]
        alive_e = [u for u in enemies if u["hp"] > 0]
        if not alive_e:
            return "win"
        if not alive_p:
            return "lose"
        u = order[_ % len(order)]
        if u["hp"] <= 0:
            continue
        if u["side"] == "p":
            # 主角 AI（与游戏 autoplay 同策略）：低血先嗑药
            if u["id"] == "protag" and potions > 0 and u["hp"] < u["max_hp"] * 0.4:
                potions -= 1
                u["hp"] = min(u["max_hp"], u["hp"] + POTION_HEAL)
                continue
            if u["heal"] > 0:
                wounded = min(alive_p, key=lambda x: x["hp"] / x["max_hp"])
                if wounded["hp"] / wounded["max_hp"] <= 0.35:
                    wounded["hp"] = min(wounded["max_hp"], wounded["hp"] + u["heal"])
                    continue
                target = min(alive_e, key=lambda x: x["hp"])
            elif u["id"] == "mage" and len(alive_e) >= 2:
                for e in alive_e:
                    e["hp"] = max(0, int(e["hp"] - max(1, 28 - 0)))  # AoE 固定 28
                continue
            else:
                target = min(alive_e, key=lambda x: x["hp"])
            target["hp"] = max(0, int(target["hp"] - damage(u["atk"], target["df"], formula, rng)))
            # Boss 狂化（60%/30% 两档，攻+15 速+2）
            if target.get("boss"):
                r = target["hp"] / target["max_hp"]
                if r <= 0.6 and not target.get("r1"):
                    target["r1"] = True
                    target["atk"] += 15
                if r <= 0.3 and not target.get("r2"):
                    target["r2"] = True
                    target["atk"] += 15
        else:
            # 敌人：35% 偏向主角（v0.2 与游戏 AI 一致）
            if rng.random() < 0.35:
                t = next((x for x in alive_p if x["id"] == "protag"), None) or rng.choice(alive_p)
            else:
                t = rng.choice(alive_p)
            raw = damage(u["atk"], t["df"], formula, rng)
            if u.get("uid") == "dragon" and t["id"] == "protag":
                raw = max(1, raw / 2)          # 父王"留手"（伏笔）
            if t["id"] == "protag":
                r = rng.random()
                if r < QTE[0]:                  # 完美防御：免伤+反弹
                    u["hp"] = max(0, int(u["hp"] - max(1, t["df"] * COUNTER)))
                elif r < QTE[0] + QTE[1]:       # 普通防御：减半
                    t["hp"] = max(0, int(t["hp"] - raw / 2))
                else:                            # 失误：吃满
                    t["hp"] = max(0, int(t["hp"] - raw))
            else:
                t["hp"] = max(0, int(t["hp"] - raw))
    return "lose"   # 保险丝：超回合数判负


def run_once(strategy, formula, rng):
    """完整一局：村庄 → 8 步选卡 → Boss → 真相时刻。返回结局与统计。"""
    cfg = STRATEGIES[strategy]
    level, exp = 1, 0
    gold, san = 120, 100
    defeats = 0
    hp_map = {}     # 战斗间血量（村口出发时满血）

    # 村庄：教会回满
    hp_map = {}

    for step in range(1, 9):
        base = min(5, cfg["dial"] + floor_bonus(step))
        stars = set(range(base, min(5, base + 1) + 1))
        pool = [c for c in CARDS.values() if c["star"] in stars]
        offers = rng.sample(pool, min(3, len(pool)))
        if cfg["pick"] == "min":
            card = min(offers, key=lambda c: c["star"])
        elif cfg["pick"] == "max":
            card = max(offers, key=lambda c: c["star"])
        else:
            card = rng.choice(offers)

        # 战斗 + 战败重试（每次 -30金 -20SAN，30% 重整；金尽则放弃此卡）
        for attempt in range(MAX_RETRY + 1):
            party = make_party(level, hp_map)
            enemies = make_enemies(card, rng)
            result = fight(party, enemies, rng, formula)
            hp_map = {u["id"]: u["hp"] for u in party}
            if result == "win":
                exp += card["exp"]
                gold += card["gold"]
                while exp >= exp_threshold(level):
                    exp -= exp_threshold(level)
                    level += 1
                break
            defeats += 1
            san -= 20
            if san <= 0:
                return "collapse", level, defeats
            if gold >= 30:
                gold -= 30
                for uid, u in zip(PARTY_IDS, make_party(level, hp_map)):
                    if hp_map.get(uid, 0) <= 0:
                        hp_map[uid] = max(1, int(u["max_hp"] * REVIVE_RATIO))
            else:
                break   # 放弃此卡，前进
    # ---- Boss：先过 SAN 闸门 ----
    if san < 50:
        return "illusion", level, defeats
    card = dict(star=5, unit="dragon", count=1, exp=0, gold=0)
    for attempt in range(MAX_RETRY + 1):
        party = make_party(level, hp_map)
        enemies = make_enemies(card, rng)
        for e in enemies:
            e["boss"] = True
            e["uid"] = "dragon"
        result = fight(party, enemies, rng, formula)
        hp_map = {u["id"]: u["hp"] for u in party}
        if result == "win":
            return "awaken", level, defeats
        defeats += 1
        san -= 20
        if san < 50:
            return "illusion", level, defeats   # 重试中跌破闸门同样回落幻觉
        if gold >= 30:
            gold -= 30
            for uid, u in zip(PARTY_IDS, make_party(level, hp_map)):
                if hp_map.get(uid, 0) <= 0:
                    hp_map[uid] = max(1, int(u["max_hp"] * REVIVE_RATIO))
        else:
            return "illusion", level, defeats   # 没钱重整 → 封印撑住
    return "illusion", level, defeats


def main():
    rng = random.Random(20261107)
    print("每配置 %d 局 · QTE 画像：完美%.0f%%/普通%.0f%%/失误%.0f%%" %
          (RUNS, QTE[0] * 100, QTE[1] * 100, (1 - QTE[0] - QTE[1]) * 100))
    header = "%-10s %-16s %8s %9s %9s %9s %10s" % (
        "策略", "伤害公式", "觉醒率", "幻觉率", "崩溃率", "Boss前均级", "均战败次数")
    print(header)
    print("-" * len(header))
    for sname, _ in STRATEGIES.items():
        for f in FORMULAS:
            r2 = random.Random(rng.random())
            outcomes = {"awaken": 0, "illusion": 0, "collapse": 0}
            levels, defeat_counts = [], []
            for _ in range(RUNS):
                out, lv, dfc = run_once(sname, f, r2)
                outcomes[out] += 1
                levels.append(lv)
                defeat_counts.append(dfc)
            print("%-10s %-16s %7.1f%% %8.1f%% %8.1f%% %11.1f %11.1f" % (
                sname, f,
                outcomes["awaken"] / RUNS * 100,
                outcomes["illusion"] / RUNS * 100,
                outcomes["collapse"] / RUNS * 100,
                statistics.mean(levels),
                statistics.mean(defeat_counts)))


if __name__ == "__main__":
    main()
