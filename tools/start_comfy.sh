#!/bin/bash
# ComfyUI 启动脚本（用户指定：--enable-dynamic-vram 动态显存管理，内存占用更优）
# 用法：bash tools/start_comfy.sh
pkill -f "ComfyUI/main.py" 2>/dev/null; sleep 1
cd /home/camael/AI/ComfyUI
setsid nohup /home/camael/AI/ComfyUI/venv/bin/python main.py \
  --enable-dynamic-vram --listen 127.0.0.1 --port 8188 \
  > /home/camael/AI/ComfyUI/comfyui.log 2>&1 &
sleep 10
curl -s --max-time 5 http://127.0.0.1:8188/system_stats > /dev/null \
  && echo "ComfyUI 启动成功（动态显存）" \
  || { echo "启动失败，日志尾部："; tail -5 /home/camael/AI/ComfyUI/comfyui.log; }
