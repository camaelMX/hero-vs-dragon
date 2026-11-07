#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
inpaint_once.py —— 局部重绘：只重画蒙版区域，其余像素原样保留
用法: python3 tools/inpaint_once.py <src.png> <dest.png> <mask_l,t,r,b> <seed> "<正向>" ["负向附加"]
mask_l,t,r,b = 要重绘的矩形区域（在 1344x768 原图坐标上）
原理: VAEEncode(src) + SetLatentNoiseMask(矩形) + KSampler denoise=1.0
"""
import json, sys, time, urllib.parse, urllib.request
from PIL import Image
import numpy as np

API = "http://127.0.0.1:8188"
CKPT = "sdxl/Illustrious2.5D半写实二次元风格模型_v1.3_2.safetensors"
STYLE = ("masterpiece, best quality, anime illustration, painterly, cinematic lighting, "
         "dark fantasy, muted blue-grey palette, atmospheric, ")
NEG = ("text, watermark, lowres, worst quality, jpeg artifacts, 1girl, woman, person, "
       "chibi, 3d render, photorealistic, bright cheerful colors")

def api_post(path, obj):
    req = urllib.request.Request(API + path, data=json.dumps(obj).encode("utf-8"),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())

def upload(src):
    boundary = "----zcform7f3a1b"
    with open(src, "rb") as f:
        data = f.read()
    name = src.rsplit("/", 1)[-1]
    body = (("--%s\r\nContent-Disposition: form-data; name=\"image\"; filename=\"%s\"\r\n"
             "Content-Type: image/png\r\n\r\n" % (boundary, name)).encode() + data
            + ("\r\n--%s\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\ntrue\r\n--%s--\r\n"
               % (boundary, boundary)).encode())
    req = urllib.request.Request(API + "/upload/image", data=body, headers={
        "Content-Type": "multipart/form-data; boundary=" + boundary})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())["name"]

src, dest, box, seed, pos, negx = (sys.argv[1], sys.argv[2],
    [int(v) for v in sys.argv[3].split(",")], int(sys.argv[4]),
    sys.argv[5], sys.argv[6] if len(sys.argv) > 6 else "")

# 1) 生成蒙版图：矩形白 = 重绘，其余黑 = 保留
im = Image.open(src).convert("RGB")
W, H = im.size
m = np.zeros((H, W), dtype=np.uint8)
m[box[1]:box[3], box[0]:box[2]] = 255
mp = src.rsplit(".", 1)[0] + "_mask.png"
Image.fromarray(m).save(mp)

simg, smask = upload(src), upload(mp)
g = {
    "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": CKPT}},
    "2": {"class_type": "CLIPTextEncode", "inputs": {"text": STYLE + pos, "clip": ["1", 1]}},
    "3": {"class_type": "CLIPTextEncode", "inputs": {"text": NEG + (", " + negx if negx else ""), "clip": ["1", 1]}},
    "4": {"class_type": "LoadImage", "inputs": {"image": simg}},
    "5": {"class_type": "VAEEncode", "inputs": {"pixels": ["4", 0], "vae": ["1", 2]}},
    "6": {"class_type": "LoadImageMask", "inputs": {"image": smask, "channel": "red"}},
    "7": {"class_type": "SetLatentNoiseMask", "inputs": {"samples": ["5", 0], "mask": ["6", 0]}},
    "8": {"class_type": "KSampler", "inputs": {"seed": seed, "steps": 28, "cfg": 7.0,
          "sampler_name": "euler", "scheduler": "normal", "denoise": 1.0,
          "model": ["1", 0], "positive": ["2", 0], "negative": ["3", 0], "latent_image": ["7", 0]}},
    "9": {"class_type": "VAEDecode", "inputs": {"samples": ["8", 0], "vae": ["1", 2]}},
    "10": {"class_type": "SaveImage", "inputs": {"filename_prefix": "inpaint", "images": ["9", 0]}},
}
pid = api_post("/prompt", {"prompt": g})["prompt_id"]
for _ in range(120):
    time.sleep(5)
    with urllib.request.urlopen(API + "/history/" + pid, timeout=30) as r:
        h = json.loads(r.read().decode())
    if pid in h and h[pid].get("outputs"):
        for node in h[pid]["outputs"].values():
            for img in node.get("images", []):
                url = "/view?filename=%s&type=%s&subfolder=%s" % (
                    urllib.parse.quote(img["filename"]), img["type"],
                    urllib.parse.quote(img.get("subfolder", "")))
                with urllib.request.urlopen(API + url, timeout=60) as r2:
                    open(dest, "wb").write(r2.read())
                print("完成 ->", dest)
                sys.exit(0)
raise SystemExit("超时")
