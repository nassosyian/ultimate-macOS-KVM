#!/usr/bin/env python3
"""Convert raw BGRA dumps named ...-WxH-sSTRIDE.bgra to PNG. Usage: bgra2png.py FILE..."""
import re
import struct
import sys
import zlib

for path in sys.argv[1:]:
    m = re.search(r"-(\d+)x(\d+)-s(\d+)\.bgra$", path)
    w, h, stride = map(int, m.groups())
    d = open(path, "rb").read()
    rows = b"".join(b"\0" + bytes(c for i in range(0, w * 4, 4) for c in (d[y * stride + i + 2],
                    d[y * stride + i + 1], d[y * stride + i])) for y in range(h))
    def chunk(t, b): return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b))
    open(path[:-5] + ".png", "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                                         + chunk(b"IDAT", zlib.compress(rows, 6)) + chunk(b"IEND", b""))
