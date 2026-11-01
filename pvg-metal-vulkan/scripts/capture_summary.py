#!/usr/bin/env python3
"""Summarise a frame capture from a pvg trace log (lines "pvg_linux_exec cap N ...").

Usage: capture_summary.py TRACE_LOG [FIRST_SEQ [LAST_SEQ]]
Prints one block per captured render segment: its attachments (ref, level, size, format,
load/store) and draws (pipeline, shaders, bound textures, depth/stencil state).
"""
import re
import sys

log = sys.argv[1]
lo = int(sys.argv[2]) if len(sys.argv) > 2 else 0
hi = int(sys.argv[3]) if len(sys.argv) > 3 else 1 << 30
segs = {}
for line in open(log, errors="replace"):
    m = re.match(r"(?:\S+Z )?pvg_linux_exec cap (\d+) (.*)", line.rstrip())
    if not m:
        continue
    seq, rest = int(m.group(1)), m.group(2)
    if lo <= seq <= hi:
        segs.setdefault(seq, []).append(rest)
for seq in sorted(segs):
    lines = segs[seq]
    end = [x for x in lines if x.startswith("end segment")]
    print(f"== seg {seq}: {end[0][len('end segment '):] if end else '(no end)'}")
    for x in lines:
        if not x.startswith("end segment"):
            print("    " + x.strip())
