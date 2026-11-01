#!/usr/bin/env python3
"""Annotate Ghidra-exported C from a dyld-cache image with strings resolved from the cache.

Every DAT_/PTR_/s_ reference whose address lies outside the extracted image (typically ObjC
selector names, class names and C strings in other cache images) gets a /* "text" */ comment.
Usage: annotate_decomp.py CACHE_DIR IN.c OUT.c
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dsc_extract import Cache  # noqa: E402

cache = Cache(sys.argv[1])
src = open(sys.argv[2]).read()
memo = {}


def resolve(addr):
    if addr not in memo:
        txt = cache.cstr(addr, 160) if cache.locate(addr) else ""
        memo[addr] = txt if txt and txt.isprintable() and len(txt) >= 2 else None
    return memo[addr]


def sub(m):
    s = resolve(int(m.group(2), 16))
    return f'{m.group(0)}/*"{s}"*/' if s else m.group(0)


out = re.sub(r"\b(DAT|PTR_[A-Za-z0-9_]*?|s_[A-Za-z0-9_]*?)_(7ff[0-9a-f]{9})\b", sub, src)
open(sys.argv[3], "w").write(out)
print(f"resolved {sum(1 for v in memo.values() if v)} of {len(memo)} addresses")
