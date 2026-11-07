#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sim_balance.py —— 第一幕数值模拟（三种玩家策略 × 1000 局）

对应 GDD/08 阶段0 第4步。目的：
  1. 验证"贪心最优但会翻车、无脑苟打不过 Boss"的设计曲线
  2. 校准伤害公式（旧 atk-def 高等级趋零 → 新 atk*40/(40+def)）
  3. 用数据决定 Boss/曲线参数是否要拧

策略定义：
  苟   dial=1，每步选星级最低的卡，SAN<70 且有钱就买香，缺 SAN 就安抚
  均衡 dial=2，选星级中位的卡，SAN<60 买香，安抚少量用
  贪心 dial=3，选"能打赢的最高星"卡，从不安抚（保最大生命）

判定口径（与游戏一致）：
  战败 = SAN-20 原地重试（血不回）；SAN=0 心防崩溃；8 步后打父王；
  真相时刻 SAN>=50 觉醒，<50 幻觉结局。教会每轮免费回满。

运行：python3 tools/sim_balance.py   （在项目根目录执行）
"""
import random
import sys

RUNS = 1000

# ---- 与 units_db.gd 同步的数值（改这里前先改游戏！）----
UNITS = {
    "hero":    {"hp": 220, "atk": 38, "def": 20, "spd": 14},
    "priest":  {"hp": 150, "atk": 15, "def": 12, "spd": 11, "heal": 60},
    "mage":    {"hp": 130, "atk": 40, "def": 8,  "spd": 9},
    "protag":  {"hp": 120, "atk": 25, "def": 15, "spd": 10},
    "slime":   {"hp": 40,  "atk": 12, "def": 2,  "spd": 6},
    "goblin":  {"hp": 80,  "atk": 22, "def": 6,  "spd": 8},
    "wolf":    {"hp": 60,  "atk": 16, "def": 4,  "spd": 12},
    "orc":     {"hp": 140, "atk": 38, "def": 10, "spd": 9},
    "troll":   {"hp": 260, "atk": 58, "def": 14, "spd": 7},
    "guard":   {"hp": 340, "atk": 72, "def": 18, "spd": 11},
    "dragon":  {"hp": 2200, "atk": 77, "def": 28, "spd": 12},
}

CARDS = {
    "slime":  {"star": 1, "group": ["slime"] * 3, "exp": 35, "gold": 12},
    "goblin": {"star": 2, "group": ["goblin"] * 3, "exp": 70, "gold": 35},
    "wolves": {"star": 2, "group": ["wolf"] * 3, "exp": 85, "gold": 30},
    "orc":    {"star": 3, "group": ["orc", "orc", "goblin"], "exp": 130, "gold": 55},
    "troll":  {"star": 4, "group": ["troll", "goblin", "goblin"], "exp": 210, "gold": 90},
    "guard":  {"star": 5, "group": ["guard", "wolf", "wolf"], "exp": 300, "gold": 130},
}

# 新伤害公式：atk * K / (K + def)。K 越大越接近旧减法。
K = 60
EXP_STEP0, EXP_INC0 = 100, 80   # 升级曲线：100, 180, 280 ...


def dmg(atk, dfn, rng):
    """新公式：乘性减免，高 def 趋近 0.35*atk 而不是负数"""
    if rng.random() >= 0.95:
        return 0  # miss
    d = atk * K / (K + dfn)
    if rng.random() < 0.05:
        d *= 1.5  # crit
    return max(1, int(d))


def level_exp(lv):
    t, inc = EXP_STEP0, EXP_INC0
    for _ in range(lv - 1):
        t += inc
        inc += 20
    return t


def simulate(strategy, rng):
    """跑一局，返回 (结局, 达到Boss, 打赢Boss, 最终SAN, 等级)"""
    dial = {"gou": 1, "mid": 2, "greed": 3}[strategy]
    lv = 1
    exp = 0
    gold = 120
    san = 100.0
    maxhp_pen = 0
    # 队伍 [hp, ]模板
    team = {u: dict(UNITS[u]) for u in ("hero", "priest", "mage", "protag")}

    def apply_level():
        nonlocal lv, exp
        while exp >= level_exp(lv):
            exp -= level_exp(lv)
            lv += 1
            for t in team.values():
                t["_bonus"] = t.get("_bonus", 0) + 1

    def fight(group, boss=False):
        """抽象战斗：返回 True=胜利。血量写回 team（胜败都不回）。"""
        nonlocal gold
        # 敌方（Boss 分支在前——group 为 None）
        if boss:
            d = UNITS["dragon"]
            foes = [dict(d, hp=d["hp"], max=d["hp"])]
        else:
            foes = [dict(UNITS[u], hp=UNITS[u]["hp"], max=UNITS[u]["hp"])
                    for u in group]
        # 我方有效数值（等级成长 +18/+4/+3 每级；安抚扣主角上限）
        me = {}
        for k, t in team.items():
            b = t.get("_bonus", 0)
            mx = t["hp"] + 18 * b
            if k == "protag":
                mx -= maxhp_pen
            me[k] = {"hp": mx, "max": mx, "atk": t["atk"] + 4 * b,
                     "def": t["def"] + 3 * b, "heal": t.get("heal", 0)}
        while True:
            # ---- 我方行动 ----
            alive_foes = [f for f in foes if f["hp"] > 0]
            if not alive_foes:
                return True
            for k in sorted(me, key=lambda x: -UNITS[x]["spd"]):
                u = me[k]
                if u["hp"] <= 0:
                    continue
                if k == "priest" and u["heal"]:
                    wounded = sorted((v for v in me.values() if 0 < v["hp"] < v["max"] * 0.35),
                                     key=lambda v: v["hp"] / v["max"])
                    if wounded:
                        wounded[0]["hp"] = min(wounded[0]["max"], wounded[0]["hp"] + u["heal"])
                        continue
                tgt = min(alive_foes, key=lambda f: f["hp"])
                tgt["hp"] -= dmg(u["atk"], tgt["def"], rng)
                alive_foes = [f for f in foes if f["hp"] > 0]
                if not alive_foes:
                    return True
            # ---- 敌方行动（50% 偏向主角，12% 狙牧师；Boss 每轮两动+狂化）----
            acts = 2 if boss else 1
            for _ in range(acts):
                alive_me = [k for k, v in me.items() if v["hp"] > 0]
                if not alive_me:
                    return False
                r = rng.random()
                if r < 0.12 and "priest" in alive_me:
                    tk = "priest"          # 猎杀治疗者——贪心策略的风险来源
                elif r < 0.75 and "protag" in alive_me:
                    tk = "protag"
                else:
                    tk = rng.choice(alive_me)
                for f in foes:
                    if f["hp"] <= 0:
                        continue
                    raw = dmg(f["atk"], me[tk]["def"], rng)
                    if boss and tk == "protag":
                        raw = max(1, raw // 2)  # 留手
                    if boss:
                        ratio = f["hp"] / f["max"]
                        if ratio <= 0.3:
                            raw = int(raw * 1.4)  # 狂化等效
                        elif ratio <= 0.6:
                            raw = int(raw * 1.18)
                    me[tk]["hp"] -= raw
                    break
                if all(v["hp"] <= 0 for v in me.values()):
                    return False

    # ---- 大轮循环 ----
    loops = 0
    while loops < 3:
        loops += 1
        # 教会回满
        for t in team.values():
            t.pop("_bonus", None) if False else None
        team_bonus_snapshot = {k: v.get("_bonus", 0) for k, v in team.items()}
        for k in team:
            team[k]["_bonus"] = team_bonus_snapshot[k]
        for step in range(1, 9):
            floorb = 2 if step >= 7 else (1 if step >= 4 else 0)
            base = min(5, dial + floorb)
            pool = [c for c, cd in CARDS.items()
                    if base <= cd["star"] <= min(5, base + 1)]
            if strategy == "gou":
                pick = min(pool, key=lambda c: CARDS[c]["star"])
            elif strategy == "greed":
                pick = max(pool, key=lambda c: CARDS[c]["star"])
            else:
                pick = sorted(pool, key=lambda c: CARDS[c]["star"])[len(pool) // 2]
            card = CARDS[pick]
            # 战斗（战败重试：SAN-20，无回复）
            while not fight(card["group"]):
                san -= 10
                if san <= 0:
                    return ("collapse", True, False, san, lv)
            exp += card["exp"]
            gold += card["gold"]
            apply_level()
        # ---- 父王 ----
        # 设计裁定：Boss 战期间 SAN 归零 = 被恐惧压垮 = 幻觉结局（循环），
        # 而非"心防崩溃"——崩溃只属于中途连败
        while not fight(None, boss=True):
            san -= 10
            if san <= 0:
                return ("illusion", True, False, 0, lv)
        # ---- 真相时刻 ----
        # SAN 管理： Village 阶段买香/安抚
        if strategy == "gou":
            while gold >= 50 and san < 85:
                gold -= 50
                san = min(100, san + 25)
            while san < 70:
                san = min(100, san + 15)
                maxhp_pen += 5
        elif strategy == "mid":
            while gold >= 50 and san < 85:
                gold -= 50
                san = min(100, san + 25)
            if san < 55:
                san = min(100, san + 15)
                maxhp_pen += 5
        if san >= 50:
            return ("awakened", True, True, san, lv)
        return ("illusion", True, True, san, lv)
    return ("timeout", True, False, san, lv)


def main():
    print(f"伤害公式 K={K}（atk*{K}/({K}+def)）  每策略 {RUNS} 局")
    print(f"{'策略':<6}{'觉醒%':>8}{'幻觉%':>8}{'崩溃%':>8}{'达Boss%':>9}"
          f"{'胜Boss%(条件)':>14}{'均Lv':>7}{'均SAN':>7}")
    for st in ("gou", "mid", "greed"):
        cnt = {"awakened": 0, "illusion": 0, "collapse": 0}
        reach = win = 0
        san_sum = lv_sum = 0
        for i in range(RUNS):
            rng = random.Random(i * 7919 + hash(st) % 1000)
            r, reach_b, win_b, san, lv = simulate(st, rng)
            cnt[r] = cnt.get(r, 0) + 1
            if reach_b:
                reach += 1
                win += 1 if win_b else 0
            san_sum += san
            lv_sum += lv
        n = RUNS
        boss_cond = (win / reach * 100) if reach else 0
        print(f"{st:<6}{cnt['awakened']/n*100:>7.1f}%{cnt['illusion']/n*100:>7.1f}%"
              f"{cnt['collapse']/n*100:>7.1f}%{reach/n*100:>8.1f}%"
              f"{boss_cond:>13.1f}%{lv_sum/n:>7.1f}{san_sum/n:>7.1f}")


if __name__ == "__main__":
    main()
