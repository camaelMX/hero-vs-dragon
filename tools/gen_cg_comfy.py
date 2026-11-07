#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_cg_comfy.py —— 通过本地 ComfyUI API 生成过场 CG（仅文生图）

与 tools/gen_cg.py（程序化剪影占位版）并存：
  * 本脚本产出 -> assets/art/cg_ai/（AI 版，质量高，耗 GPU）
  * 占位版产出 -> assets/art/cg/   （秒出，离线保底）

路线（美术担当定稿）：
  * 默认 = SDXL《Illustrious2.5D》+ pixel-art-xl LoRA @1024x576
    （下载自 HuggingFace nerijs/pixel-art-xl，免费；出图后再整 数值化像素处理）
  * 备用 = SD1.5《山川梦绘集》/《猫爪》纯提示词像素风 @640x384

安全约束（用户明令两条）：
  1. 别跑视频模型（loras 里那些 wan2.2/minimax 一个都不碰，名字命中即拒绝）
  2. 大文件只装 AI 盘（模型目录在 /home/camael/AI/ComfyUI，不在系统盘）

用法（项目根目录执行）：
  python3 tools/gen_cg_comfy.py list        列出全部 CG
  python3 tools/gen_cg_comfy.py CG01        生成一张
  python3 tools/gen_cg_comfy.py all         批量 13 张（建议夜里跑）
  python3 tools/gen_cg_comfy.py CG05 3      生成 3 个变体挑最好
"""
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request

API = "http://127.0.0.1:8188"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "art", "cg_ai")
LORA_DIR = "/home/camael/AI/ComfyUI/models/loras"
# 游戏内引用目录（程序化占位 CG 的路径）——AI 成品同步一份保持引用路径不变
INGAME_DIR = os.path.join(ROOT, "assets", "art", "cg")
PORTRAIT_DIR = os.path.join(ROOT, "assets", "art", "portraits")

# —— 模型白名单（全部经 probe 实测 OK；禁止添加任何视频模型）——
ALLOWED_CKPTS = {
    "sdxl": "sdxl/Illustrious2.5D半写实二次元风格模型_v1.3_2.safetensors",  # 默认
    "ink15": "sd1.5/1.5 山川梦绘集_V1_mix_V1.safetensors",
    "cute15": "sd1.5/猫爪_可爱二次元模型_1.0.safetensors",
}
# 插画风路线：不再用像素 LoRA（用户拍板"不追求像素了"）。留空即纯提示词。
DEFAULT_LORA = None
BANNED_KEYWORDS = ("wan", "video", "svd", "hunyuan", "ltx", "cogvideo",
                   "animate", "morph", "framepack", "minimax")

NEGATIVE = ("text, watermark, signature, ui, frame, border, lowres, worst quality, "
            "jpeg artifacts, extra limbs, deformed hands, chibi, super deformed, "
            "modern clothing, 3d render, photorealistic, pixel art, bright cheerful colors")

# 风格锚：统一挂每条 prompt 开头，保证所有图同一个世界观（插画风定稿）
STYLE = ("anime illustration, painterly, cinematic lighting, highly detailed, "
         "dark fantasy, muted blue-grey palette with warm candlelight accents, "
         "atmospheric, ")
STYLE_SDXL = "masterpiece, best quality, very aesthetic, " + STYLE  # Illustrious 系吃质量词

# —— 13 张 CG（构图出自 GDD/09 第五节；seed 固定可复现）——
CGS = [
    {"id": "CG01", "slug": "white_raven", "seed": 147, "cfg": 7,
     "prompt": "no humans, inside a grand cathedral nave, (a single white bird in flight:1.4), (snow-white plumage:1.4), wings fully spread gliding across golden morning sunbeams, "
               "huge glowing stained-glass rose window behind the bird, dust motes glittering in the light, festive red banners hanging from marble pillars, "
               "stone floor far below, bright hopeful morning mood, cinematic wide shot",
     "neg_extra": "1girl, 1boy, human, people, crowd, angel, humanoid, face, person, girl, owl, black feathers, grey body, dark plumage, giant bird, oversized animal, chibi, cloak, robe"},{"id": "CG02", "slug": "warm_scale", "seed": 109, "cfg": 7,  # seed 109 = 三变体中选中稿（垂死趴地+少年立于头前）
     "prompt": "close-up side view, a huge black dragon head lowered sideways, resting heavily on the snow-covered ground, the dying dragon's golden eye half-closed and glistening, mouth closed, "
               "ragged breath steaming in the freezing air, old scars and a broken horn, "
               "a young boy with short dark blue hair in silver partial armor standing before the dragon's snout, his small hand reaching toward the dragon's nose, "
               "snow drifting in dark stone ruins, faint ember light, cinematic composition",
     "neg_extra": "roaring, open mouth, bared fangs, two humans, girl, woman, kiss, romance, dragon alone, no humans, white dragon, fur, feathers, humanoid dragon, anthro, standing dragon, rearing up"},
    {"id": "CG03", "slug": "soothing", "seed": 103,
     "prompt": "a priestess gently placing her hand on a young knight's forehead beside a campfire at night, snowstorm outside, faint glowing scale patterns on his arm, warm firelight against cold blue night"},
    {"id": "CG04", "slug": "beads", "seed": 130,  # seed 111 固执复刻"黑袍黑发"，换 130
     "prompt": "1boy, (young knight apprentice with short dark blue hair in silver partial armor:1.3), kneeling on snowy stone floor, cradling a dying priestess girl in his arms, "
               "she has long silver-white hair and white-gold vestments, eyes closed, head resting against his chest, "
               "her hand slipping down from his forehead, "
               "(white prayer beads scattered across the snowy ground:1.3), a loose bead string, one bead rolling away in the foreground, "
               "dark stone ruins at night, gentle snowfall through a broken ceiling, "
               "cold desaturated palette, quiet tragedy, grief, no blood",
     "neg_extra": "dragon, monster, creature, standing, standing girl, multiple people in background, black robe, black cloak, black hair, dark armor, role reversal"},
    {"id": "CG05", "slug": "awakening", "seed": 115,
     "prompt": "close-up side view, a huge black dragon head lowered sideways, the dragon's forehead gently touching the forehead of a young boy with short dark blue hair, the boy kneeling below the dragon head, his small hand resting on the dragon's snout, "
               "glowing cyan scale marks lighting up along the boy's arm, both sharing a quiet sorrowful moment, "
               "snow drifting in dark stone ruins, faint ember light, cinematic composition",
     "neg_extra": "roaring, open mouth, bared fangs, two humans, girl, woman, kiss, romance, dragon alone, no humans"},
    {"id": "CG06", "slug": "beheading", "seed": 321, "cfg": 7.5,  # seed 321 = 选中稿；"execution"一词会召唤绞刑架，改用舞台式描述
     "prompt": "(a raised wooden stage platform made of fresh pale timber:1.4), wooden support posts and a short wooden staircase leading up, built in a snowy capital city square, "
               "(1man:1.3), a lone hero in ornate silver armor and a long white cape standing on top of the wooden platform, sword tip resting down against the planks, seen from a low angle, "
               "snow stopped, overcast pale winter sky, silent empty square, grim cathedral spires around, ominous stillness, cinematic",
     "neg_extra": "dragon, creature, monster, multiple people, crowd, giant bird, chibi, fire, hanging, noose, gallows, ropes, crucifixion, woman, girl, hood, second person, extra figure, crouching person, kneeling person"},
    {"id": "CG07", "slug": "ice_mirror", "seed": 117,
     "prompt": "1boy, young mage with short dark hair in dark purple robes, hood down, one arm outstretched casting a spell, "
               "shielding a smaller knight boy behind his back, "
               "a wall of magical ice shards exploding forward in front of them, shards flying, "
               "snow, dark ruins at night, dramatic light, urgency",
     "neg_extra": "girl, woman, wings, monster, creature, weapon, sword, grayscale, monochrome"},
    {"id": "CG08", "slug": "ash_prayer", "seed": 122,  # 旧稿构图暧昧（用户误读）；照抄 CG05 成功结构，改闭眼趴地+抚吻部告别
     "prompt": "close-up side view, a huge black dragon head lowered sideways, resting on the snowy ground, the dragon's eyes closed, still and peaceful, breath mist rising weakly, "
               "a young boy with short dark blue hair kneeling beside the dragon's huge snout, his small hand resting on the dragon's snout in farewell, head bowed, "
               "a single candle burning on the ground near them, faint warm ember light against cold blue darkness, "
               "snow drifting in dark stone ruins, vast loneliness, quiet mourning, cinematic composition",
     "neg_extra": "roaring, open mouth, bared fangs, two humans, girl, woman, kiss, romance, standing dragon, rearing, living dragon, awake dragon, armor on dragon, clothed dragon, humanoid dragon, anthro, furry, dragon man, wings on human, monster, creature, skeleton, bones, fire breath"},
    {"id": "CG09", "slug": "two_copper", "seed": 109,
     "prompt": "two copper coins side by side on fresh undisturbed snow, extreme close-up still life, soft pale winter light, melancholic"},
    {"id": "CG10", "slug": "blood_march", "seed": 117,  # act2_end 实际文案=剑落雪+白鸦+丧钟，旧"血洗行军"描述与文本无关
     "prompt": "no humans, a lone sword planted upright in the fresh snow atop a wooden execution platform, "
               "(a single white crow perched on the wooden railing:1.3), head tilted, looking at the viewer, "
               "a dark human capital with cathedral spires and a tall bell tower in the distance at dusk, faint crimson glow on the horizon, ash drifting like snow, "
               "quiet aftermath of a duel, somber and still, cinematic wide shot",
     "neg_extra": "people, person, human, figures, crowd, dragon, monster, creature, fire, burning"},
    {"id": "CG11", "slug": "unspoiled_snow", "seed": 111,
     "prompt": "a young white birch sapling at a mountain cave entrance, white prayer beads buried at its roots, snowfall just stopped, pale dawn light, serene and hopeful, the brightest scene of the game"},
    {"id": "CG12", "slug": "new_party", "seed": 112,
     "prompt": "five young adventurers at a mountain pass before a dark cave mouth, one holding a banner with a dragon emblem, in the cave darkness a colossal golden eye barely beginning to open, dawn backlight"},
    {"id": "CG13", "slug": "white_raven_loop", "seed": 113,  # 幻觉/复仇未竟两结局共用：文案都点名白鸦，旧图无鸦
     "prompt": "morning prayer hall interior, golden stained-glass light beams through tall windows, "
               "(a single white crow taking off in startled flight:1.4), snow-white plumage, wings spread wide, a few white feathers drifting down, "
               "rows of wooden pews and candle stands below, empty stone aisle, deja vu stillness, cinematic wide shot",
     "neg_extra": "people, person, human, knight, crowd, black crow, dark feathers, owl, dragon, monster"},
    {"id": "CG14", "slug": "dragon_awakening", "seed": 114,  # 魔化演出：锁链崩断、鳞甲吞没、城市显出原形（PNG 曾丢失，2026-11-07 重制）
     "prompt": "(1boy:1.3), a young man with short dark blue hair standing at the center of the transformation, "
               "glowing cyan scale patterns spreading across his cheek and arm, (six broken chain links shattering off his arms, glowing cracks:1.3), "
               "faint golden eyes, black regal armor with scale motifs emerging over his body, dark aura rising like smoke, "
               "a grey iron human capital city skyline looming behind him at dusk, dramatic low angle, dark fantasy, ominous coronation",
     "neg_extra": "girl, woman, full dragon, lizard face, monster, creature, crowd, multiple people, fire, burning"},
    {"id": "CG15", "slug": "departure", "seed": 777, "cfg": 8,  # 旧稿=暖色小镇闲逛，与"雪路出征"文案无关；钉死雪+旗+金晨光
     "prompt": "(1boy, solo:1.4), young knight apprentice with (short dark blue hair:1.3) in plain silver armor, standing at a grand cathedral city gate in golden morning light, "
               "holding a travel pack, looking at a distant expedition with banners departing down the road, "
               "(snow-covered street:1.3), (festive red banners hanging:1.2), cold winter morning, lonely quiet mood, full body, wide shot",
     "neg_extra": "dragon, creature, monster, crowd focus, giant bird, owl, chibi, multiple boys in focus, group shot, brown hair, summer, green grass, desert, warm palette, woman, girl"},
]

# —— 角色头像（对话/战斗侧栏用，832x1216 竖幅）——
# 外貌 token 在各条 prompt 内固定，保证多图同人
PORTRAITS = [
    {"id": "P01", "slug": "protag_squire", "seed": 201,
     "prompt": "1boy, young androgynous knight apprentice, short dark blue hair, gentle uncertain eyes, silver partial armor over blue tunic, white tabard with holy emblem"},
    {"id": "P02", "slug": "protag_awakened", "seed": 202,
     "prompt": "1boy, same young knight now awakened demon prince, short dark blue hair, glowing cyan scale patterns on cheek and neck, faintly glowing golden eyes, black regal armor with scale motifs, dark aura"},
    {"id": "P03", "slug": "hero", "seed": 203,
     "prompt": "1man, handsome golden-haired hero in ornate gold and white armor, confident but weary smile, small scar on cheek, red cape"},
    {"id": "P04", "slug": "priestess", "seed": 204,
     "prompt": "1girl, gentle young priestess, silver-white long hair, white and gold vestments, warm sad smile, holding prayer beads"},
    {"id": "P05", "slug": "mage", "seed": 205,
     "prompt": "1person, mysterious mage, dark purple hooded robe, face half in shadow, calm knowing eyes, frost motes floating"},
    {"id": "P06", "slug": "merchant", "seed": 206,
     "prompt": "1man, jolly middle-aged merchant, thick mustache, fur-lined coat, wine-red scarf, snowflakes on shoulders"},
    {"id": "P07", "slug": "royal_guard", "seed": 207,
     "prompt": "1person, horned dark-elf royal guard of the demon court, silver-blue ornate armor, loyal stern face, short white hair"},
    {"id": "P08", "slug": "new_soothsayer", "seed": 208,
     "prompt": "1girl, priestess resembling an idealized colder version of a silver-haired priestess, flawless composure, hollow perfect smile, white and silver vestments, slightly uncanny"},
    # —— 敌对角色（战斗右上栏 & 图鉴）——
    {"id": "P09", "slug": "goblin_scout", "seed": 209,
     "prompt": "1creature, goblin scout portrait, green skin, pointed ears, cunning beady eyes, leather scraps armor, crude earring"},
    {"id": "P10", "slug": "snow_wolf", "seed": 210,
     "prompt": "1creature, dire snow wolf head portrait, silver-grey fur, golden predator eyes, frost on whiskers, wild and intelligent"},
    {"id": "P11", "slug": "orc_hunter", "seed": 211,
     "prompt": "1creature, orc hunter portrait, tusks, weathered bronze skin, braided black hair, bone and leather armor, war paint"},
    {"id": "P12", "slug": "rage_troll", "seed": 212,
     "prompt": "1creature, massive mountain troll portrait, stone-grey skin, small furious amber eyes, mossy shoulders, broken chains"},
    {"id": "P13", "slug": "slime_mat", "seed": 213,
     "prompt": "1creature, cute-but-eerie slime creature portrait, translucent teal jelly body, dark core, soft glow, bubbles inside"},
    {"id": "P14", "slug": "dragon_father", "seed": 214,
     "prompt": "1creature, ancient black dragon portrait, glowing cyan scale veins, golden wise sorrowful eye, broken horns, old battle scars, regal and tragic"},
    {"id": "P15", "slug": "border_soldier", "seed": 215,
     "prompt": "1man, weary border conscript soldier portrait, padded gambeson, simple helm, chapped face, homesick eyes"},
    {"id": "P16", "slug": "officer", "seed": 216,
     "prompt": "1man, stern human officer portrait, polished half-plate, blue officer sash, thin moustache, cold command gaze"},
    {"id": "P17", "slug": "holy_paladin", "seed": 217,
     "prompt": "1person, zealous holy paladin portrait, tower shield, winged helm under arm, white and gold tabard, fanatical certainty"},
    {"id": "P18", "slug": "inquisitor", "seed": 218,
     "prompt": "1person, church inquisitor portrait, dark robe with white trim, chain of holy seals, burning brands, merciless calm"},
]


def guard(name: str) -> None:
    """白名单 + 视频模型禁运（用户明令两条，见文件头）"""
    low = name.lower()
    for kw in BANNED_KEYWORDS:
        if kw in low:
            raise SystemExit("拒绝：疑似视频模型（命中 %s）：%s" % (kw, name))


def build_graph(ckpt_key, pos, neg, w, h, seed, steps, cfg, lora):
    """txt2img 图（ComfyUI API 格式）。lora 非空时插入 LoraLoader 链。
    以后想上更复杂工作流：界面搭好 → 导出 API JSON → 替换本函数。"""
    g = {
        "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": ALLOWED_CKPTS[ckpt_key]}},
    }
    model_src, clip_src = ["1", 0], ["1", 1]
    if lora:
        guard(lora["file"])
        if not os.path.exists(os.path.join(LORA_DIR, lora["file"])):
            raise SystemExit("LoRA 文件不存在：%s（先下载）" % lora["file"])
        g["2"] = {"class_type": "LoraLoader", "inputs": {
            "lora_name": lora["file"], "strength_model": lora["strength"],
            "strength_clip": lora["strength"],
            "model": model_src, "clip": clip_src}}
        model_src, clip_src = ["2", 0], ["2", 1]
    nid = 3
    g[str(nid)] = {"class_type": "CLIPTextEncode", "inputs": {"text": pos, "clip": clip_src}}
    pos_id = str(nid); nid += 1
    g[str(nid)] = {"class_type": "CLIPTextEncode", "inputs": {"text": neg, "clip": clip_src}}
    neg_id = str(nid); nid += 1
    g[str(nid)] = {"class_type": "EmptyLatentImage", "inputs": {"width": w, "height": h, "batch_size": 1}}
    lat_id = str(nid); nid += 1
    g[str(nid)] = {"class_type": "KSampler", "inputs": {
        "seed": seed, "steps": steps, "cfg": cfg,
        "sampler_name": "euler", "scheduler": "normal", "denoise": 1.0,
        "model": model_src, "positive": [pos_id, 0], "negative": [neg_id, 0],
        "latent_image": [lat_id, 0]}}
    ks_id = str(nid); nid += 1
    g[str(nid)] = {"class_type": "VAEDecode", "inputs": {"samples": [ks_id, 0], "vae": ["1", 2]}}
    vae_id = str(nid); nid += 1
    g[str(nid)] = {"class_type": "SaveImage", "inputs": {"filename_prefix": "cgai", "images": [vae_id, 0]}}
    return g


def api_post(path, obj):
    req = urllib.request.Request(
        API + path, data=json.dumps(obj).encode("utf-8"),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode("utf-8"))


def api_get_json(path):
    with urllib.request.urlopen(API + path, timeout=30) as r:
        return json.loads(r.read().decode("utf-8"))


def submit_and_fetch(graph, dest_path, timeout_s=420):
    pid = api_post("/prompt", {"prompt": graph})["prompt_id"]
    t0 = time.time()
    while time.time() - t0 < timeout_s:
        time.sleep(2)
        hist = api_get_json("/history/%s" % pid)
        if pid not in hist:
            continue
        entry = hist[pid]
        if entry.get("status", {}).get("status_str") == "error":
            for m in entry["status"].get("messages", []):
                if m[0] == "execution_error":
                    raise SystemExit("ComfyUI 出错 @%s: %s" % (
                        m[1].get("node_type"), str(m[1].get("exception_message"))[:200]))
            raise SystemExit("ComfyUI 执行出错（未提供细节）")
        outputs = entry.get("outputs", {})
        if outputs:
            for node_out in outputs.values():
                for img in node_out.get("images", []):
                    url = "/view?filename=%s&subfolder=%s&type=%s" % (
                        urllib.parse.quote(img["filename"]),
                        urllib.parse.quote(img.get("subfolder", "")),
                        img.get("type", "output"))
                    with urllib.request.urlopen(API + url, timeout=60) as r:
                        data = r.read()
                    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
                    with open(dest_path, "wb") as f:
                        f.write(data)
                    print("CG  ->", os.path.relpath(dest_path, ROOT), flush=True)
                    return
    raise SystemExit("超时：%ds 未出图（可能 ComfyUI 正在排队）" % timeout_s)


def gen_one(cg, variant=0):
    ckpt_key = cg.get("ckpt", "sdxl")
    guard(ALLOWED_CKPTS[ckpt_key])
    lora = DEFAULT_LORA if ckpt_key == "sdxl" else None
    seed = int(cg["seed"]) + variant * 7
    style = STYLE_SDXL if ckpt_key == "sdxl" else STYLE
    w, h = (1344, 768) if ckpt_key == "sdxl" else (640, 384)
    cfg, steps = (5.5, 28) if ckpt_key == "sdxl" else (7.0, 26)
    cfg = int(cg.get("cfg", cfg))  # 单图可覆盖：构图顽固时拉高 CFG 逼模型听话
    neg = NEGATIVE + (", " + cg["neg_extra"] if cg.get("neg_extra") else "")
    graph = build_graph(ckpt_key, style + cg["prompt"], neg, w, h, seed, steps, cfg, lora)
    suffix = "" if variant == 0 else "_v%d" % (variant + 1)
    dest = os.path.join(OUT, "%s_%s%s.png" % (cg["id"], cg["slug"], suffix))
    print("提交 %-5s %-16s ckpt=%s seed=%d %dx%d" % (
        cg["id"], cg["slug"], ckpt_key, seed, w, h), flush=True)
    submit_and_fetch(graph, dest)
    # 注：旧版会同步一份 1280x720 到 assets/art/cg/——该目录已无任何代码引用，
    # 2026-11-07 清理时删除，不再生成副本（游戏只读 assets/art/cg_ai/）。


def gen_portrait(p, variant=0):
    """头像：832x1216 竖幅，输出 assets/art/portraits/（不参与同名覆盖）"""
    guard(ALLOWED_CKPTS["sdxl"])
    seed = int(p["seed"]) + variant * 7
    pos = STYLE_SDXL + ("portrait, bust shot, upper body, looking at viewer, "
                        "simple dark gradient background, " + p["prompt"])
    graph = build_graph("sdxl", pos, NEGATIVE, 832, 1216, seed, steps=26, cfg=5.5, lora=None)
    suffix = "" if variant == 0 else "_v%d" % (variant + 1)
    dest = os.path.join(PORTRAIT_DIR, "%s_%s%s.png" % (p["id"], p["slug"], suffix))
    print("提交 %-5s %-16s 头像 seed=%d" % (p["id"], p["slug"], seed), flush=True)
    submit_and_fetch(graph, dest)


def main():
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(INGAME_DIR, exist_ok=True)
    os.makedirs(PORTRAIT_DIR, exist_ok=True)
    args = sys.argv[1:]
    if not args or args[0] == "list":
        for cg in CGS:
            print("%s  %-18s %s" % (cg["id"], cg["slug"], cg["prompt"][:60] + "…"))
        for p in PORTRAITS:
            print("%s  %-18s [头像] %s" % (p["id"], p["slug"], p["prompt"][:48] + "…"))
        print("\n用法：python3 tools/gen_cg_comfy.py [CGxx|Pxx|cgall|portraits] [变体数]")
        return
    variants = int(args[1]) if len(args) > 1 else 1
    cmd = args[0]
    if cmd == "cgall":
        targets = CGS
        for cg in targets:
            for v in range(variants):
                gen_one(cg, v)
        return
    if cmd == "portraits":
        for p in PORTRAITS:
            for v in range(variants):
                gen_portrait(p, v)
        return
    hit = [c for c in CGS if c["id"].upper() == cmd.upper()] or \
          [p for p in PORTRAITS if p["id"].upper() == cmd.upper()]
    if not hit:
        raise SystemExit("没找到 %s，先 list" % cmd)
    for t in hit:
        for v in range(variants):
            if t["id"].startswith("P"):
                gen_portrait(t, v)
            else:
                gen_one(t, v)


if __name__ == "__main__":
    main()
