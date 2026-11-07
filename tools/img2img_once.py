#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
img2img_once.py —— 单图重绘（文生图搞不定时，用现成好图 + 低重绘幅度改细节）

用法:
  python3 tools/img2img_once.py <src.png> <dest.png> <seed> <denoise> "<正向提示词>" ["负向附加词"]

原理: ComfyUI API img2img —— LoadImage → VAEEncode → KSampler(denoise) → SaveImage
  denoise 0.4~0.5 = 基本只调色调; 0.6~0.7 = 保构图改内容; >0.8 ≈ 重画。
模型白名单/黑图防护与 gen_cg_comfy.py 相同（只跑文生图系，禁视频模型）。
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

API = "http://127.0.0.1:8188"
CKPT = "sdxl/Illustrious2.5D半写实二次元风格模型_v1.3_2.safetensors"

STYLE = ("masterpiece, best quality, very aesthetic, anime illustration, painterly, "
         "cinematic lighting, highly detailed, dark fantasy, muted blue-grey palette "
         "with warm candlelight accents, atmospheric, ")
NEG_BASE = ("text, watermark, signature, ui, frame, border, lowres, worst quality, "
            "jpeg artifacts, extra limbs, deformed hands, chibi, super deformed, "
            "modern clothing, 3d render, photorealistic, pixel art, bright cheerful colors")


def api_post(path, obj):
    req = urllib.request.Request(API + path, data=json.dumps(obj).encode("utf-8"),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode("utf-8"))


def upload_image(src):
    """把本地图片传进 ComfyUI 的 input 目录，返回服务器端文件名"""
    boundary = "----zcform7f3a1b"
    with open(src, "rb") as f:
        data = f.read()
    name = os.path.basename(src)
    body = (
        ("--%s\r\nContent-Disposition: form-data; name=\"image\"; filename=\"%s\"\r\n"
         "Content-Type: image/png\r\n\r\n" % (boundary, name)).encode()
        + data
        + ("\r\n--%s\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\ntrue\r\n--%s--\r\n"
           % (boundary, boundary)).encode())
    req = urllib.request.Request(API + "/upload/image", data=body, headers={
        "Content-Type": "multipart/form-data; boundary=" + boundary})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())["name"]


def main():
    src, dest, seed, denoise, pos, neg_extra = (
        sys.argv[1], sys.argv[2], int(sys.argv[3]), float(sys.argv[4]),
        sys.argv[5], sys.argv[6] if len(sys.argv) > 6 else "")
    server_img = upload_image(src)

    g = {
        "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": CKPT}},
        "2": {"class_type": "CLIPTextEncode", "inputs": {"text": STYLE + pos, "clip": ["1", 1]}},
        "3": {"class_type": "CLIPTextEncode",
              "inputs": {"text": NEG_BASE + (", " + neg_extra if neg_extra else ""), "clip": ["1", 1]}},
        "4": {"class_type": "LoadImage", "inputs": {"image": server_img}},
        "5": {"class_type": "VAEEncode", "inputs": {"pixels": ["4", 0], "vae": ["1", 2]}},
        "6": {"class_type": "EmptyLatentImage",
              "inputs": {"width": 1344, "height": 768, "batch_size": 1}},  # 占位，不用
        "7": {"class_type": "KSampler",
              "inputs": {"seed": seed, "steps": 28, "cfg": 7.0,
                         "sampler_name": "euler", "scheduler": "normal",
                         "denoise": denoise, "model": ["1", 0],
                         "positive": ["2", 0], "negative": ["3", 0],
                         "latent_image": ["5", 0]}},
        "8": {"class_type": "VAEDecode", "inputs": {"samples": ["7", 0], "vae": ["1", 2]}},
        "9": {"class_type": "SaveImage",
              "inputs": {"filename_prefix": "img2img", "images": ["8", 0]}},
    }
    r = api_post("/prompt", {"prompt": g})
    pid = r["prompt_id"]
    # 轮询直到出图
    for _ in range(120):
        time.sleep(5)
        with urllib.request.urlopen(API + "/history/" + pid, timeout=30) as r2:
            h = json.loads(r2.read().decode())
        if pid in h and h[pid].get("outputs"):
            outs = h[pid]["outputs"]
            for node in outs.values():
                for img in node.get("images", []):
                    url = "/view?filename=%s&type=%s&subfolder=%s" % (
                        urllib.parse.quote(img["filename"]), img["type"],
                        urllib.parse.quote(img.get("subfolder", "")))
                    with urllib.request.urlopen(API + url, timeout=60) as r3:
                        open(dest, "wb").write(r3.read())
                    print("完成 ->", dest)
                    return
    raise SystemExit("超时：ComfyUI 未返回结果")


if __name__ == "__main__":
    main()
