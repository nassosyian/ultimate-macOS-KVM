#!/usr/bin/env python3
"""Pull the AIR bitcode module out of a single-function metallib (bitcode wrapper 0x0B17C0DE).
Usage: metallib_extract.py IN.metallib OUT.bc"""
import struct
import sys

d = open(sys.argv[1], "rb").read()
w = d.find(b"\xde\xc0\x17\x0b")
if d[:4] != b"MTLB" or w < 0:
    raise SystemExit("not a metallib with a wrapped bitcode module")
_magic, _ver, off, size, _cpu = struct.unpack_from("<5I", d, w)
open(sys.argv[2], "wb").write(d[w + off:w + off + size])
