#!/usr/bin/env python3
"""Extract PGCmdHeader id -> decode selector tables from the annotated Ghidra C of the PVG framework.
Usage: decoder_tables.py PVG.annotated.c"""
import re
import sys

src = open(sys.argv[1]).read()
for m in re.finditer(r"// ===== -\[(PGDeserializer\w+Decoder)_decodeWithHeader:withIterator:\] @ \w+ =====\n(.*?)(?=\n// ===== )", src, re.S):
    cls, body = m.group(1), m.group(2)
    locals_ = dict(re.findall(r'(local_[0-9a-f]+) = &DAT_\w+/\*"(\w+:)"\*/;', body))
    sw = body[body.find("switch("):]
    default = re.search(r'puVar\d+ = &DAT_\w+/\*"(\w+:)"\*/;\s*\n\s*switch', body)
    table, pending = {}, []
    for line in sw.splitlines():
        c = re.match(r"\s*case (0x[0-9a-f]+|\d+):", line)
        if c:
            pending.append(int(c.group(1), 0))
            continue
        a = re.search(r"puVar\d+ = (local_[0-9a-f]+|&DAT_\w+/\*\"(\w+:)\"\*/);", line)
        if a and pending:
            sel = a.group(2) or locals_.get(a.group(1), a.group(1))
            for p in pending:
                table[p] = sel
            pending = []
        elif "break;" in line and pending:
            for p in pending:
                table[p] = default.group(1) if default else "?"
            pending = []
    print(f"## {cls} ({len(table)} commands)")
    for k in sorted(table):
        print(f"{k:#06x} {table[k].replace('WithCursor:', '')}")
