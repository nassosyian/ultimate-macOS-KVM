#!/usr/bin/env python3
"""Read PVG guest task memory through the trace VM's QEMU monitor (pmemsave + page-table walk).

Usage:
  task_mem.py ROOT_PFN read VA LEN [OUT]       hexdump (or save to OUT) task virtual memory
  task_mem.py ROOT_PFN objects LIST_VA IDS...  decode object table entries {u8 type, u24 len, u64 va}
                                               and hexdump each object body
  task_mem.py ROOT_PFN functions LIST_VA MAX_ID OUT_DIR
                                               save every function object's metallib (type 6)
ROOT_PFN is the task root PFN from the pvg_linux_define_task trace event.
"""
import os
import socket
import struct
import sys
import tempfile

SOCK = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "kvm-osx", "monitor.sock")
TMP = tempfile.mkdtemp()
_page_cache = {}


class Monitor:
    """Persistent HMP connection; each command returns when the next prompt arrives."""

    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(path)
        self._until_prompt()

    def _until_prompt(self):
        buf = b""
        while not buf.rstrip().endswith(b"(qemu)"):
            buf += self.s.recv(65536)
        return buf

    def cmd(self, line):
        self.s.sendall(line.encode() + b"\n")
        return self._until_prompt()


_mon = None


def phys_page(pfn):
    global _mon
    if pfn not in _page_cache:
        if _mon is None:
            _mon = Monitor(SOCK)
        f = os.path.join(TMP, "p.bin")
        _mon.cmd(f'pmemsave {pfn << 12:#x} 0x1000 "{f}"')
        _page_cache[pfn] = open(f, "rb").read()
    return _page_cache[pfn]


class Task:
    def __init__(self, root_pfn):
        self.pt_root, self.depth = struct.unpack_from("<II", phys_page(root_pfn), 0)

    def translate(self, va):
        table, vpn = self.pt_root, va >> 12
        for level in range(self.depth - 1, -1, -1):
            idx = (vpn >> (10 * level)) & 0x3FF
            table = struct.unpack_from("<I", phys_page(table), idx * 4)[0] & 0x7FFFFFFF
            if not table:
                return None
        return table

    def read(self, va, n):
        out = bytearray()
        while n:
            c = min(n, 0x1000 - (va & 0xFFF))
            pfn = self.translate(va)
            out += phys_page(pfn)[va & 0xFFF:(va & 0xFFF) + c] if pfn else b"\xee" * c
            va, n = va + c, n - c
        return bytes(out)


def hexdump(data, base):
    for i in range(0, len(data), 16):
        chunk = data[i:i + 16]
        words = " ".join(f"{struct.unpack_from('<I', chunk, j)[0]:08x}" for j in range(0, len(chunk) - 3, 4))
        print(f"  {base + i:#012x}: {words}")


def main():
    task = Task(int(sys.argv[1], 0))
    cmd = sys.argv[2]
    if cmd == "read":
        va, n = int(sys.argv[3], 0), int(sys.argv[4], 0)
        data = task.read(va, n)
        if len(sys.argv) > 5:
            open(sys.argv[5], "wb").write(data)
        else:
            hexdump(data, va)
    elif cmd == "objects":
        list_va = int(sys.argv[3], 0)
        for oid in (int(x, 0) for x in sys.argv[4:]):
            e = task.read(list_va + 12 * oid, 12)
            head, va = struct.unpack("<IQ", e)
            typ, length = head & 0xFF, head >> 8
            print(f"object {oid}: type={typ:#x} len={length:#x} va={va:#x}")
            if typ and length and length <= 0x400:
                hexdump(task.read(va, length), va)
    elif cmd == "functions":
        list_va, max_id, out = int(sys.argv[3], 0), int(sys.argv[4], 0), sys.argv[5]
        os.makedirs(out, exist_ok=True)
        table = task.read(list_va, 12 * (max_id + 1))
        for oid in range(1, max_id + 1):
            head, va = struct.unpack_from("<IQ", table, 12 * oid)
            if head & 0xFF != 6:
                continue
            body = task.read(va, head >> 8)
            lib_va, lib_len = struct.unpack_from("<QI", body, 0)
            lib = task.read(lib_va, lib_len)
            if lib[:4] == b"MTLB":
                open(os.path.join(out, f"fn{oid:04d}.metallib"), "wb").write(lib)
                print(f"function {oid}: {lib_len:#x} bytes")
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
