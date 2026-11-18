"""Generates alarm.wav (ringtone) and AppIcon.png for the AlarmClock project.

Pure Python standard library only (no pip dependencies), so it runs anywhere:
    python3 scripts/make_assets.py
Paths are resolved relative to this script's location.
"""

import math
import os
import struct
import wave
import zlib

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_DIR = os.path.join(REPO_ROOT, "AlarmClock")
ICON_DIR = os.path.join(APP_DIR, "Assets.xcassets", "AppIcon.appiconset")

os.makedirs(ICON_DIR, exist_ok=True)

# ---------------------------------------------------------------- alarm sound
SR = 44100
DURATION = 29.0
TOTAL = int(SR * DURATION)
samples = [0.0] * TOTAL
fade = int(SR * 0.008)


def beep(start, length, freq, amp=0.42):
    count = int(SR * length)
    begin = int(start * SR)
    if begin >= TOTAL:
        return
    end = min(begin + count, TOTAL)
    f = min(fade, (end - begin) // 2)
    for i in range(begin, end):
        k = i - begin
        w = amp * math.sin(2 * math.pi * freq * k / SR)
        w += 0.25 * amp * math.sin(4 * math.pi * freq * k / SR)
        if k < f:
            env = k / f
        elif end - i <= f:
            env = (end - i) / f
        else:
            env = 1.0
        samples[i] += w * env


t0 = 0.0
while t0 < DURATION:
    beep(t0, 0.14, 1180)
    beep(t0 + 0.23, 0.14, 1180)
    beep(t0 + 0.46, 0.14, 880)
    t0 += 1.8

pcm = bytearray()
for s in samples:
    v = max(-1.0, min(1.0, s))
    pcm += struct.pack("<h", int(v * 32767))

with wave.open(os.path.join(APP_DIR, "alarm.wav"), "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes(bytes(pcm))

print("wav", os.path.getsize(os.path.join(APP_DIR, "alarm.wav")), "bytes")

# ------------------------------------------------ notification chime (3 notes)
# 通知提示音：三音上行（C5-E5-G5），柔和衰减，每 3.6 秒一轮、共 6 轮，约 21.6 秒，
# 音量逐轮小幅递增，仍在 iOS 通知音 30 秒上限内。
CHIME_SR = 44100
CHIME_DUR = 6 * 3.6
CHIME_N = int(CHIME_SR * CHIME_DUR)
chime = [0.0] * CHIME_N


def chime_note(start, freq, length, amp):
    begin = int(start * CHIME_SR)
    count = int(length * CHIME_SR)
    attack = int(0.02 * CHIME_SR)
    for i in range(count):
        idx = begin + i
        if idx >= CHIME_N:
            break
        t = i / CHIME_SR
        env = i / attack if i < attack else math.exp(-3.0 * (t - 0.02))
        w = math.sin(2 * math.pi * freq * t)
        w += 0.22 * math.sin(4 * math.pi * freq * t)
        w += 0.06 * math.sin(6 * math.pi * freq * t)
        chime[idx] += amp * env * w


MOTIF = [(0.00, 523.25, 0.34), (0.18, 659.25, 0.32), (0.36, 783.99, 0.28)]  # C5 E5 G5
for r in range(6):
    base = r * 3.6
    gain = 0.62 + 0.076 * r          # 0.62 → 1.0，逐轮加深存在感
    for off, freq, amp in MOTIF:
        chime_note(base + off, freq, 1.6, amp * gain)

peak = max(abs(v) for v in chime) or 1.0
chime_pcm = bytearray()
for v in chime:
    chime_pcm += struct.pack("<h", int(max(-1.0, min(1.0, v / peak * 0.82)) * 32767))

with wave.open(os.path.join(APP_DIR, "chime.wav"), "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(CHIME_SR)
    w.writeframes(bytes(chime_pcm))

print("chime", os.path.getsize(os.path.join(APP_DIR, "chime.wav")), "bytes")

# ---------------------------------------------------------------- app icon
# Pure-python PNG writer: pill capsule + medical cross badge on dark bg.
S = 1024
CX, CY = S * 0.47, S * 0.47
PILL_HALF = S * 0.30      # capsule half-length along its axis
PILL_R = S * 0.165        # capsule radius
BADGE_X, BADGE_Y, BADGE_R = S * 0.78, S * 0.80, S * 0.135
CROSS_W = S * 0.048
CROSS_L = S * 0.125

TOP = (26, 26, 34)
BOTTOM = (7, 7, 9)
ORANGE = (255, 138, 56)
ORANGE_D = (224, 106, 28)
WHITE = (255, 255, 255)
GLOW_RGB = (255, 110, 40)

# capsule axis tilted 35 degrees (upper-right to lower-left)
ANG = math.radians(-35)
AX, AY = math.cos(ANG), math.sin(ANG)
A = (CX - PILL_HALF * AX, CY - PILL_HALF * AY)
B = (CX + PILL_HALF * AX, CY + PILL_HALF * AY)
MID = ((A[0] + B[0]) / 2.0, (A[1] + B[1]) / 2.0)


def seg_dist(px, py, ax, ay, bx, by):
    vx, vy = bx - ax, by - ay
    wx, wy = px - ax, py - ay
    t = max(0.0, min(1.0, (wx * vx + wy * vy) / (vx * vx + vy * vy)))
    dx, dy = wx - t * vx, wy - t * vy
    return math.sqrt(dx * dx + dy * dy)


def clamp01(v):
    return 0.0 if v < 0.0 else (1.0 if v > 1.0 else v)


rows = []
for y in range(S):
    t = y / (S - 1)
    row = bytearray([0])  # PNG filter type 0
    dyg2 = (y - CY) ** 2
    for x in range(S):
        # background gradient
        r = TOP[0] + (BOTTOM[0] - TOP[0]) * t
        g = TOP[1] + (BOTTOM[1] - TOP[1]) * t
        b = TOP[2] + (BOTTOM[2] - TOP[2]) * t

        # warm glow
        dist = math.sqrt((x - CX) ** 2 + dyg2) / (S * 0.58)
        glow = clamp01(1.0 - dist) ** 2 * 0.18
        r += GLOW_RGB[0] * glow
        g += GLOW_RGB[1] * glow
        b += GLOW_RGB[2] * glow

        # pill capsule, split along its axis: orange half / white half
        d = seg_dist(x, y, A[0], A[1], B[0], B[1])
        a = clamp01(PILL_R + 0.5 - d)
        if a > 0:
            along = (x - MID[0]) * AX + (y - MID[1]) * AY
            if along >= 0:
                base = WHITE
            else:
                # subtle shading on the orange half for depth
                shade = clamp01(0.5 + along / (PILL_HALF * 2.0) * 0.35 + 0.15)
                base = (
                    ORANGE_D[0] + (ORANGE[0] - ORANGE_D[0]) * shade,
                    ORANGE_D[1] + (ORANGE[1] - ORANGE_D[1]) * shade,
                    ORANGE_D[2] + (ORANGE[2] - ORANGE_D[2]) * shade,
                )
            r = r * (1 - a) + base[0] * a
            g = g * (1 - a) + base[1] * a
            b = b * (1 - a) + base[2] * a

        # medical cross badge (bottom-right, on top)
        ab = clamp01(BADGE_R + 0.5 - math.sqrt((x - BADGE_X) ** 2 + (y - BADGE_Y) ** 2))
        if ab > 0:
            r = r * (1 - ab) + ORANGE[0] * ab
            g = g * (1 - ab) + ORANGE[1] * ab
            b = b * (1 - ab) + ORANGE[2] * ab
            ah = max(
                clamp01(CROSS_W / 2 + 0.5 - seg_dist(
                    x, y,
                    BADGE_X - CROSS_L / 2, BADGE_Y,
                    BADGE_X + CROSS_L / 2, BADGE_Y)),
                clamp01(CROSS_W / 2 + 0.5 - seg_dist(
                    x, y,
                    BADGE_X, BADGE_Y - CROSS_L / 2,
                    BADGE_X, BADGE_Y + CROSS_L / 2)),
            )
            if ah > 0:
                r = r * (1 - ah) + WHITE[0] * ah
                g = g * (1 - ah) + WHITE[1] * ah
                b = b * (1 - ah) + WHITE[2] * ah

        row += bytes((int(r) & 0xFF, int(g) & 0xFF, int(b) & 0xFF))
    rows.append(bytes(row))


def png_chunk(tag, data):
    payload = tag + data
    return struct.pack(">I", len(data)) + payload + struct.pack(">I", zlib.crc32(payload) & 0xFFFFFFFF)


png = b"\x89PNG\r\n\x1a\n"
png += png_chunk(b"IHDR", struct.pack(">IIBBBBB", S, S, 8, 2, 0, 0, 0))
png += png_chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
png += png_chunk(b"IEND", b"")

with open(os.path.join(ICON_DIR, "AppIcon.png"), "wb") as f:
    f.write(png)

print("icon", os.path.getsize(os.path.join(ICON_DIR, "AppIcon.png")), "bytes")
print("done")
