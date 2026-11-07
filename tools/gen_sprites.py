#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_sprites.py —— 程序化生成灰盒像素美术（纯标准库，零依赖）

内容：角色/怪物战斗小人、战斗背景、道路 tile、卡框 UI。
风格：统一"双色调+黑描边"的极简像素画——明确是 placeholder，
      但构图与 GDD/09 对应，正式美术可直接按同文件名替换。

运行：python3 tools/gen_sprites.py   （在项目根目录执行）
"""
import os
import random
import struct
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "art")

# ------------------------------------------------------------
# PNG 编码（RGBA，8bit，无滤波）
# ------------------------------------------------------------

def save_png(path, w, h, get_px):
    """get_px(x, y) -> (r, g, b, a)"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter type 0
        for x in range(w):
            raw.extend(get_px(x, y))

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)  # RGBA8
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)
    print("ART ->", os.path.relpath(path, ROOT))


class Canvas:
    def __init__(self, w, h, bg=(0, 0, 0, 0)):
        self.w, self.h = w, h
        self.buf = {}
        for y in range(h):
            for x in range(w):
                self.buf[(x, y)] = bg

    def px(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.buf[(x, y)] = c

    def rect(self, x0, y0, x1, y1, c):
        """闭区间矩形"""
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                self.px(x, y, c)

    def outline(self, c=(20, 18, 24, 255)):
        """外描边：给每个不透明像素的透明邻居描一圈（先收集后写回）"""
        edge = []
        for (x, y), v in self.buf.items():
            if v[3] == 0:
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if not (0 <= nx < self.w and 0 <= ny < self.h):
                    continue
                if self.buf[(nx, ny)][3] == 0:
                    edge.append((nx, ny))
        for p in edge:
            self.buf[p] = c

    def save(self, path):
        save_png(path, self.w, self.h,
                 lambda x, y: self.buf[(x, y)])


def shade(c, k=0.72):
    return (int(c[0] * k), int(c[1] * k), int(c[2] * k), c[3] if len(c) > 3 else 255)


def light(c, k=1.25):
    return (min(255, int(c[0] * k)), min(255, int(c[1] * k)), min(255, int(c[2] * k)),
            c[3] if len(c) > 3 else 255)


# ------------------------------------------------------------
# 角色模板（48x64，脚底在画布底边，同 GDD/09 的角色规格）
# ------------------------------------------------------------

def draw_humanoid(cv, pal, weapon=None, hood=False, armor=False, bulky=False,
                  robe=False, banner=False, pack=False):
    """
    pal 字典键：skin / main(衣) / main2(副色) / metal / hair
    weapon: "sword" / "staff" / None
    robe  : 长袍（审判官/商贩）——腿部换成袍摆
    banner: 军旗（军官）
    pack  : 背货箱（商人）
    """
    dx = -4 if bulky else 0    # 壮汉整体加宽
    leg_w = 3 + (1 if bulky else 0)

    # 腿 + 靴（长袍时只露脚尖）
    if robe:
        cv.rect(13 + dx, 44, 34 - dx, 60, pal["main"])             # 袍摆
        cv.rect(13 + dx, 57, 34 - dx, 60, shade(pal["main"], 0.7))
        cv.rect(16, 61, 21, 63, shade(pal["main2"], 0.5))          # 鞋尖
        cv.rect(26, 61, 31, 63, shade(pal["main2"], 0.5))
    else:
        for lx in (18 + dx, 26 - dx):
            cv.rect(lx, 48, lx + leg_w - 1, 59, pal["main2"])
            cv.rect(lx, 56, lx + leg_w - 1, 63, shade(pal["main2"], 0.55))
    # 躯干
    cv.rect(14 + dx, 30, 33 - dx, 47, pal["main"])
    cv.rect(14 + dx, 42, 33 - dx, 44, shade(pal["main"]))          # 衣摆阴影
    cv.rect(14 + dx, 40, 33 - dx, 41, pal["main2"])                # 腰带
    if armor:
        cv.rect(15 + dx, 32, 32 - dx, 35, pal["metal"])            # 胸甲
        cv.rect(14 + dx, 33, 16 + dx, 45, pal["metal"])            # 肩甲
        cv.rect(31 - dx, 33, 33 - dx, 45, pal["metal"])
    if pack:
        cv.rect(6, 30, 13, 46, shade(pal["main2"], 0.6))           # 背上货箱
        cv.rect(6, 36, 13, 38, pal["metal"])
    # 手臂
    cv.rect(10 + dx, 32, 13 + dx, 45, pal["main2"])
    cv.rect(34 - dx, 32, 37 - dx, 45, pal["main2"])
    # 头
    cv.rect(17, 14, 30, 29, pal["skin"])
    cv.rect(17, 14, 30, 19, pal["hair"])                           # 发/盔
    if hood:
        cv.rect(16, 12, 31, 22, pal["main"])                       # 兜帽罩住上半脸
        cv.rect(19, 23, 22, 26, (30, 30, 34, 255))                 # 阴影下的眼睛区
    else:
        cv.px(21, 23, (25, 22, 28, 255))                           # 眼
        cv.px(27, 23, (25, 22, 28, 255))
    # 高帽（审判官）
    if banner == "hat":
        cv.rect(19, 4, 28, 14, pal["main2"])
        cv.rect(17, 12, 30, 14, pal["main2"])
    # 武器
    if weapon == "sword":
        cv.rect(38, 16, 40, 46, pal["metal"])
        cv.rect(36, 46, 42, 47, pal["main2"])                      # 护手
        cv.px(39, 48, shade(pal["main2"], 0.5))
    elif weapon == "staff":
        cv.rect(39, 12, 40, 50, shade(pal["main2"], 0.6))
        cv.rect(37, 8, 42, 13, pal["metal"])                       # 法杖顶端
    # 军旗（军官）：旗杆 + 红旗
    if banner is True:
        cv.rect(42, 6, 43, 56, shade(pal["main2"], 0.5))
        cv.rect(44, 6, 47, 18, (150, 45, 45, 255))
        cv.rect(44, 6, 47, 8, (190, 60, 55, 255))


def draw_sprite_char(unit_id):
    pal = PALETTES[unit_id]
    cv = Canvas(48, 64)
    cfg = CHAR_CFG.get(unit_id, {})
    draw_humanoid(cv, pal, weapon=cfg.get("weapon"), hood=cfg.get("hood", False),
                  armor=cfg.get("armor", False), bulky=cfg.get("bulky", False),
                  robe=cfg.get("robe", False), banner=cfg.get("banner", False),
                  pack=cfg.get("pack", False))
    cv.outline()
    cv.save(os.path.join(OUT, "sprites", "unit_%s.png" % unit_id))


CHAR_CFG = {
    "hero":   {"weapon": "sword"},
    "priest": {"weapon": "staff"},
    "mage":   {"hood": True},
    "protag": {"weapon": "sword", "armor": True},
    "goblin": {},
    "orc":    {"weapon": "sword", "bulky": True},
    "guard":  {"armor": True, "hood": True},
    "soldier": {"weapon": "sword", "armor": True},
    "knight": {"weapon": "sword", "armor": True},
    "troll":  {"bulky": True},
    # ---- 第二幕人类 + NPC ----
    "officer":    {"banner": True, "armor": True},                 # 军官（督战旗手）
    "inquisitor": {"robe": True, "hood": True, "banner": "hat"},   # 审判官（高帽长袍）
    "merchant":   {"robe": True, "pack": True},                    # 商人（围巾货郎）
    "priest2":    {"weapon": "staff"},                             # 新安抚师（幻觉结局）
}

PALETTES = {
    "hero":   {"skin": (245, 220, 180, 255), "main": (225, 185, 55, 255), "main2": (165, 128, 32, 255), "metal": (250, 242, 214, 255), "hair": (118, 80, 30, 255)},
    "priest": {"skin": (240, 215, 185, 255), "main": (233, 233, 243, 255), "main2": (178, 183, 205, 255), "metal": (255, 255, 255, 255), "hair": (95, 75, 62, 255)},
    "mage":   {"skin": (230, 205, 175, 255), "main": (118, 78, 190, 255), "main2": (78, 48, 140, 255), "metal": (205, 185, 255, 255), "hair": (55, 48, 70, 255)},
    "protag": {"skin": (245, 220, 180, 255), "main": (70, 110, 200, 255), "main2": (40, 70, 140, 255), "metal": (185, 212, 250, 255), "hair": (50, 45, 55, 255)},
    "goblin": {"skin": (95, 160, 70, 255), "main": (150, 92, 50, 255), "main2": (100, 60, 35, 255), "metal": (165, 165, 170, 255), "hair": (60, 110, 45, 255)},
    "orc":    {"skin": (145, 112, 82, 255), "main": (125, 62, 50, 255), "main2": (82, 42, 36, 255), "metal": (172, 172, 178, 255), "hair": (40, 30, 26, 255)},
    "guard":  {"skin": (102, 92, 112, 255), "main": (60, 50, 82, 255), "main2": (36, 30, 52, 255), "metal": (205, 195, 225, 255), "hair": (30, 26, 40, 255)},
    "soldier": {"skin": (235, 210, 180, 255), "main": (110, 120, 140, 255), "main2": (76, 85, 105, 255), "metal": (192, 197, 207, 255), "hair": (60, 50, 45, 255)},
    "knight": {"skin": (235, 210, 180, 255), "main": (198, 198, 214, 255), "main2": (140, 145, 165, 255), "metal": (232, 232, 240, 255), "hair": (120, 90, 50, 255)},
    "troll":  {"skin": (152, 140, 120, 255), "main": (112, 82, 62, 255), "main2": (76, 56, 44, 255), "metal": (150, 140, 130, 255), "hair": (60, 50, 42, 255)},
    "officer": {"skin": (238, 212, 182, 255), "main": (90, 100, 125, 255), "main2": (58, 66, 88, 255), "metal": (210, 215, 225, 255), "hair": (45, 38, 34, 255)},
    "inquisitor": {"skin": (238, 214, 186, 255), "main": (40, 36, 48, 255), "main2": (24, 22, 30, 255), "metal": (225, 200, 120, 255), "hair": (18, 16, 22, 255)},
    "merchant": {"skin": (242, 216, 184, 255), "main": (150, 96, 52, 255), "main2": (96, 60, 34, 255), "metal": (220, 200, 150, 255), "hair": (70, 52, 40, 255)},
    "priest2": {"skin": (240, 215, 185, 255), "main": (214, 220, 238, 255), "main2": (160, 168, 195, 255), "metal": (255, 255, 255, 255), "hair": (80, 62, 52, 255)},
}


# ------------------------------------------------------------
# 非人形怪：史莱姆 / 雪狼 / 恶龙 Boss
# ------------------------------------------------------------

def draw_slime():
    cv = Canvas(40, 32)
    main = (110, 200, 120, 255)
    dark = shade(main)
    widths = [10, 18, 26, 32, 36, 38, 40, 40, 40, 40]
    for row, wdt in enumerate(widths):
        x0 = (40 - wdt) // 2
        cv.rect(x0, 12 + row, x0 + wdt - 1, 12 + row, main)
    cv.rect(4, 22, 35, 31, main)
    cv.rect(4, 28, 35, 31, dark)                       # 底部暗色
    cv.rect(14, 17, 24, 22, light(main, 1.2))          # 高光核心
    cv.px(15, 24, (20, 40, 25, 255))                   # 眼
    cv.px(23, 24, (20, 40, 25, 255))
    cv.outline()
    cv.save(os.path.join(OUT, "sprites", "unit_slime.png"))


def draw_wolf():
    cv = Canvas(64, 40)
    main = (122, 122, 138, 255)
    dark = shade(main)
    cv.rect(8, 14, 44, 26, main)                       # 躯干
    cv.rect(8, 22, 44, 26, dark)
    cv.rect(44, 8, 58, 20, main)                       # 头
    cv.rect(44, 6, 47, 9, dark)                        # 耳
    cv.px(54, 12, (230, 190, 70, 255))                 # 金瞳
    cv.rect(0, 16, 7, 20, dark)                        # 尾
    for lx in (10, 18, 32, 40):                        # 四腿
        cv.rect(lx, 27, lx + 3, 39, dark)
    cv.outline()
    cv.save(os.path.join(OUT, "sprites", "unit_wolf.png"))


def draw_dragon():
    """父王占位剪影：160x120，灰盒 Boss 用"""
    cv = Canvas(160, 120)
    main = (86, 74, 92, 255)
    dark = shade(main, 0.6)
    # 盘卧的躯体：同心圆感的三段弧
    cv.rect(20, 70, 130, 105, main)
    cv.rect(20, 92, 130, 105, dark)
    cv.rect(50, 46, 118, 78, main)                     # 后段身体
    # 颈与头（朝左）
    cv.rect(26, 34, 46, 72, main)
    cv.rect(6, 26, 40, 46, main)
    cv.rect(6, 40, 40, 46, dark)
    cv.rect(2, 30, 12, 38, dark)                       # 吻部
    cv.px(14, 33, (240, 190, 60, 255))                 # 金瞳
    # 角
    cv.rect(30, 18, 33, 28, dark)
    cv.rect(38, 16, 41, 28, dark)
    # 背鳍
    for i, x in enumerate(range(56, 120, 14)):
        h = 10 + (i % 3) * 4
        cv.rect(x, 46 - h, x + 6, 50, dark)
    # 尾
    cv.rect(120, 78, 150, 92, main)
    cv.rect(146, 72, 158, 84, dark)
    cv.outline()
    cv.save(os.path.join(OUT, "sprites", "unit_dragon.png"))


# ------------------------------------------------------------
# 场景背景 640x360（Godot 里放大 2 倍 = 1280x720）
# ------------------------------------------------------------

def speckle(cv, rnd, area, color, count, w=2, h=1):
    x0, y0, x1, y1 = area
    for _ in range(count):
        x = rnd.randint(x0, x1)
        y = rnd.randint(y0, y1)
        cv.rect(x, y, x + rnd.randint(0, w), y + rnd.randint(0, h), color)


def bg_base(sky_a, sky_b, ground, seed):
    cv = Canvas(640, 360)
    rnd = random.Random(seed)
    for y in range(200):                      # 天空三段带
        c = sky_a if y < 90 else (sky_b if y < 150 else shade(sky_b, 1.1))
        cv.rect(0, y, 639, y, c)
    cv.rect(0, 200, 639, 359, ground)         # 地面
    speckle(cv, rnd, (0, 210, 639, 350), shade(ground, 0.85), 900)
    speckle(cv, rnd, (0, 210, 639, 350), light(ground, 1.15), 500)
    return cv, rnd


def bg_forest():
    cv, rnd = bg_base((28, 32, 48, 255), (44, 52, 64, 255), (36, 46, 38, 255), 1)
    for _ in range(14):                       # 远树剪影（根扎在地平线下）
        x = rnd.randint(0, 600)
        h = rnd.randint(40, 90)
        w = rnd.randint(18, 34)
        base_y = rnd.randint(208, 236)
        for i in range(h):
            row_w = int(w * i / h)
            cv.rect(x - row_w // 2 + w // 2, base_y - i, x + row_w // 2 + w // 2,
                    base_y - i, (18, 26, 22, 255))
    cv.save(os.path.join(OUT, "bg", "bg_forest.png"))


def bg_snow():
    cv, rnd = bg_base((30, 34, 50, 255), (52, 58, 82, 255), (196, 202, 220, 255), 2)
    for _ in range(8):                        # 远山
        x = rnd.randint(0, 560)
        w = rnd.randint(80, 180)
        h = rnd.randint(60, 120)
        for i in range(h):
            row_w = int(w * i / h)
            cv.rect(x + (w - row_w) // 2, 200 - i, x + (w + row_w) // 2, 200 - i,
                    (62, 68, 92, 255))
    speckle(cv, rnd, (0, 205, 639, 355), (255, 255, 255, 255), 400, w=3, h=1)
    cv.save(os.path.join(OUT, "bg", "bg_snow.png"))


def bg_lair():
    """龙巢：黑石 + 暖色余烬光斑"""
    cv, rnd = bg_base((16, 12, 16, 255), (26, 18, 20, 255), (34, 26, 28, 255), 3)
    for _ in range(9):                        # 余烬光斑（同心矩形模拟辉光）
        x = rnd.randint(20, 600)
        y = rnd.randint(220, 340)
        for r in (14, 9, 5, 2):
            c = (120, 34, 26, 255) if r > 5 else (220, 110, 40, 255)
            cv.rect(x - r, y - r // 2, x + r, y + r // 2, c)
    for _ in range(5):                        # 石笋剪影
        x = rnd.randint(0, 600)
        h = rnd.randint(50, 130)
        for i in range(h):
            cv.rect(x + i // 6, 200 - i, x + 12 - i // 6, 200 - i, (14, 10, 12, 255))
    cv.save(os.path.join(OUT, "bg", "bg_lair.png"))


def bg_ruin():
    """北境废墟（第二幕基调）：灰烬地 + 断墙"""
    cv, rnd = bg_base((38, 36, 44, 255), (58, 54, 62, 255), (52, 48, 52, 255), 4)
    for _ in range(6):                        # 断墙
        x = rnd.randint(0, 560)
        h = rnd.randint(40, 110)
        w = rnd.randint(30, 90)
        cv.rect(x, 200 - h, x + w, 200, (72, 68, 76, 255))
        cv.rect(x, 200 - h, x + w, 200 - h + 6, (90, 86, 96, 255))
    speckle(cv, rnd, (0, 205, 639, 350), (30, 28, 32, 255), 600)
    cv.save(os.path.join(OUT, "bg", "bg_ruin.png"))


# ------------------------------------------------------------
# Tile 与 UI
# ------------------------------------------------------------

def tile_road(name, base, dark):
    cv = Canvas(24, 24)
    rnd = random.Random(hash(name) % 999)
    cv.rect(0, 0, 23, 23, base)
    for _ in range(9):                        # 鹅卵石
        x = rnd.randint(0, 15)
        y = rnd.randint(0, 15)
        cv.rect(x, y, x + rnd.randint(5, 8), y + rnd.randint(3, 5), dark)
    speckle(cv, rnd, (0, 0, 20, 20), light(base, 1.2), 14)
    cv.save(os.path.join(OUT, "ui", name))


TIER_COLORS = {
    1: (110, 90, 60, 255),    # 祈祷：木纹
    2: (130, 132, 148, 255),  # 猎杀：铁纹
    3: (150, 45, 45, 255),    # 血誓：暗红
}


def card_frame(tier):
    cv = Canvas(120, 160)
    border = TIER_COLORS[tier]
    cv.rect(0, 0, 119, 159, border)
    cv.rect(4, 4, 115, 155, (22, 22, 28, 255))
    cv.rect(4, 4, 115, 26, light(border, 1.15))      # 标题条
    cv.rect(4, 4, 115, 26, border)
    cv.rect(8, 30, 111, 128, (30, 30, 38, 255))      # 画框区
    cv.rect(8, 132, 111, 152, (18, 18, 24, 255))     # 信息区
    # 底部星级槽位
    for i in range(5):
        x = 14 + i * 20
        cv.rect(x, 156, x + 10, 157, (60, 60, 70, 255))
    cv.save(os.path.join(OUT, "ui", "card_tier%d.png" % tier))


def star():
    cv = Canvas(12, 12)
    g = (240, 200, 60, 255)
    for i in range(5):                        # 简易菱形星
        cv.rect(5 - i if i < 3 else i - 3, 2 + i, 6 + i if i < 3 else 11 - (i - 3), 2 + i, g)
    cv.rect(5, 0, 6, 11, g)
    cv.rect(0, 5, 11, 6, g)
    cv.outline((90, 70, 20, 255))
    cv.save(os.path.join(OUT, "ui", "star.png"))


def bg_village():
    """村庄/据点（run_scene 背景）：暖窗小屋 + 教会尖顶 + 雪地"""
    cv, rnd = bg_base((40, 44, 66, 255), (64, 60, 84, 255), (188, 194, 214, 255), 5)
    # 教会（中景左侧）：尖顶 + 圣徽
    cv.rect(90, 120, 150, 200, (70, 66, 86, 255))
    for i in range(30):
        cv.rect(118 - i // 3, 90 + i, 120 + i // 3, 90 + i, (70, 66, 86, 255))
    cv.rect(116, 78, 121, 90, (225, 200, 120, 255))
    cv.rect(104, 150, 116, 178, (225, 200, 120, 255))          # 亮窗
    # 小屋 ×4：随机位置 + 暖窗
    for _ in range(4):
        x = rnd.randint(220, 560)
        w = rnd.randint(60, 100)
        h = rnd.randint(50, 80)
        top = 200 - h
        cv.rect(x, top, x + w, 200, (58, 54, 72, 255))
        for i in range(w // 2):                                # 三角屋顶
            cv.rect(x + i, top - i // 2, x + w - i, top - i // 2, (44, 42, 60, 255))
        cv.rect(x + 10, top + 18, x + 22, top + 30, (232, 180, 90, 255))
        cv.rect(x + w - 24, top + 18, x + w - 12, top + 30, (232, 180, 90, 255))
    speckle(cv, rnd, (0, 205, 639, 350), (255, 255, 255, 255), 300, w=3)
    cv.save(os.path.join(OUT, "bg", "bg_village.png"))


def main():
    os.makedirs(os.path.join(OUT, "sprites"), exist_ok=True)
    os.makedirs(os.path.join(OUT, "bg"), exist_ok=True)
    os.makedirs(os.path.join(OUT, "ui"), exist_ok=True)

    for uid in CHAR_CFG:
        draw_sprite_char(uid)
    draw_slime()
    draw_wolf()
    draw_dragon()

    bg_forest()
    bg_snow()
    bg_lair()
    bg_ruin()
    bg_village()

    tile_road("tile_road.png", (70, 68, 78, 255), (54, 52, 62, 255))
    tile_road("tile_road_boss.png", (86, 46, 46, 255), (64, 32, 34, 255))
    for t in (1, 2, 3):
        card_frame(t)
    star()
    print("图像生成完毕。")


if __name__ == "__main__":
    main()
