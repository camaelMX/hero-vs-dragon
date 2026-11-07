#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_bg_comfy.py —— ComfyUI 生成战斗/场景插画背景（复用 gen_cg_comfy 管线）

用户需求（2026-11-07）：像素背景太丑，战斗背景升级插画。
产出：
  原图 1344x768  -> assets/art/bg_ai/（母版留档）
  降采样 1280x720 -> assets/art/bg/bg_*.png（游戏引用路径，直接生效）
旧像素背景先备份到 assets/art/bg_pixel_backup/（gen_sprites.py 可随时再生成，双保险）。

安全约束与 gen_cg_comfy.py 相同：模型白名单 + 视频模型禁运 + 大文件只在 AI 盘。

用法（项目根目录）：python3 tools/gen_bg_comfy.py [all|village|forest|snow|lair]
"""
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_cg_comfy import (ALLOWED_CKPTS, NEGATIVE, STYLE, STYLE_SDXL,
                          build_graph, guard, submit_and_fetch)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_AI = os.path.join(ROOT, "assets", "art", "bg_ai")
OUT_GAME = os.path.join(ROOT, "assets", "art", "bg")
BACKUP = os.path.join(ROOT, "assets", "art", "bg_pixel_backup")

# 空场景铁律：无人无怪（单位是游戏贴图，背景抢戏就完了）；
# 前景必须是平整空地（角色要在上面站位）
BGS = [
    {"id": "bg_village", "seed": 301,
     "prompt": "remote mountain village at dusk in heavy snow, small timber houses "
               "with warm candlelit windows, a modest stone chapel with a soft glowing "
               "window, smoke from chimneys, snow-covered path leading out of the village, "
               "dark pine forest and cliffs behind, empty scene, no people, wide landscape, "
               "flat open snowy ground in foreground"},
    {"id": "bg_forest", "seed": 302,
     "prompt": "snow-covered pine forest trail in overcast daylight, tall dark spruce "
               "trees on both sides, an open snowy clearing path in the middle ground, "
               "faint blue winter light, footprints of unknown creatures, empty scene, "
               "no people, no creatures, wide landscape, flat open snowfield in foreground"},
    {"id": "bg_snow", "seed": 303,
     "prompt": "bleak high mountain snowline trail, wind-blown snow, jagged black peaks "
               "in the distance under a heavy grey sky, a lone weathered shrine marker, "
               "desolate and ominous, empty scene, no people, wide landscape, "
               "flat open snowfield in foreground"},
    # 龙巢：Illustrious 画建筑+光影型空场景稳定（祈祷堂 CG 先例），
    # 严禁 bones/shadow/creature 类词汇（会召唤生物，实测三连翻车）
    {"id": "bg_lair", "seed": 334,
     "prompt": "colossal dark underground cavern hall, towering black stone pillars "
               "vanishing into darkness, long reflective obsidian floor, abandoned "
               "swords and tattered banners along the walls, distant warm ember light "
               "deep in the darkness, thin mist, vast oppressive scale, "
               "environmental concept art, empty of characters, wide landscape"},
]


def gen_bg(bg, variant=0):
    ckpt = bg.get("ckpt", "sdxl")
    guard(ALLOWED_CKPTS[ckpt])
    seed = bg["seed"] + variant * 11
    if ckpt == "sdxl":
        style, w, h, steps, cfg = STYLE_SDXL, 1344, 768, 28, 5.5
    else:
        # SD1.5 风景模型（山川梦绘集）：640x384 出图后 lanczos 放大——
        # 暗色调大场景对放大软化不敏感；角色模型压不住"空场景"时用它
        style, w, h, steps, cfg = STYLE, 960, 544, 26, 7.0
    pos = (style + "environment concept art, no characters, "
           + bg["prompt"])
    # 背景专属负向：任何生物都不要（单位是游戏贴图，背景抢戏=废）
    neg = (NEGATIVE + ", dragon, creatures, monsters, animals, people, "
           "silhouette figure, skeleton, skull, beast")
    graph = build_graph(ckpt, pos, neg, w, h, seed, steps=steps, cfg=cfg, lora=None)
    dest = os.path.join(OUT_AI, "%s.png" % bg["id"])
    print("提交 %-11s seed=%d 1344x768" % (bg["id"], seed), flush=True)
    submit_and_fetch(graph, dest)
    # 黑图检测：动态 VRAM 流式加载偶发 NaN → 纯黑图，必须当场拦下重试
    from PIL import Image
    im = Image.open(dest).convert("RGB")
    px = list(im.resize((8, 8)).getdata())
    bright = sum(sum(c) for c in px) / (len(px) * 3)
    if bright < 5.0:
        os.remove(dest)
        raise SystemExit("黑图（亮度 %.1f）已删除——ComfyUI 出了 NaN，先 "
                         "curl -X POST http://127.0.0.1:8188/free -d "
                         "'{\"unload_models\":true,\"free_memory\":true}' 再重试" % bright)
    final = os.path.join(OUT_GAME, "%s.png" % bg["id"])
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", dest,
                    "-vf", "scale=1280:720", final], check=True)
    print("      -> ", os.path.relpath(final, ROOT), "(亮度 %.0f)" % bright, flush=True)


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else "all"
    # 旧像素背景备份（只备份一次，不覆盖已有备份）
    os.makedirs(BACKUP, exist_ok=True)
    for bg in BGS:
        src = os.path.join(OUT_GAME, "%s.png" % bg["id"])
        dst = os.path.join(BACKUP, "%s.png" % bg["id"])
        if os.path.exists(src) and not os.path.exists(dst):
            shutil.copy2(src, dst)
            print("备份像素版 ->", os.path.relpath(dst, ROOT))
    todo = BGS if arg == "all" else [b for b in BGS if b["id"] == arg]
    if not todo:
        raise SystemExit("没找到 %s，可选: all/%s" % (arg, "|".join(b["id"] for b in BGS)))
    for b in todo:
        gen_bg(b)


if __name__ == "__main__":
    main()
