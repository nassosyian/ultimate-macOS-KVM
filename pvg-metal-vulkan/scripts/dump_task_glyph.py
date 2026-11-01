#!/usr/bin/env python3
"""Independently verify PVG task translation: walk a task's page tables via QEMU's monitor
(pmemsave) and render a BGRA cursor glyph to PNG.
Usage: dump_task_glyph.py TASK_ROOT_PFN VA WIDTH HEIGHT STRIDE OUT.png"""
import os
import struct
import subprocess
import sys
import tempfile
import zlib

MON = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vm-monitor.sh")
tmp = tempfile.mkdtemp()


def phys(addr, n):
    f = os.path.join(tmp, "m.bin")
    subprocess.run([MON, f'pmemsave {addr:#x} {n:#x} "{f}"'], capture_output=True)
    return open(f, "rb").read()


def translate(root_pfn, va):
    pt_root, depth = struct.unpack("<II", phys(root_pfn << 12, 8))
    table, vpn = pt_root, va >> 12
    for level in range(depth - 1, -1, -1):
        idx = (vpn >> (10 * level)) & 0x3FF
        table = struct.unpack("<I", phys((table << 12) + idx * 4, 4))[0] & 0x7FFFFFFF
        if not table:
            raise SystemExit(f"hole at level {level} for va {va:#x}")
    return (table << 12) | (va & 0xFFF)


root, va, w, h, stride = (int(x, 0) for x in sys.argv[1:6])
pages = {}
for pva in range(va & ~0xFFF, va + (h - 1) * stride + w * 4, 0x1000):
    pages[pva] = phys(translate(root, pva), 0x1000)


def vread(a, n):
    out = b""
    while n:
        c = min(n, 0x1000 - (a & 0xFFF))
        out += pages[a & ~0xFFF][a & 0xFFF:(a & 0xFFF) + c]
        a, n = a + c, n - c
    return out


rows = []
for y in range(h):
    row = vread(va + y * stride, w * 4)
    # BGRA (premultiplied) -> RGBA
    rows.append(b"\0" + b"".join(bytes((row[i + 2], row[i + 1], row[i], row[i + 3])) for i in range(0, w * 4, 4)))
png = b"\x89PNG\r\n\x1a\n"
for tag, data in ((b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)),
                  (b"IDAT", zlib.compress(b"".join(rows))), (b"IEND", b"")):
    png += struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))
open(sys.argv[6], "wb").write(png)
print("wrote", sys.argv[6])
