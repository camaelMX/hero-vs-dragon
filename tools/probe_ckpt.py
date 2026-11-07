#!/usr/bin/env python3
"""探测 ComfyUI 各 checkpoint 能否加载（最小 256x256 3步图）"""
import json, time, urllib.request
CKS = ["sd1.5/1.5 山川梦绘集_V1_mix_V1.safetensors",
       "sd1.5/儿童绘本 _ CrayonPaiting_1.0.safetensors",
       "sd1.5/猫爪_可爱二次元模型_1.0.safetensors",
       "sdxl/Illustrious2.5D半写实二次元风格模型_v1.3_2.safetensors",
       "sdxl/heartOfAppleXL_v20_xl.safetensors"]
def run(ckpt):
    g = {"1":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":ckpt}},
         "2":{"class_type":"CLIPTextEncode","inputs":{"text":"pixel art test","clip":["1",1]}},
         "3":{"class_type":"CLIPTextEncode","inputs":{"text":"bad","clip":["1",1]}},
         "4":{"class_type":"EmptyLatentImage","inputs":{"width":256,"height":256,"batch_size":1}},
         "5":{"class_type":"KSampler","inputs":{"seed":1,"steps":3,"cfg":7.0,"sampler_name":"euler","scheduler":"normal","denoise":1.0,"model":["1",0],"positive":["2",0],"negative":["3",0],"latent_image":["4",0]}},
         "6":{"class_type":"VAEDecode","inputs":{"samples":["5",0],"vae":["1",2]}},
         "7":{"class_type":"SaveImage","inputs":{"filename_prefix":"probe","images":["6",0]}}}
    req=urllib.request.Request("http://127.0.0.1:8188/prompt",data=json.dumps({"prompt":g}).encode(),headers={"Content-Type":"application/json"})
    pid=json.loads(urllib.request.urlopen(req,timeout=30).read())["prompt_id"]
    for _ in range(120):
        time.sleep(2)
        h=json.loads(urllib.request.urlopen("http://127.0.0.1:8188/history/%s"%pid,timeout=30).read())
        if pid in h:
            st=h[pid].get("status",{})
            if st.get("status_str")=="error":
                for m in st.get("messages",[]):
                    if m[0]=="execution_error": return "FAIL: "+str(m[1].get("exception_message"))[:90]
                return "FAIL: ?"
            if h[pid].get("outputs"): return "OK"
    return "TIMEOUT"
for c in CKS:
    print(c, "=>", run(c), flush=True)
print("PROBE-DONE")
