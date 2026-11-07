#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_cg.py —— 程序化生成剧情 CG（640x360 像素剪影风，纯标准库）

对应 GDD/09 第五节 CG 清单（编号一致）。剪影 + 光效的极简构图：
正式 CG 委托回来后同名替换即可。

运行：python3 tools/gen_cg.py   （在项目根目录执行）
"""
import os
import random

from gen_sprites import Canvas, shade, light  # 复用画布与调色工具

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "art", "cg")

INK = (16, 13, 20, 255)        # 剪影墨色
GOLD = (232, 190, 90, 255)
CYAN = (150, 220, 235, 255)
FIRE = (226, 120, 50, 255)


def glow(cv, x, y, r, color, steps=5):
    """同心矩形模拟辉光。只画在"空白像素"上——绝不覆盖剪影。"""
    for i in range(steps, 0, -1):
        rr = int(r * i / steps)
        for yy in range(max(0, y - rr // 2), min(360, y + rr // 2 + 1)):
            for xx in range(max(0, x - rr), min(640, x + rr + 1)):
                if cv.buf[(xx, yy)][3] == 0:
                    cv.buf[(xx, yy)] = (color[0], color[1], color[2], 60)


def person(cv, x, y, h, color=INK, kneel=False, arm_up=False):
    """小人剪影：y=脚底，h=身高"""
    head = max(3, h // 6)
    bw = max(4, h // 5)
    top = y - h
    cv.rect(x, top, x + bw, top + head, color)                    # 头
    body_top = top + head + 1
    body_bottom = y if not kneel else y - h // 3
    cv.rect(x - 1, body_top, x + bw + 1, body_bottom, color)      # 躯干
    if kneel:
        cv.rect(x - h // 5, y - h // 4, x + bw + 2, y - h // 6, color)   # 跪腿
        cv.rect(x - 1, body_bottom, x + bw + 1, y - h // 3, color)
    else:
        cv.rect(x, body_bottom + 1, x + bw // 2, y, color)        # 腿
        cv.rect(x + bw // 2 + 1, body_bottom + 1, x + bw, y, color)
    if arm_up:
        cv.rect(x + bw + 1, body_top, x + bw + 4, body_top + h // 3, color)


def snowfall(cv, rnd, n=160, area=(0, 0, 639, 359), color=(230, 235, 248, 255)):
    for _ in range(n):
        x = rnd.randint(area[0], area[2])
        y = rnd.randint(area[1], area[3])
        cv.rect(x, y, x + 1, y + 1, color)


def night_sky(cv, rnd, base=(24, 26, 42, 255)):
    for y in range(360):
        k = y / 360.0
        c = (int(base[0] * (1 - k * 0.4)), int(base[1] * (1 - k * 0.4)),
             int(base[2] * (1 - k * 0.3)), 255)
        cv.rect(0, y, 639, y, c)
    for _ in range(40):                                          # 星
        x = rnd.randint(0, 637)
        y = rnd.randint(0, 158)
        cv.rect(x, y, x + 1, y + 1, (200, 205, 230, 255))


def speckle_bg(cv, rnd):
    for _ in range(260):
        x, y = rnd.randint(0, 639), rnd.randint(212, 352)
        cv.rect(x, y, x + rnd.randint(1, 3), y + 1, (172, 178, 200, 255))


# ------------------------------------------------------------

def cg01_white_raven():
    """CG-01 白鸦：晨祷堂彩窗 + 长椅剪影 + 白鸦"""
    cv = Canvas(640, 360)
    cv.rect(0, 0, 639, 359, (30, 28, 40, 255))
    wx, wy = 250, 40
    cols = [(190, 80, 70), (90, 120, 180), (210, 170, 80), (110, 160, 120)]
    for gy in range(8):
        for gx in range(6):
            c = cols[(gx + gy) % 4]
            cv.rect(wx + gx * 23 + 2, wy + gy * 25 + 2,
                    wx + gx * 23 + 21, wy + gy * 25 + 22, (c[0], c[1], c[2], 235))
    cv.rect(wx - 4, wy - 4, wx + 143, wy + 207, (70, 60, 50, 255))
    # 光柱
    for i in range(3):
        x0 = wx + 30 + i * 40
        for d in range(120):
            cv.rect(x0 + d // 3, wy + 200 + d, x0 + 18 + d // 3, wy + 200 + d,
                    (120, 110, 100, 28))
    # 长椅剪影两排
    for row in range(2):
        y = 290 + row * 34
        for x in range(20, 620, 90):
            cv.rect(x, y, x + 70, y + 12, INK)
            cv.rect(x + 6, y + 12, x + 64, y + 26, INK)
    person(cv, 470, 330, 46, INK)                                 # 打瞌睡的见习生
    # 白鸦（右上，翅膀张开）
    bx, by = 560, 60
    cv.rect(bx, by, bx + 8, by + 5, (245, 245, 245, 255))
    cv.rect(bx - 6, by - 4, bx + 2, by + 2, (245, 245, 245, 255))
    cv.rect(bx + 7, by - 5, bx + 13, by + 1, (245, 245, 245, 255))
    cv.save(os.path.join(OUT, "cg01_white_raven.png"))


def cg02_scale_in_hand():
    """CG-02 温热的鳞片：掌心族徽"""
    cv = Canvas(640, 360)
    cv.rect(0, 0, 639, 359, (24, 20, 26, 255))
    cv.rect(300, 200, 560, 340, (205, 172, 140, 255))
    cv.rect(300, 200, 340, 260, (205, 172, 140, 255))            # 拇指
    for i in range(4):                                           # 指缝阴影
        cv.rect(360 + i * 50, 200, 368 + i * 50, 232, (160, 128, 100, 255))
    cx, cy = 430, 270
    for row in range(4):                                         # 叠瓦族徽
        w = 60 - row * 12
        for i in range(3):
            x = cx - w // 2 + i * (w // 3 + 2)
            y = cy - 18 + row * 12
            cv.rect(x, y, x + w // 3 - 2, y + 9, (70, 130, 130, 255))
    glow(cv, cx, cy, 70, (90, 170, 170))
    cv.save(os.path.join(OUT, "cg02_scale_in_hand.png"))


def cg03_comfort():
    """CG-03 安抚：篝火旁牧师覆手"""
    cv = Canvas(640, 360)
    night_sky(cv, random.Random(103), (18, 20, 34, 255))
    rnd = random.Random(103)
    fx, fy = 320, 300
    glow(cv, fx, fy, 90, FIRE)
    cv.rect(fx - 14, fy - 12, fx + 14, fy, FIRE)
    cv.rect(fx - 8, fy - 20, fx + 8, fy - 6, (240, 170, 70, 255))
    person(cv, 240, 316, 62, INK)
    person(cv, 380, 316, 60, INK, kneel=True)
    cv.rect(372, 240, 402, 248, (205, 172, 140, 255))            # 覆上的手
    for i in range(4):                                           # 鳞纹微光
        cv.rect(386 + i * 6, 252, 389 + i * 6, 260, CYAN)
    snowfall(cv, rnd, 60, (0, 0, 639, 200))
    cv.save(os.path.join(OUT, "cg03_comfort.png"))


def cg04_beads():
    """CG-04 念珠：雪地散落的念珠（不直接画血）"""
    cv = Canvas(640, 360)
    night_sky(cv, random.Random(104), (26, 30, 48, 255))
    rnd = random.Random(104)
    cv.rect(0, 210, 639, 359, (190, 196, 216, 255))
    speckle_bg(cv, rnd)
    person(cv, 470, 300, 70, INK, kneel=True)
    cv.rect(400, 288, 446, 296, INK)                             # 伸出的手臂
    for i in range(13):                                          # 念珠弧线
        x = 150 + i * 22
        y = 268 + int(((i - 6) ** 2) * 1.6)
        cv.rect(x, y, x + 5, y + 5, (238, 234, 226, 255))
    snowfall(cv, rnd, 90)
    cv.save(os.path.join(OUT, "cg04_beads.png"))


def cg05_awakening():
    """CG-05 觉醒：跪姿抬头，鳞纹亮起，龙首低垂相抵"""
    cv = Canvas(640, 360)
    night_sky(cv, random.Random(105), (14, 14, 24, 255))
    rnd = random.Random(105)
    cv.rect(0, 260, 639, 359, (40, 40, 58, 255))
    # 光晕先铺（glow 只染空白像素），剪影后画
    glow(cv, 298, 250, 60, CYAN)
    glow(cv, 320, 232, 26, (240, 240, 220))                      # 额头相抵的光
    cv.rect(40, 90, 240, 200, (36, 32, 54, 255))                 # 龙首剪影（比夜空亮一档）
    cv.rect(180, 120, 330, 210, (36, 32, 54, 255))
    cv.rect(8, 110, 60, 170, (36, 32, 54, 255))
    cv.rect(30, 70, 52, 96, (36, 32, 54, 255))
    cv.rect(112, 136, 128, 144, GOLD)                            # 龙瞳（加大）
    person(cv, 300, 320, 80, INK, kneel=True)
    cv.rect(296, 226, 300, 260, INK)                             # 抬起的手臂
    for i in range(7):                                           # 鳞纹连成甲
        cv.rect(293, 228 + i * 5, 303, 231 + i * 5, CYAN)
    snowfall(cv, rnd, 120, (0, 0, 639, 240))
    cv.save(os.path.join(OUT, "cg05_awakening.png"))


def cg06_beheading():
    """CG-06 斩首：剑光斜落，剪影处理"""
    cv = Canvas(640, 360)
    cv.rect(0, 0, 639, 359, (12, 10, 16, 255))
    rnd = random.Random(106)
    for i in range(4):                                           # 斜落剑光带
        cv.rect(150 + i * 30, 0, 420 + i * 30, 360 - i * 10,
                (240, 242, 250, max(0, 255 - i * 60)))
    cv.rect(260, 220, 420, 320, (34, 30, 50, 255))               # 坠落的龙首
    cv.rect(240, 190, 300, 240, (34, 30, 50, 255))
    cv.rect(280, 150, 310, 190, (34, 30, 50, 255))
    snowfall(cv, rnd, 100)
    cv.save(os.path.join(OUT, "cg06_beheading.png"))


def cg07_ice_mirror():
    """CG-07 挡刀：法师张臂，冰镜碎成三千片"""
    cv = Canvas(640, 360)
    night_sky(cv, random.Random(107), (20, 22, 38, 255))
    rnd = random.Random(107)
    cv.rect(452, 0, 470, 180, (235, 238, 248, 255))              # 剑光
    cx, cy = 420, 200
    for i in range(26):                                          # 放射碎片
        x = cx + rnd.randint(-150, 60)
        y = cy + rnd.randint(-120, 80)
        w = rnd.randint(6, 22)
        cv.rect(x, y, x + w, y + rnd.randint(3, 8), (225, 235, 248, 255))
    glow(cv, cx, cy, 90, (200, 225, 245))
    person(cv, 280, 320, 92, INK, arm_up=True)
    cv.rect(250, 220, 262, 250, INK)
    person(cv, 360, 330, 66, (28, 26, 36, 255))                  # 身后的主角
    snowfall(cv, rnd, 70)
    cv.save(os.path.join(OUT, "cg07_ice_mirror.png"))


def cg08_ashes():
    """CG-08 灰烬中的祈祷：龙尸旁呼气成霜"""
    cv = Canvas(640, 360)
    cv.rect(0, 0, 639, 359, (20, 16, 18, 255))
    rnd = random.Random(108)
    cv.rect(0, 250, 639, 359, (36, 30, 32, 255))
    cv.rect(60, 190, 560, 300, (30, 24, 26, 255))                # 龙尸
    cv.rect(60, 260, 560, 300, (24, 20, 22, 255))
    cv.rect(120, 160, 240, 210, (30, 24, 26, 255))
    person(cv, 400, 336, 74, INK, kneel=True)
    for i in range(9):                                           # 呼气成霜
        cv.rect(430 + i * 5, 268 - i * 3, 434 + i * 5, 272 - i * 3,
                (220, 228, 240, max(0, 255 - i * 18)))
    for _ in range(16):                                          # 余烬
        x, y = rnd.randint(80, 560), rnd.randint(200, 340)
        cv.rect(x, y, x + 2, y + 2, FIRE)
    cv.save(os.path.join(OUT, "cg08_ashes.png"))


def cg09_copper_coins():
    """CG-09 两个铜子儿：雪地里两枚铜钱"""
    cv = Canvas(640, 360)
    night_sky(cv, random.Random(109), (28, 30, 46, 255))
    rnd = random.Random(109)
    cv.rect(0, 220, 639, 359, (196, 202, 222, 255))
    speckle_bg(cv, rnd)
    for cx, cy in ((290, 290), (330, 306)):
        cv.rect(cx, cy, cx + 22, cy + 10, (196, 150, 70, 255))
        cv.rect(cx + 3, cy + 2, cx + 19, cy + 8, (222, 178, 92, 255))
        cv.rect(cx + 9, cy + 3, cx + 13, cy + 7, (150, 110, 50, 255))
    glow(cv, 310, 298, 50, (230, 190, 110))
    snowfall(cv, rnd, 70)
    cv.save(os.path.join(OUT, "cg09_copper_coins.png"))


def cg10_blood_wash():
    """CG-10 血洗终章：燃烧城门下的加冕行军"""
    cv = Canvas(640, 360)
    cv.rect(0, 0, 639, 359, (14, 10, 14, 255))
    rnd = random.Random(110)
    cv.rect(240, 60, 400, 300, (30, 22, 24, 255))                # 城门拱
    glow(cv, 320, 220, 130, FIRE)
    cv.rect(280, 180, 360, 300, (150, 60, 30, 255))              # 门内火光
    cv.rect(296, 220, 344, 300, (230, 130, 50, 255))
    for i in range(7):                                           # 跪伏人群
        person(cv, 90 + (i % 2) * 470 + i * 6, 330 - (i % 3) * 10,
               34 + (i % 3) * 8, INK, kneel=True)
    person(cv, 310, 250, 96, INK)                                # 行进中的高身影
    snowfall(cv, rnd, 60, (0, 0, 639, 359), (90, 70, 60, 255))   # 灰烬
    cv.save(os.path.join(OUT, "cg10_blood_wash.png"))


def cg11_birch():
    """CG-11 不染雪：真结局——白桦树苗与念珠（全游戏最亮的一张）"""
    cv = Canvas(640, 360)
    for y in range(360):
        k = y / 360.0
        c = (int(120 + 60 * (1 - k)), int(130 + 55 * (1 - k)),
             int(160 + 40 * (1 - k)), 255)
        cv.rect(0, y, 639, y, c)
    rnd = random.Random(111)
    cv.rect(0, 260, 639, 359, (226, 230, 240, 255))
    cv.rect(316, 120, 324, 290, (235, 232, 226, 255))            # 白桦干
    for y in range(130, 280, 26):                                # 皮纹
        cv.rect(316, y, 318, y + 8, (60, 60, 66, 255))
    cv.rect(296, 96, 344, 124, (140, 170, 120, 255))             # 树冠
    cv.rect(306, 82, 336, 100, (120, 155, 110, 255))
    for i in range(6):                                           # 根下念珠
        cv.rect(300 + i * 8, 292, 304 + i * 8, 296, (238, 234, 226, 255))
    snowfall(cv, rnd, 24, (0, 0, 639, 260))                      # 雪停了
    cv.save(os.path.join(OUT, "cg11_birch.png"))


def cg12_new_heroes():
    """CG-12 新的讨伐队：数百年后，山口五人小队 + 巨瞳睁开"""
    cv = Canvas(640, 360)
    cv.rect(0, 0, 639, 359, (10, 9, 14, 255))
    rnd = random.Random(112)
    cv.rect(0, 300, 639, 359, (24, 22, 30, 255))
    for i in range(200):                                         # 山体夹峙
        cv.rect(0, 60 + i, max(0, 200 - i // 2), 60 + i, (16, 14, 20, 255))
        cv.rect(min(639, 440 + i // 2), 60 + i, 639, 60 + i, (16, 14, 20, 255))
    cv.rect(250, 130, 390, 190, (18, 14, 16, 255))               # 山腹巨瞳
    cv.rect(280, 150, 360, 172, (60, 44, 20, 255))
    cv.rect(300, 156, 342, 166, GOLD)
    cv.rect(318, 152, 322, 170, (40, 30, 16, 255))               # 竖瞳
    person(cv, 120, 330, 60, INK)                                # 旗手领头
    for i in range(4):
        person(cv, 170 + i * 26, 326 - i * 2, 52 - i, INK)
    cv.rect(122, 250, 124, 300, INK)                             # 旗杆
    cv.rect(126, 250, 150, 272, (60, 50, 70, 255))
    snowfall(cv, rnd, 80)
    cv.save(os.path.join(OUT, "cg12_new_heroes.png"))


def cg13_raven_loop():
    """CG-13 白鸦·轮回：晨祷堂复用构图，鳞纹多了一道，鸦远去"""
    cv = Canvas(640, 360)
    cv.rect(0, 0, 639, 359, (30, 28, 40, 255))
    rnd = random.Random(113)
    wx, wy = 250, 40
    cols = [(190, 80, 70), (90, 120, 180), (210, 170, 80), (110, 160, 120)]
    for gy in range(8):
        for gx in range(6):
            c = cols[(gx + gy) % 4]
            cv.rect(wx + gx * 23 + 2, wy + gy * 25 + 2,
                    wx + gx * 23 + 21, wy + gy * 25 + 22, (c[0], c[1], c[2], 200))
    cv.rect(wx - 4, wy - 4, wx + 143, wy + 207, (70, 60, 50, 255))
    for row in range(2):
        y = 290 + row * 34
        for x in range(20, 620, 90):
            cv.rect(x, y, x + 70, y + 12, INK)
            cv.rect(x + 6, y + 12, x + 64, y + 26, INK)
    person(cv, 470, 330, 46, INK)
    for i in range(4):                                           # 前臂鳞纹清晰
        cv.rect(486, 296 + i * 4, 496, 298 + i * 4, (90, 150, 150, 255))
    bx, by = 430, 70                                             # 飞远的鸦（残影）
    for k, dx in enumerate((0, -14, -28)):
        c = (245, 245, 245, max(0, 255 - k * 80))
        cv.rect(bx + dx, by + k * 3, bx + dx + 5, by + k * 3 + 3, c)
    cv.save(os.path.join(OUT, "cg13_raven_loop.png"))


def main():
    os.makedirs(OUT, exist_ok=True)
    cg01_white_raven()
    cg02_scale_in_hand()
    cg03_comfort()
    cg04_beads()
    cg05_awakening()
    cg06_beheading()
    cg07_ice_mirror()
    cg08_ashes()
    cg09_copper_coins()
    cg10_blood_wash()
    cg11_birch()
    cg12_new_heroes()
    cg13_raven_loop()
    print("CG 生成完毕（13 张）。")


if __name__ == "__main__":
    main()
