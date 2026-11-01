#!/usr/bin/env python3
"""Convert executor attachment dumps named ...-fmtF-WxH-sSTRIDE.raw (F = VkFormat) to PNG.

Usage: raw2png.py FILE...
Colour formats are written as-is (alpha dropped); one/two-channel and float formats are
normalised to their min..max range so distance fields and masks are visible.
"""
import re
import sys

import numpy as np
from PIL import Image

# VkFormat -> (numpy dtype, channels, order)
FORMATS = {
    9: (np.uint8, 1, "R"),          # R8_UNORM
    16: (np.uint8, 2, "RG"),        # R8G8_UNORM
    37: (np.uint8, 4, "RGBA"),      # R8G8B8A8_UNORM
    43: (np.uint8, 4, "RGBA"),      # R8G8B8A8_SRGB
    44: (np.uint8, 4, "BGRA"),      # B8G8R8A8_UNORM
    50: (np.uint8, 4, "BGRA"),      # B8G8R8A8_SRGB
    76: (np.float16, 1, "R"),       # R16_SFLOAT
    83: (np.float16, 2, "RG"),      # R16G16_SFLOAT
    97: (np.float16, 4, "RGBA"),    # R16G16B16A16_SFLOAT
    100: (np.float32, 1, "R"),      # R32_SFLOAT
    103: (np.float32, 2, "RG"),     # R32G32_SFLOAT
    109: (np.float32, 4, "RGBA"),   # R32G32B32A32_SFLOAT
}


def convert(path):
    m = re.search(r"-fmt(\d+)-(\d+)x(\d+)-s(\d+)\.raw$", path)
    if not m:
        print(f"{path}: name does not encode format/size")
        return
    fmt, w, h, stride = (int(x) for x in m.groups())
    raw = np.frombuffer(open(path, "rb").read(), dtype=np.uint8)
    if fmt in (58, 64):     # A2R10G10B10 / A2B10G10R10 UNORM_PACK32
        v = raw[:stride * h].reshape(h, stride)[:, :w * 4].copy().view(np.uint32)
        c = [(v >> s_) & 0x3ff for s_ in (20, 10, 0)]
        rgb = np.stack(c if fmt == 58 else c[::-1], axis=2).astype(np.float32) / 4
        out = path[:-4] + ".png"
        Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8)).save(out)
        print(out)
        return
    if fmt not in FORMATS:
        print(f"{path}: VkFormat {fmt} not handled")
        return
    dt, ch, order = FORMATS[fmt]
    rows = raw[:stride * h].reshape(h, stride)
    px = rows[:, :w * ch * np.dtype(dt).itemsize].copy().view(dt).reshape(h, w, ch)
    px = px.astype(np.float32)
    if dt != np.uint8 or ch < 3:
        lo, hi = float(np.nanmin(px)), float(np.nanmax(px))
        print(f"{path}: range {lo:.4g}..{hi:.4g}")
        px = (px - lo) / (hi - lo) * 255 if hi > lo else px * 0
    if order == "BGRA":
        px = px[:, :, [2, 1, 0]]
    elif ch >= 3:
        px = px[:, :, :3]
    elif ch == 2:
        px = np.concatenate([px, np.zeros((h, w, 1), np.float32)], axis=2)
    else:
        px = px[:, :, 0]
    out = path[:-4] + ".png"
    Image.fromarray(np.clip(px, 0, 255).astype(np.uint8)).save(out)
    print(out)


for p in sys.argv[1:]:
    convert(p)
