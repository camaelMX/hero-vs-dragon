#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_audio.py —— 程序化生成音效与 BGM v2（纯标准库，零依赖）

v2 音乐升级点（回应"要洗脑且好听"）：
  * 和弦进行 + 声部编排：村庄=卡农进行(C-G-Am-F)，战斗=Am-F-C-G，Boss=Dm-Bb-Gm-A
  * 洗脑结构：2 小节钩子旋律 + 应答句，每 4 小节循环，微变化防腻
  * 琶音铺底（16 分音符碎和弦 = 芯片乐灵魂）、八度跳动贝斯
  * 鼓组：底鼓/军鼓/踩镲 合成，战斗与 Boss 有完整律动
  * 延迟回声（feedback delay）给旋律 bus —— 一步到位的"制作感"
  * 软包络（ADSR）、主旋律颤音、母线软限幅 + 归一化

运行：python3 tools/gen_audio.py   （在项目根目录执行）
"""
import math
import os
import random
import struct
import subprocess
import wave

SR = 44100
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_SFX = os.path.join(ROOT, "assets", "audio", "sfx")
OUT_BGM = os.path.join(ROOT, "assets", "audio", "bgm")


# ============================================================
# 基础合成
# ============================================================

def write_wav(path: str, samples):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    frames = b"".join(
        struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32000)) for s in samples
    )
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(frames)


def silence(dur: float):
    return [0.0] * int(SR * dur)


def midi_hz(m: float) -> float:
    return 440.0 * (2.0 ** ((m - 69) / 12.0))


def osc(midi, dur, wave_type="tri", duty=0.5, gain=0.5, attack=0.01,
        release=0.06, vib=0.0, glide_to=None):
    """单音符。vib>0 加颤音（5.2Hz），glide_to 滑音。"""
    n = int(SR * dur)
    out = []
    phase = 0.0
    f0 = midi_hz(midi)
    f1 = f0 if glide_to is None else midi_hz(glide_to)
    for i in range(n):
        t = i / n
        f = f0 + (f1 - f0) * t
        if vib > 0.0:
            f *= 1.0 + vib * 0.006 * math.sin(2 * math.pi * 5.2 * i / SR)
        phase += 2.0 * math.pi * f / SR
        u = (phase / (2 * math.pi)) % 1.0
        if wave_type == "sine":
            v = math.sin(phase)
        elif wave_type == "square":
            v = 1.0 if u < duty else -1.0
        else:  # tri
            v = 2.0 * abs(2.0 * u - 1.0) - 1.0
        # ADSR（A 快、R 收尾，中段带 92% 持续，避免"方片感"）
        if t * dur < attack:
            e = (t * dur) / attack
        elif t > 1.0 - release / dur:
            e = max(0.0, (1.0 - t) * dur / release)
        else:
            e = 1.0
        out.append(v * gain * e)
    return out


def noise(dur, gain=0.5, lp=0.25, decay=2.0, seed=7):
    rnd = random.Random(seed)
    n = int(SR * dur)
    out = []
    y = 0.0
    for i in range(n):
        x = rnd.uniform(-1.0, 1.0)
        y += lp * (x - y)
        out.append(y * gain * max(0.0, 1.0 - i / n) ** decay)
    return out


def concat(*tracks):
    out = []
    for t in tracks:
        out.extend(t)
    return out


def pad_to(samples, n):
    if len(samples) < n:
        samples.extend([0.0] * (n - len(samples)))
    return samples[:n]


class Bus:
    """一条音轨：把音符/鼓样本按时间混进来，最后可挂延迟回声。"""

    def __init__(self, total_sec: float):
        self.n = int(SR * total_sec)
        self.buf = [0.0] * self.n

    def add(self, start_sec: float, samples, gain=1.0):
        s0 = int(start_sec * SR)
        for i, s in enumerate(samples):
            j = s0 + i
            if 0 <= j < self.n:
                self.buf[j] += s * gain

    def echo(self, time_sec: float, fb: float = 0.32, mix_gain: float = 0.35):
        """反馈延迟： lead bus 挂上立刻有制作感"""
        d = int(time_sec * SR)
        for i in range(self.n):
            if i >= d:
                self.buf[i] += self.buf[i - d] * fb * mix_gain

    def samples(self):
        return self.buf


def master_mix(buses, peak=0.88):
    """混音 + 软限幅 + 归一化"""
    n = max(b.n for b in buses)
    out = [0.0] * n
    for b in buses:
        for i, s in enumerate(b.buf):
            out[i] += s
    # 软限幅（tanh 让过冲变"暖"而不是爆）
    out = [math.tanh(s * 1.1) for s in out]
    m = max(1e-6, max(abs(s) for s in out))
    k = peak / m
    return [s * k for s in out]


# ============================================================
# 鼓组合成
# ============================================================

def drum_kick(gain=0.9):
    return osc(45, 0.16, "sine", gain=gain, attack=0.002, release=0.12, glide_to=38)


def drum_snare(gain=0.5, seed=5):
    return mix_t([osc(190, 0.09, "tri", gain=gain * 0.5, attack=0.001, release=0.06),
                  noise(0.11, gain=gain, lp=0.55, decay=2.2, seed=seed)])


def drum_hat(gain=0.16, seed=11):
    return noise(0.045, gain=gain, lp=0.85, decay=3.0, seed=seed)


def mix_t(tracks):
    n = max(len(t) for t in tracks)
    out = [0.0] * n
    for t in tracks:
        for i, s in enumerate(t):
            out[i] += s
    return out


# ============================================================
# 音序器：把 (beat, midi, dur_beat) 事件铺进 Bus
# ============================================================

def lay(bus, events, beat_sec, wave_type, gain, duty=0.5, vib=0.0, attack=0.01):
    for start_b, midi, dur_b in events:
        bus.add(start_b * beat_sec,
                osc(midi, dur_b * beat_sec * 0.98, wave_type,
                    duty=duty, gain=gain, attack=attack, release=0.05, vib=vib))


def lay_drums(bus, bars, beat_sec, pattern="battle"):
    """pattern: village=轻 kick+hat / battle=全套 / boss=加重"""
    for bar in range(bars):
        t0 = bar * 4 * beat_sec
        if pattern == "village":
            bus.add(t0, drum_kick(0.4))
            for e8 in range(8):
                bus.add(t0 + e8 * beat_sec / 2, drum_hat(0.10, seed=bar * 8 + e8))
        else:
            for beat in range(4):
                bus.add(t0 + beat * beat_sec, drum_kick(0.8))
                if beat % 2 == 1:
                    bus.add(t0 + beat * beat_sec, drum_snare(0.42, seed=bar * 4 + beat))
            div = 2 if pattern == "battle" else 4          # boss 用 16 分镲
            g = 0.13 if pattern == "battle" else 0.10
            for e in range(4 * div):
                bus.add(t0 + e * beat_sec / div, drum_hat(g, seed=bar * 16 + e))


# ============================================================
# 三首曲子
# ============================================================

def bgm_village():
    """村庄：卡农进行 C-G-Am-F， triangle 主旋律，温柔循环。96 BPM, 8 小节。"""
    bpm, bars = 96, 8
    beat = 60.0 / bpm
    total = bars * 4 * beat
    lead, arp, bass, drums = Bus(total), Bus(total), Bus(total), Bus(total)

    # 和弦（每小节一个）：C G Am F ×2
    prog = [(72, 76, 79), (67, 71, 74), (69, 72, 76), (65, 69, 72)] * 2
    roots = [48, 43, 45, 41] * 2

    # 钩子旋律：每 4 小节一句，第二遍尾音变化（洗脑但防腻）
    hook = [
        (0.0, 76, .5), (.5, 79, .5), (1.0, 84, 1.0), (2.0, 83, .5), (2.5, 79, .5), (3.0, 81, 1.0),
        (4.0, 74, .5), (4.5, 79, .5), (5.0, 83, 1.0), (6.0, 81, .5), (6.5, 77, .5), (7.0, 79, 1.0),
        (8.0, 72, .5), (8.5, 76, .5), (9.0, 81, 1.0), (10.0, 79, .5), (10.5, 76, .5), (11.0, 72, 1.0),
        (12.0, 69, .5), (12.5, 72, .5), (13.0, 77, 1.0), (14.0, 79, .5), (14.5, 81, .5), (15.0, 83, 1.0),
        # 应答句（高走后回落，解决到主音）
        (16.0, 84, .75), (16.75, 83, .25), (17.0, 81, .5), (17.5, 79, .5), (18.0, 76, 2.0),
        (20.0, 79, .75), (20.75, 81, .25), (21.0, 79, .5), (21.5, 74, .5), (22.0, 79, 2.0),
        (24.0, 81, .75), (24.75, 79, .25), (25.0, 76, .5), (25.5, 72, .5), (26.0, 76, 2.0),
        (28.0, 74, .5), (28.5, 76, .5), (29.0, 77, .5), (29.5, 79, .5), (30.0, 72, 2.0),
    ]
    lay(lead, hook, beat, "tri", 0.30, vib=1.0, attack=0.015)

    # 琶音：16 分碎和弦（芯片乐的灵魂铺底）
    for bar_i, chord in enumerate(prog):
        seq = [chord[0] - 12, chord[1] - 12, chord[2] - 12, chord[1] - 12] * 2
        for k, m in enumerate(seq):
            arp.add((bar_i * 4 + k * 0.25) * beat,
                    osc(m, beat * 0.22, "square", duty=0.35, gain=0.085,
                        attack=0.004, release=0.03))
    # 贝斯：根音+五度，1、3 拍
    for bar_i, r in enumerate(roots):
        bass.add(bar_i * 4 * beat, osc(r, beat * 1.6, "tri", gain=0.30, attack=0.008))
        bass.add((bar_i * 4 + 2) * beat, osc(r + 7, beat * 1.6, "tri", gain=0.24, attack=0.008))

    lay_drums(drums, bars, beat, "village")
    lead.echo(beat * 0.75, fb=0.30, mix_gain=0.5)   # 附点延迟 = 空间感
    return master_mix([lead, arp, bass, drums])


def bgm_battle():
    """普通战斗：Am-F-C-G，推进感八度贝斯 + 切分钩子。140 BPM, 8 小节。"""
    bpm, bars = 140, 8
    beat = 60.0 / bpm
    total = bars * 4 * beat
    lead, arp, bass, drums = Bus(total), Bus(total), Bus(total), Bus(total)

    prog = [(69, 72, 76), (65, 69, 72), (67, 72, 76), (67, 71, 74)] * 2  # Am F C G
    roots = [45, 41, 48, 43] * 2

    # 钩子：切分节奏 + 级进下行应答（战斗的"喊话感"）
    hook = [
        (0.0, 69, .75), (.75, 72, .25), (1.0, 76, .5), (1.5, 74, .25), (1.75, 72, .25), (2.0, 74, 1.5),
        (4.0, 77, .75), (4.75, 76, .25), (5.0, 72, .5), (5.5, 69, .5), (6.0, 72, 1.5),
        (8.0, 67, .75), (8.75, 72, .25), (9.0, 76, .5), (9.5, 79, .5), (10.0, 76, 1.5),
        (12.0, 74, .5), (12.5, 71, .5), (13.0, 67, .5), (13.5, 71, .5), (14.0, 74, 1.5),
        # 应答：上行冲刺后急停
        (16.0, 76, .5), (16.5, 77, .5), (17.0, 76, .5), (17.5, 74, .5), (18.0, 72, 1.0), (19.0, 69, 1.0),
        (20.0, 77, .5), (20.5, 76, .5), (21.0, 74, .5), (21.5, 72, .5), (22.0, 69, 2.0),
        (24.0, 76, .5), (24.5, 79, .5), (25.0, 76, .5), (25.5, 74, .5), (26.0, 72, 1.0), (27.0, 67, 1.0),
        (28.0, 69, .75), (28.75, 71, .25), (29.0, 72, .5), (29.5, 74, .5), (30.0, 76, 2.0),
    ]
    lay(lead, hook, beat, "square", 0.16, duty=0.35, attack=0.005)
    lead.echo(beat * 0.75, fb=0.28, mix_gain=0.45)

    # 琶音 16 分
    for bar_i, chord in enumerate(prog):
        seq = [chord[0], chord[1] + 12, chord[2], chord[1] + 12] * 4
        for k, m in enumerate(seq):
            arp.add((bar_i * 4 + k * 0.25) * beat,
                    osc(m, beat * 0.20, "square", duty=0.25, gain=0.065,
                        attack=0.003, release=0.025))
    # 贝斯：八度跳动（推进感的来源）
    for bar_i, r in enumerate(roots):
        for k in range(8):
            m = r if k % 2 == 0 else r + 12
            bass.add((bar_i * 4 + k * 0.5) * beat,
                     osc(m, beat * 0.42, "tri", gain=0.30, attack=0.004, release=0.03))

    lay_drums(drums, bars, beat, "battle")
    return master_mix([lead, arp, bass, drums])


def bgm_boss():
    """Boss：Dm-Bb-Gm-A，低音 ostinato + 戏剧性长句。126 BPM, 8 小节。"""
    bpm, bars = 126, 8
    beat = 60.0 / bpm
    total = bars * 4 * beat
    lead, arp, bass, drums = Bus(total), Bus(total), Bus(total), Bus(total)

    prog = [(62, 65, 69), (58, 62, 65), (55, 58, 62), (57, 61, 64)] * 2  # Dm Bb Gm A
    roots = [38, 34, 31, 33] * 2

    # 钩子：长音 + 半音下行叹息（父王的悲怆感），每句落在和弦外音再解决
    hook = [
        (0.0, 74, 1.5), (1.5, 77, .5), (2.0, 76, 1.0), (3.0, 74, 1.0),
        (4.0, 70, 1.5), (5.5, 74, .5), (6.0, 72, 2.0),
        (8.0, 70, 1.5), (9.5, 67, .5), (10.0, 65, 1.0), (11.0, 62, 1.0),
        (12.0, 61, 1.5), (13.5, 64, .5), (14.0, 69, 2.0),
        # 应答：高八度宣示
        (16.0, 86, 1.5), (17.5, 84, .5), (18.0, 82, 2.0),
        (20.0, 81, 1.5), (21.5, 77, .5), (22.0, 74, 2.0),
        (24.0, 82, 1.0), (25.0, 81, 1.0), (26.0, 77, 1.0), (27.0, 74, 1.0),
        (28.0, 76, .5), (28.5, 74, .5), (29.0, 73, .5), (29.5, 74, .5), (30.0, 74, 2.0),
    ]
    lay(lead, hook, beat, "square", 0.15, duty=0.5, vib=1.2, attack=0.02)
    lead.echo(beat * 0.75, fb=0.34, mix_gain=0.5)

    # 琶音：低八度暗流
    for bar_i, chord in enumerate(prog):
        seq = [chord[0] - 12, chord[1] - 12, chord[2] - 12, chord[1] - 12] * 4
        for k, m in enumerate(seq):
            arp.add((bar_i * 4 + k * 0.25) * beat,
                    osc(m, beat * 0.18, "square", duty=0.3, gain=0.055,
                        attack=0.003, release=0.02))
    # 贝斯：16 分 ostinato（根-八度交替，压迫感）
    for bar_i, r in enumerate(roots):
        for k in range(16):
            m = r if k % 4 != 2 else r + 12
            bass.add((bar_i * 4 + k * 0.25) * beat,
                     osc(m, beat * 0.20, "tri", gain=0.28, attack=0.003, release=0.025))

    lay_drums(drums, bars, beat, "boss")
    return master_mix([lead, arp, bass, drums])


BGM = {
    "bgm_battle": bgm_battle,
    "bgm_boss": bgm_boss,
    "bgm_village": bgm_village,
}


# ============================================================
# SFX（沿用 v1：手感音已经过验证，不动）
# ============================================================

def tone(freq, dur, wave_type="sine", gain=0.5, attack=0.004, release=0.05, freq_end=None):
    n = int(SR * dur)
    out = []
    phase = 0.0
    for i in range(n):
        f = freq if freq_end is None else freq + (freq_end - freq) * (i / n)
        phase += 2.0 * math.pi * f / SR
        u = (phase / (2 * math.pi)) % 1.0
        if wave_type == "sine":
            v = math.sin(phase)
        elif wave_type == "square":
            v = 1.0 if u < 0.5 else -1.0
        else:
            v = 2.0 * abs(2.0 * u - 1.0) - 1.0
        t = i / n
        if t * dur < attack:
            e = (t * dur) / attack
        elif t > 1.0 - release / dur:
            e = max(0.0, (1.0 - t) * dur / release)
        else:
            e = 1.0
        out.append(v * gain * e)
    return out


def sfx_perfect_defend():
    a = mix_t([tone(1250, 0.16, "sine", 0.5), tone(1875, 0.12, "sine", 0.25),
               tone(625, 0.2, "tri", 0.2)])
    return concat(a, silence(0.22), [s * 0.25 for s in a])


def sfx_normal_defend():
    return mix_t([tone(160, 0.16, "tri", 0.5), noise(0.1, 0.2, lp=0.08)])


def sfx_dodge():
    n = int(SR * 0.22)
    rnd = random.Random(11)
    out = []
    y = 0.0
    for i in range(n):
        t = i / n
        x = rnd.uniform(-1, 1)
        y += 0.5 * (x - y)
        carrier = math.sin(2 * math.pi * (400 + 2000 * t * t) * (i / SR))
        out.append(y * carrier * 0.5 * (1 - t))
    return out


def sfx_dodge_fail():
    return mix_t([tone(90, 0.35, "sine", 0.6, freq_end=55), noise(0.08, 0.35, lp=0.3)])


def sfx_crit():
    return concat(tone(2200, 0.06, "square", 0.3), noise(0.12, 0.5, lp=0.5))


def sfx_hit():
    return mix_t([tone(220, 0.12, "tri", 0.5, freq_end=140), noise(0.07, 0.3, lp=0.4)])


def sfx_faint():
    return tone(300, 0.4, "tri", 0.4, freq_end=110)


def sfx_heal():
    return concat(tone(520, 0.09, "sine", 0.3), tone(660, 0.09, "sine", 0.3),
                  tone(880, 0.16, "sine", 0.3))


def sfx_heartbeat():
    thump = osc(45, 0.12, "sine", gain=0.7, attack=0.002, release=0.09, glide_to=38)
    # 总长 1.1 秒可循环：咚 0.12 + 间歇 0.18 + 咚 0.12 + 尾间 0.68
    return concat(thump, silence(0.18), [s * 0.8 for s in thump], silence(0.68))


def sfx_card_flip():
    return mix_t([tone(900, 0.05, "square", 0.12), noise(0.04, 0.2, lp=0.6)])


def sfx_card_stomp():
    return concat(noise(0.14, 0.5, lp=0.15), tone(70, 0.18, "sine", 0.5, freq_end=45))


def sfx_ui_click():
    return tone(1250, 0.04, "square", 0.1)


SFX = {
    "se_perfect_defend": sfx_perfect_defend,
    "se_normal_defend": sfx_normal_defend,
    "se_dodge": sfx_dodge,
    "se_dodge_fail": sfx_dodge_fail,
    "se_crit": sfx_crit,
    "se_hit": sfx_hit,
    "se_faint": sfx_faint,
    "se_heal": sfx_heal,
    "se_heartbeat": sfx_heartbeat,
    "se_card_flip": sfx_card_flip,
    "se_card_stomp": sfx_card_stomp,
    "se_ui_click": sfx_ui_click,
}


def main():
    os.makedirs(OUT_SFX, exist_ok=True)
    os.makedirs(OUT_BGM, exist_ok=True)
    for name, fn in SFX.items():
        write_wav(os.path.join(OUT_SFX, name + ".wav"), fn())
        print("SFX  ->", name)
    for name, fn in BGM.items():
        wav_path = os.path.join(OUT_BGM, name + ".wav")
        print("BGM  合成中…", name)
        write_wav(wav_path, fn())
        ogg_path = os.path.join(OUT_BGM, name + ".ogg")
        try:
            subprocess.run(
                ["ffmpeg", "-y", "-loglevel", "error", "-i", wav_path,
                 "-c:a", "libvorbis", "-q:a", "4", ogg_path],
                check=True,
            )
            os.remove(wav_path)
            print("BGM  ->", name + ".ogg")
        except Exception as e:
            print("BGM  ->", name + ".wav（ffmpeg 转码失败：%s）" % e)
    print("音频生成完毕。")


if __name__ == "__main__":
    main()
