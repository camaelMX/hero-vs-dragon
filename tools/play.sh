#!/bin/bash
# 游戏一键启动（先导入新资产再进游戏——杜绝"新生成的图进游戏是黑屏"）
# 用法：bash tools/play.sh
cd /home/camael/AI/game
pkill -f "godot --path" 2>/dev/null; sleep 1
/home/camael/AI/godot_editor/4.7.2/Godot_v4.7.2-stable_linux.x86_64 --headless --path . --import > /dev/null 2>&1
DISPLAY=${DISPLAY:-:0} exec /home/camael/AI/godot_editor/4.7.2/Godot_v4.7.2-stable_linux.x86_64 --path .
