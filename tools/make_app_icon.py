"""Renders App/Assets.xcassets/AppIcon.appiconset/AppIcon.png: an 8-point sparkle on a night sky."""
import struct
import zlib
from pathlib import Path

import numpy as np

SIZE, SS = 1024, 2
N = SIZE * SS
OUT = Path(__file__).resolve().parent.parent / "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"


def hex_rgb(h):
    return np.array([int(h[i:i + 2], 16) / 255 for i in (1, 3, 5)])


def astroid(x, y, r, p=0.42):
    return (np.abs(x) ** p + np.abs(y) ** p) ** (1 / p) / r


y, x = np.mgrid[0:N, 0:N]
x = (x + 0.5) / N * 2 - 1
y = (y + 0.5) / N * 2 - 1

d = np.hypot(x, y)
img = hex_rgb("#0B1640") * (1 - np.clip(d / 1.3, 0, 1))[..., None] + hex_rgb("#020B1B") * np.clip(d / 1.3, 0, 1)[..., None]

rng = np.random.default_rng(7)
for _ in range(45):
    sx, sy = rng.uniform(-0.95, 0.95, 2)
    if np.hypot(sx, sy) < 0.75:
        continue
    rad, bright = rng.uniform(0.003, 0.007), rng.uniform(0.35, 0.8)
    img += (bright * np.exp(-((x - sx) ** 2 + (y - sy) ** 2) / rad ** 2))[..., None]

c45 = np.sqrt(0.5)
xr, yr = (x + y) * c45, (y - x) * c45
f = np.minimum(astroid(x, y, 0.66), astroid(xr, yr, 0.38))
star = np.clip((1 - f) * 60, 0, 1)

t = np.clip((x + y) / 1.3 + 0.5, 0, 1)[..., None]
stops = [hex_rgb("#4F8BFF"), hex_rgb("#9B72F2"), hex_rgb("#D96BA0")]
grad = np.where(t < 0.5, stops[0] + (stops[1] - stops[0]) * (t / 0.5), stops[1] + (stops[2] - stops[1]) * ((t - 0.5) / 0.5))
core = np.exp(-(d / 0.12) ** 2)[..., None]
fill = grad * (1 - 0.55 * core) + np.array([1.0, 1.0, 1.0]) * 0.55 * core

glow = np.exp(-np.clip(f - 1, 0, None) * 3.0)[..., None] * 0.6
img = img + grad * glow
img = img * (1 - star[..., None]) + fill * star[..., None]

img = np.clip(img, 0, 1).reshape(SIZE, SS, SIZE, SS, 3).mean(axis=(1, 3))
px = (img * 255 + 0.5).astype(np.uint8)

raw = b"".join(b"\x00" + row.tobytes() for row in px)


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
print(OUT)
