"""Generates alarm.wav (ringtone) and AppIcon.png for the AlarmClock project.

Run on the CI runner before building:  python3 scripts/make_assets.py
Paths are resolved relative to this script's location, so it works locally and on CI.
"""

import math
import os
import struct
import wave

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_DIR = os.path.join(REPO_ROOT, "AlarmClock")
ICON_DIR = os.path.join(APP_DIR, "Assets.xcassets", "AppIcon.appiconset")

os.makedirs(ICON_DIR, exist_ok=True)

# ---------------------------------------------------------------- alarm sound
SR = 44100
DURATION = 29.0
n = int(SR * DURATION)
signal = np.zeros(n, dtype=np.float64)

fade = int(SR * 0.008)


def beep(start, length, freq, amp=0.42):
    count = int(SR * length)
    t = np.arange(count) / SR
    wave_data = amp * np.sin(2 * math.pi * freq * t)
    wave_data += 0.25 * amp * np.sin(2 * math.pi * freq * 2 * t)
    env = np.ones(count)
    f = min(fade, count // 2)
    env[:f] = np.linspace(0, 1, f)
    env[-f:] = np.linspace(1, 0, f)
    begin = int(start * SR)
    if begin >= n:
        return
    end = min(begin + count, n)
    signal[begin:end] += (wave_data * env)[: end - begin]


period = 1.8
t0 = 0.0
while t0 < DURATION:
    beep(t0, 0.14, 1180)
    beep(t0 + 0.23, 0.14, 1180)
    beep(t0 + 0.46, 0.14, 880)
    t0 += period

signal = np.clip(signal, -1, 1)
pcm = (signal * 32767).astype(np.int16)
with wave.open(os.path.join(APP_DIR, "alarm.wav"), "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes(pcm.tobytes())

# ---------------------------------------------------------------- app icon
S = 2048
px = np.zeros((S, S, 3), dtype=np.float64)

yy = np.linspace(0, 1, S)[:, None]
for i in range(3):
    top = [26, 26, 34][i]
    bottom = [7, 7, 9][i]
    px[:, :, i] = top + (bottom - top) * yy

cy, cx = S * 0.54, S * 0.5
Y, X = np.mgrid[0:S, 0:S]
dist = np.sqrt((X - cx) ** 2 + (Y - cy) ** 2) / (S * 0.55)
glow = np.clip(1 - dist, 0, 1) ** 2
for i, c in enumerate([255, 110, 40]):
    px[:, :, i] += glow * c * 0.18

img = Image.fromarray(np.clip(px, 0, 255).astype(np.uint8)).convert("RGBA")
draw = ImageDraw.Draw(img)

r = S * 0.285
ring_w = S * 0.062
bbox = [cx - r, cy - r, cx + r, cy + r]
draw.ellipse(bbox, outline=(255, 138, 56, 255), width=int(ring_w))
draw.ellipse(
    [cx - r + ring_w * 0.62, cy - r + ring_w * 0.62,
     cx + r - ring_w * 0.62, cy + r - ring_w * 0.62],
    outline=(255, 196, 130, 90), width=int(ring_w * 0.18),
)

for sign in (-1, 1):
    bx = cx + sign * S * 0.165
    by = cy - r * 0.72
    br = S * 0.085
    draw.ellipse([bx - br, by - br, bx + br, by + br], fill=(255, 138, 56, 255))

draw.line([cx, cy, cx, cy - r * 0.60], fill=(255, 255, 255, 255), width=int(S * 0.028))
draw.line([cx, cy, cx + r * 0.44, cy + r * 0.20], fill=(255, 255, 255, 255), width=int(S * 0.028))
dot = S * 0.042
draw.ellipse([cx - dot, cy - dot, cx + dot, cy + dot], fill=(255, 255, 255, 255))

img = img.filter(ImageFilter.GaussianBlur(0.6))
icon = img.convert("RGB").resize((1024, 1024), Image.LANCZOS)
icon.save(os.path.join(ICON_DIR, "AppIcon.png"), "PNG")

print("wav", os.path.getsize(os.path.join(APP_DIR, "alarm.wav")), "bytes")
print("icon ok")
