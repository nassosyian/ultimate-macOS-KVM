#!/usr/bin/env python3
"""Map PVG MMIO register offsets to the _PGDevice selector each one invokes.

Decodes the clang switch jump tables in -[_PGDevice mmioWriteAtOffset:value:] / mmioReadAtOffset:
of an extracted ParavirtualizedGraphics binary (scripts/dsc_extract.py output + .ptrs.tsv).
Usage: decode_mmio_jumptable.py BINARY FUNC_START FUNC_END TABLE_ADDR:FIRST_INDEX:COUNT:REG_BASE ...
"""
import re
import struct
import subprocess
import sys

binary, start, end = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 16)
ptrs = {}
for line in open(binary + ".ptrs.tsv"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) == 3 and parts[0].startswith("0x"):
        ptrs[int(parts[0], 16)] = parts[2]

dis = subprocess.run(["llvm-objdump-19", "-d", "--no-show-raw-insn", f"--start-address={start:#x}",
                      f"--stop-address={end:#x}", binary], capture_output=True, text=True).stdout
insns = []
for line in dis.splitlines():
    m = re.match(r"\s*([0-9a-f]+):\s+(.*)", line)
    if m:
        insns.append((int(m.group(1), 16), m.group(2)))


def selector_after(addr):
    """Follow straight-line code / jmps from addr until a selref load into %rsi."""
    seen = set()
    while addr not in seen:
        seen.add(addr)
        idx = next((i for i, (a, _) in enumerate(insns) if a == addr), None)
        if idx is None:
            return f"<target {addr:#x} outside function>"
        for a, text in insns[idx:]:
            m = re.search(r"## (0x[0-9a-f]+)", text)
            iv = re.match(r"movl\s+(0x[0-9a-f]+)\(%rdi\), %eax", text)
            if iv:
                return f"ivar[{iv.group(1)}] (u32)"
            xc = re.match(r"xchgl\s+%eax, (0x[0-9a-f]+)\(%rdi\)", text)
            if xc:
                return f"READ-AND-CLEAR ivar[{xc.group(1)}]"
            if text.startswith("movq") and "(%rdi), %rdi" in text:
                continue  # message sent to a sub-object; selector follows
            if "%rsi" in text and text.startswith("movq") and m:
                slot = int(m.group(1), 16)
                return ptrs.get(slot, f"<selref {slot:#x}>").strip('"')
            if text.startswith(("callq", "retq")):
                return f"<{text.split()[0]} at {a:#x}: special case>"
            if text.startswith("jmp") and not text.startswith("jmpq"):
                addr = int(text.split()[1], 16)
                break
        else:
            return "<?>"
    return "<loop>"


with open(binary, "rb") as f:
    data = f.read()
text_vmaddr = 0x7ffb1734a000  # __TEXT vmaddr == file offset 0 in the extracted image
for spec in sys.argv[4:]:
    table, first, count, base = spec.split(":")
    table, first, count, base = int(table, 16), int(first, 16), int(count, 16), int(base, 16)
    for i in range(count):
        rel = struct.unpack_from("<i", data, table - text_vmaddr + 4 * i)[0]
        target = table + rel
        print(f"reg {base + 4 * (first + i):#06x}  -> {selector_after(target)}")
