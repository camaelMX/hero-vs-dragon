#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_demon_dragon.py —— 主角·魔龙战斗形态贴图（MO-13，GDD/09）

为什么单独一个文件：unit_dragon.png 是"父王"的灰紫配色，
魔龙要一眼区分身份——暗紫红黑的躯体 + 灼红腹纹 + 断裂的锁链挂饰
（锁链=第二幕手臂鳞纹的化身演出呼应，GDD/03 魔化觉醒）。

复用 gen_sprites.py 的极简像素画框架（Canvas/save_png/双色调+黑描边），
保持和其余战斗小人同一画风。

运行：python3 tools/gen_demon_dragon.py   （在项目根目录执行）
"""
import os
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)

import gen_sprites as gs   # Canvas / shade / OUT 都从这里拿

OUT = os.path.join(gs.OUT, "sprites")


def draw_demon_dragon():
    """主角·魔龙（血洗终章玩家形态）：160x120，比父王更扁长凶戾"""
    cv = gs.Canvas(160, 120)
    # 配色三件套：暗紫躯体 / 近黑鳞背 / 灼红腹纹与瞳
    main = (58, 34, 52, 255)        # 暗紫（父王是灰紫 86,74,92——刻意压暗压红）
    dark = gs.shade(main, 0.55)     # 近黑鳞
    ember = (196, 58, 34, 255)      # 灼红腹纹
    glow = (240, 120, 40, 255)      # 纹路高光
    # 盘卧的躯体：三段弧（构图与父王同构——同一种族的血脉镜像）
    cv.rect(20, 70, 130, 105, main)
    cv.rect(20, 92, 130, 105, dark)
    cv.rect(50, 46, 118, 78, main)
    # 灼红腹纹：躯体下缘三道斜纹
    for x in range(30, 120, 18):
        cv.rect(x, 96, x + 10, 104, ember)
        cv.px(x + 10, 95, glow)
    # 颈与头（朝左，吻部更尖长——比父王凶）
    cv.rect(26, 34, 46, 72, main)
    cv.rect(4, 26, 40, 46, main)
    cv.rect(4, 40, 40, 46, dark)
    cv.rect(0, 32, 12, 38, dark)                       # 吻部
    cv.px(12, 33, (255, 60, 30, 255))                  # 灼红瞳（父王是金瞳——一眼区分）
    # 角：三根，比父王多一根且更弯
    cv.rect(30, 16, 33, 28, dark)
    cv.rect(38, 14, 41, 28, dark)
    cv.rect(46, 18, 49, 28, dark)
    # 背鳍：黑鳞刺
    for i, x in enumerate(range(56, 120, 14)):
        h = 12 + (i % 3) * 5
        cv.rect(x, 46 - h, x + 6, 50, dark)
    # 尾
    cv.rect(120, 78, 150, 92, main)
    cv.rect(146, 70, 158, 84, dark)
    # 断裂的锁链：缠在颈上一节、垂在躯体前——人类给他戴过的东西
    chain = (150, 148, 158, 255)
    cv.rect(30, 66, 44, 70, chain)                     # 颈环
    cv.rect(34, 70, 38, 84, chain)                     # 断链垂下
    cv.px(36, 86, chain)                               # 链尾最后一环
    cv.outline()
    cv.save(os.path.join(OUT, "unit_demon_dragon.png"))
    print("OK unit_demon_dragon.png")


if __name__ == "__main__":
    draw_demon_dragon()
