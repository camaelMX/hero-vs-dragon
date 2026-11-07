#!/bin/bash
# ACE-Step 权重下载（ModelScope 官方仓库，AI 盘）+ 官方代码克隆与安装
set -e
BASE="https://modelscope.cn/models/ACE-Step/ACE-Step-v1-3.5B/resolve/master"
DST="/home/camael/AI/acestep_weights"
FILES=(
  "ace_step_transformer/diffusion_pytorch_model.safetensors"
  "ace_step_transformer/config.json"
  "music_dcae_f8c8/diffusion_pytorch_model.safetensors"
  "music_dcae_f8c8/config.json"
  "music_vocoder/diffusion_pytorch_model.safetensors"
  "music_vocoder/config.json"
  "umt5-base/model.safetensors"
  "umt5-base/config.json"
  "umt5-base/tokenizer.json"
  "umt5-base/tokenizer_config.json"
  "umt5-base/special_tokens_map.json"
)
mkdir -p "$DST"
for f in "${FILES[@]}"; do
  mkdir -p "$DST/$(dirname "$f")"
  echo "下载 $f"
  curl -sL -C - --retry 3 --max-time 36000 -o "$DST/$f" "$BASE/$f"
done
echo "WEIGHTS-DONE"
# 官方代码
cd /home/camael/AI
[ -d ACE-Step ] || git clone --depth 1 https://github.com/ace-step/ACE-Step.git
cd ACE-Step
/home/camael/AI/ComfyUI/venv/bin/pip install -e . --no-warn-script-location 2>&1 | tail -3
echo "ACE-SETUP-DONE"
