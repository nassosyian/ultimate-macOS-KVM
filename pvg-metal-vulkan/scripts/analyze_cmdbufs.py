#!/usr/bin/env python3
"""Offline analysis of dumped PVG ExecIndirect2 command buffers.
Usage: analyze_cmdbufs.py DUMP_DIR [--verbose N]"""
import collections
import glob
import os
import re
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
names, cur = {}, None
for line in open(os.path.join(ROOT, "docs/pvg-decoder-tables.txt")):
    m = re.match(r"## PGDeserializer(\w+)Decoder", line)
    if m:
        cur = m.group(1).lower()
        continue
    m = re.match(r"(0x[0-9a-f]+) decode(\w+)", line)
    if m:
        names.setdefault(cur, {})[int(m.group(1), 16)] = m.group(2)
ENC = {0: "render", 1: "compute", 2: "blit", 4: "info", 5: "protection"}


def chain(buf, start, end, table):
    """Return the list of (id, len, off) if command headers chain exactly from start to end."""
    out, off = [], start
    while off < end:
        if off + 8 > end:
            return None
        cid, clen = struct.unpack_from("<II", buf, off)
        if clen < 8 or off + clen > end or cid not in table:
            return None
        out.append((cid, clen, off))
        off += clen
    return out


stats, desc_sizes = collections.Counter(), collections.Counter()
verbose = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[2] == "--verbose" else 0
for path in sorted(glob.glob(os.path.join(sys.argv[1], "cb-*.bin"))):
    buf = open(path, "rb").read()
    off = 0
    while off + 8 <= len(buf):
        seglen, enc, cont, endf = struct.unpack_from("<IBBB", buf, off)
        if seglen < 8:
            break
        kind = ENC.get(enc, f"enc{enc}")
        table = names.get(kind, {})
        start = off + 8
        cmds, dsize = None, 0
        for dsize in range(0, min(0x800, seglen - 8) + 1, 4):
            if kind == "render" and cont == 0 and dsize == 0:
                pass
            cmds = chain(buf, start + dsize, off + seglen, table)
            if cmds is not None and (cmds or dsize == seglen - 8):
                break
        if cmds is None:
            stats[f"{kind}: unparsed"] += 1
        else:
            if kind == "render" and not cont:
                desc_sizes[dsize] += 1
            for cid, clen, coff in cmds:
                stats[f"{kind}: {table[cid]}"] += 1
            if verbose:
                verbose -= 1
                print(f"{os.path.basename(path)} +{off:#x} {kind} len={seglen:#x} cont={cont} desc={dsize:#x}")
                if dsize:
                    d = buf[start:start + dsize]
                    print("   desc:", " ".join(f"{w:08x}" for w in struct.unpack_from(f"<{dsize // 4}I", d)))
                for cid, clen, coff in cmds:
                    words = struct.unpack_from(f"<{(clen - 8) // 4}I", buf, coff + 8)
                    print(f"   {table[cid]:<36} " + " ".join(f"{w:x}" for w in words[:12]))
        off += seglen
print("render pass descriptor sizes:", dict(desc_sizes))
for k, v in stats.most_common(40):
    print(f"{v:7d}  {k}")
