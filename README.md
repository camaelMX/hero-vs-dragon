# 《勇者斗恶龙：魔子》—— 灰盒原型

Godot 4.7.2（标准版 / GDScript）。设计文档在 `GDD/` 目录（编辑器里被 `.gdignore` 隐藏，是给人迭代用的）。

## 现在能玩什么

**灰盒 0-2：村庄→赶路循环** —— 村庄整备（教会回血 / 挑战等级旋钮 / 定神香 / 牧师安抚）→ 每步三选一怪卡 → 战斗 → 踩卡铺路 → 8 步一轮。SAN 计量、升级成长、掉落、战败重试/撤退全部接入。美术与音频为**程序化生成的占位资产**（`tools/` 下两个生成器，可随时重跑）。

## 怎么运行

1. 双击 Godot → **Import** → 选择本目录的 `project.godot` → **Import & Edit**
2. 按 **F5** 运行

## 操作

| 键 | 作用 |
|---|---|
| 村庄按钮 | 教会回血 / 挑战等级 / 买定神香 / 牧师安抚 / 出发 |
| 卡牌按钮 | 每步三选一（卡面有星级与奖励预告） |
| 战斗按钮 | 攻击 / 血瓶 / 切反应预设 / 撤退 / 结束回合 |
| 空格 | 防御 QTE（敌人攻击主角的瞬间按，按中黄色=完美防御） |
| F | 闪避 QTE（窗口更小：成功=完全回避，失败=吃满+失去下回合） |

## 自动冒烟测试（不开编辑器验证整个循环）

```bash
AUTOPLAY=1 godot --headless --path .
```

AI 会自动跑满 2 轮村庄-赶路循环后退出（exit=0 即通过）；终端输出战斗日志。

## 代码结构

```
scripts/
  data/units_db.gd        数值总表（单位属性与 QTE 旋钮，对应 GDD/07）
  data/cards_db.gd        怪卡定义（星级/经验/掉落/数量）
  data/game_state.gd      Autoload 全局状态（SAN/金币/等级/进度，跨场景）
  combat/fighter.gd       战斗单位：数据 + 占位像素外观
  combat/qte_ring.gd      QTE 判定条（防御/闪避两种模式）
  combat/party_ai.gd      AI 队友最小行为树
  combat/combat_scene.gd  战斗主循环（回合引擎 + QTE 结算 + UI）
  run/run_scene.gd        村庄/赶路循环（三选一卡牌 + 铺路 + SAN 面板）
scenes/
  run/run_scene.tscn      主场景
  combat/combat_scene.tscn 战斗场景
tools/
  gen_sprites.py          程序化像素美术生成器（纯标准库）
  gen_audio.py            程序化音效/BGM 生成器（纯标准库）
assets/                   生成的占位资产（美术/音频），正式资产按 GDD/09 替换
```

## 已知占位 / 待办

- 伤害公式已按模拟校准为乘法减伤 `atk × 60/(60+def)`（tools/sim_act1.py，三策略×1000 局验收）
- 灰盒 0-3（第一幕 Boss 父王 + 觉醒 + SAN 闸门）未接入
- 像素小人为程序化占位，正式美术按 `GDD/09_资产清单.md` 替换（同文件名覆盖即可）
- 中文若显示方块 = 系统缺 CJK 字体：`sudo apt install fonts-noto-cjk`
