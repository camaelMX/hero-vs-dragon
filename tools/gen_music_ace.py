#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_music_ace.py —— 用本地 ACE-Step 3.5B 生成游戏 BGM（替换合成器 v2）

用法（务必用 ComfyUI 的 venv 跑，AMD torch 在里面）：
  /home/camael/AI/ComfyUI/venv/bin/python tools/gen_music_ace.py [village|battle|boss|all]

流程：
  1. 生成到 assets/audio/bgm_ace/（暂存，wav）
  2. ffmpeg 转 ogg
  3. 备份旧曲到 assets/audio/bgm_v2_backup/ 后同名替换 assets/audio/bgm/
  游戏代码零改动（文件名一致，finished->play 循环沿用）。

运行前确认：ComfyUI 若在生成图片会抢显存，ACE 走 cpu_offload 保底不炸。
"""
import os
import shutil
import subprocess
import sys

sys.path.insert(0, "/home/camael/AI/ACE-Step")
os.environ.setdefault("HF_HUB_OFFLINE", "1")  # 权重全在本地，断网也要能跑

from acestep.pipeline_ace_step import ACEStepPipeline  # noqa: E402

# —— 补丁：新版 torchaudio 保存 wav 强制走 torchcodec（未安装即崩）——
# 直接用 soundfile 落盘，绕开 torchaudio 的后端选择
import time  # noqa: E402
import soundfile as sf  # noqa: E402
import torch  # noqa: E402


def _save_wav_file_patch(self, target_wav, idx, save_path=None,
                         sample_rate=48000, format="wav"):
    # soundfile 的 py3.14 轮子 libsndfile 损坏（连显式 WAV 都报 Format not recognised）
    # ——改用标准库 wave 模块写 PCM16，零第三方依赖，绝无格式玄学
    import wave as _wave
    import numpy as np
    out_dir = os.path.join(ROOT, "assets", "audio", "bgm_ace")
    os.makedirs(out_dir, exist_ok=True)
    if save_path is None or not os.path.isabs(save_path):
        save_path = os.path.join(
            out_dir, "output_%s_%d.wav" % (time.strftime("%Y%m%d%H%M%S"), idx))
    wav = target_wav.detach().float().cpu().numpy()
    pcm = (np.clip(wav, -1.0, 1.0) * 32767).astype("<i2")
    if pcm.ndim == 2:                      # (声道, 样本) → wave 要交织排列
        pcm = pcm.T
    with _wave.open(save_path, "wb") as w:
        w.setnchannels(1 if pcm.ndim == 1 else pcm.shape[1])
        w.setsampwidth(2)
        w.setframerate(int(sample_rate))
        w.writeframes(pcm.tobytes())
    return save_path


ACEStepPipeline.save_wav_file = _save_wav_file_patch

ROOT = "/home/camael/AI/game"
CKPT = "/home/camael/AI/acestep_weights"
STAGE = os.path.join(ROOT, "assets", "audio", "bgm_ace")
FINAL = os.path.join(ROOT, "assets", "audio", "bgm")
BACKUP = os.path.join(ROOT, "assets", "audio", "bgm_v2_backup")

# —— 三首曲子（对应游戏三场景；tags 走 ACE 的自然语言+标签混排）——
TRACKS = {
    "bgm_village": {
        "tags": "instrumental, warm gentle folk ballad, soft piano and warm strings, "
                "hopeful, calm, peaceful snow village morning, acoustic, 90 bpm",
        "dur": 90, "seed": 2024,
    },
    "bgm_battle": {
        "tags": "instrumental, epic dark fantasy battle theme, driving percussion, "
                "orchestral strings and brass, tense rhythm, heroic, 140 bpm",
        "dur": 75, "seed": 2025,
    },
    "bgm_boss": {
        "tags": "instrumental, tragic epic boss battle theme, dark orchestral, "
                "distant choir pad, heavy drums, dramatic slow build, emotional, 120 bpm",
        "dur": 90, "seed": 2026,
    },
}


def main():
    targets = sys.argv[1:] or ["village", "battle", "boss"]
    os.makedirs(STAGE, exist_ok=True)
    os.makedirs(BACKUP, exist_ok=True)

    print("加载 ACE-Step（bfloat16 + cpu_offload，首跑约 1-2 分钟）…", flush=True)
    # overlapped_decode 必须关：它会把 vocoder 块搬上 HIP GPU，在 AMD 上段错误；
    # 关掉后走 CPU 解码（慢一点但稳），扩散主体仍在 GPU。
    pipe = ACEStepPipeline(checkpoint_dir=CKPT, dtype="bfloat16",
                           cpu_offload=True, overlapped_decode=False)
    # 实验：ACE_GPU_DECODE=1 时把 DCAE/vocoder 搬上 GPU 走非重叠解码
    # （崩的是 overlapped 实现，普通解码路径未必崩；失败了去掉环境变量即回退 CPU）
    if os.environ.get("ACE_GPU_DECODE") == "1":
        print("试验：DCAE/vocoder → GPU 解码", flush=True)
        pipe.music_dcae = pipe.music_dcae.to("cuda").eval()

    for t in targets:
        name = "bgm_" + t
        cfg = TRACKS[name]
        print("生成 %s（%d 秒，seed=%d）…" % (name, cfg["dur"], cfg["seed"]), flush=True)
        res = pipe(prompt=cfg["tags"], lyrics="", audio_duration=cfg["dur"],
                   infer_step=48, guidance_scale=15.0, manual_seeds=[cfg["seed"]])
        wav = res[0] if isinstance(res, (list, tuple)) else res
        # 1) 暂存
        stage_wav = os.path.join(STAGE, name + ".wav")
        shutil.copy(wav, stage_wav)
        # 2) 备份旧曲（只在第一次备份，避免备份覆盖）
        old = os.path.join(FINAL, name + ".ogg")
        bak = os.path.join(BACKUP, name + ".ogg")
        if os.path.exists(old) and not os.path.exists(bak):
            shutil.copy(old, bak)
        # 3) 转 ogg 同名替换（游戏零改动）
        new_ogg = os.path.join(FINAL, name + ".ogg")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", stage_wav,
                        "-c:a", "libvorbis", "-q:a", "4", new_ogg], check=True)
        print("BGM  ->", os.path.relpath(new_ogg, ROOT), flush=True)
    print("MUSIC-DONE")


if __name__ == "__main__":
    main()
