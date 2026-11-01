#!/usr/bin/env python3
"""Decode PVG serialized pipeline objects (object type 7, kind 0xe) from a live guest.

Usage: decode_pipeline.py TASK_ROOT_PFN OBJECT_IDS...
Body: {u32 kind, u32 len, u32 id, u32 plist_len, plist}. plist = Metal SerializedCompactPropertyList:
u8 count, count x {u8 key, u8 len, value}. Object-valued keys hold a u32 offset (from the plist start)
of a SerializedObjectList: u32 count, then u32 offsets[count] relative to the list start, each pointing
at a nested property list (layout checked live).
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from task_mem import Task  # noqa: E402

RP_KEYS = {0: "label", 1: "vertexFunction", 2: "fragmentFunction", 3: "vertexDescriptor",
           4: "rasterSampleCount", 5: "alphaToCoverage", 6: "alphaToOne", 7: "rasterizationEnabled",
           8: "colorAttachments", 9: "depthPixelFormat", 10: "stencilPixelFormat",
           0xb: "inputPrimitiveTopology", 0x15: "obj15", 0x16: "obj16", 0x19: "supportICB",
           0x1c: "sampleMask", 0x37: "logicOperation", 0x3a: "visibilityGroupID"}
CA_KEYS = {0: "index", 1: "pixelFormat", 2: "blending", 3: "srcRGB", 4: "dstRGB", 5: "rgbOp",
           6: "srcAlpha", 7: "dstAlpha", 8: "alphaOp", 9: "writeMask"}


def plist(buf, off, end, names, depth=0):
    count = buf[off]
    p = off + 1
    out = []
    for _ in range(count):
        if p + 2 > end:
            out.append(("<truncated>", b""))
            break
        key, ln = buf[p], buf[p + 1]
        out.append((names.get(key, f"key{key:#x}"), buf[p + 2:p + 2 + ln]))
        p += 2 + ln
    return out, p


def as_int(v):
    return int.from_bytes(v, "little") if v else 0


def main():
    task = Task(int(sys.argv[1], 0))
    for oid in (int(x, 0) for x in sys.argv[2:]):
        e = task.read(0x1000 + 12 * oid, 12)
        head, va = struct.unpack("<IQ", e)
        body = task.read(va, head >> 8)
        kind, blen, bid, plen = struct.unpack_from("<4I", body, 0)
        pl = body[16:16 + plen]
        print(f"object {oid}: kind={kind:#x} len={blen:#x} plist_len={plen:#x}")
        entries, _ = plist(pl, 0, len(pl), RP_KEYS)
        for name, v in entries:
            if name == "colorAttachments":
                off = as_int(v)
                cnt = struct.unpack_from("<I", pl, off)[0]
                print(f"  colorAttachments: object list @{off:#x} count={cnt}")
                for i in range(cnt):
                    o = off + struct.unpack_from("<I", pl, off + 4 + 4 * i)[0]
                    ca, _ = plist(pl, o, len(pl), CA_KEYS)
                    print("    [%d] " % i + ", ".join(f"{n}={as_int(x):#x}" for n, x in ca))
            elif name in ("label", "vertexDescriptor"):
                off = as_int(v)
                print(f"  {name} @{off:#x}: " + pl[off:off + 48].hex())
            else:
                print(f"  {name} = {as_int(v):#x} ({v.hex()})")


if __name__ == "__main__":
    main()
