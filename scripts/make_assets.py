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

# ---------------------------------------------------------------- app icon
# Pure-python PNG writer with soft-edged geometry (no PIL needed).
S = 1024
CX, CY = S * 0.5, S * 0.54
R = S * 0.285          # clock face radius
RING_W = S * 0.062     # ring thickness
BELL_R = S * 0.085
HAND_W = S * 0.028
DOT_R = S * 0.042

TOP = (26, 26, 34)
BOTTOM = (7, 7, 9)
ORANGE = (255, 138, 56)
HILITE = (255, 196, 130)
WHITE = (255, 255, 255)
GLOW_RGB = (255, 110, 40)


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
    dy2 = (y - CY) ** 2
    dyg2 = (y - CY) ** 2
    for x in range(S):
        # background gradient
        r = TOP[0] + (BOTTOM[0] - TOP[0]) * t
        g = TOP[1] + (BOTTOM[1] - TOP[1]) * t
        b = TOP[2] + (BOTTOM[2] - TOP[2]) * t

        # warm glow behind the clock
        dist = math.sqrt((x - CX) ** 2 + dyg2) / (S * 0.55)
        glow = clamp01(1.0 - dist) ** 2 * 0.18
        r += GLOW_RGB[0] * glow
        g += GLOW_RGB[1] * glow
        b += GLOW_RGB[2] * glow

        # clock ring (soft edge)
        dc = math.sqrt((x - CX) ** 2 + dy2)
        half = RING_W / 2
        a = clamp01(half + 0.5 - abs(dc - R))
        if a > 0:
            r = r * (1 - a) + ORANGE[0] * a
            g = g * (1 - a) + ORANGE[1] * a
            b = b * (1 - a) + ORANGE[2] * a

        # inner highlight ring
        a2 = clamp01(RING_W * 0.09 + 0.5 - abs(dc - (R - RING_W * 0.62)))
        if a2 > 0:
            alpha = a2 * (90 / 255)
            r = r * (1 - alpha) + HILITE[0] * alpha
            g = g * (1 - alpha) + HILITE[1] * alpha
            b = b * (1 - alpha) + HILITE[2] * alpha

        # bells on top
        for sign in (-1, 1):
            bx = CX + sign * S * 0.165
            by = CY - R * 0.72
            ab = clamp01(BELL_R + 0.5 - math.sqrt((x - bx) ** 2 + (y - by) ** 2))
            if ab > 0:
                r = r * (1 - ab) + ORANGE[0] * ab
                g = g * (1 - ab) + ORANGE[1] * ab
                b = b * (1 - ab) + ORANGE[2] * ab

        # hands and center dot
        ah = clamp01(HAND_W / 2 + 0.5 - seg_dist(x, y, CX, CY, CX, CY - R * 0.60))
        ah = max(ah, clamp01(HAND_W / 2 + 0.5 - seg_dist(x, y, CX, CY, CX + R * 0.44, CY + R * 0.20)))
        ah = max(ah, clamp01(DOT_R + 0.5 - math.sqrt((x - CX) ** 2 + (y - CY) ** 2)))
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
