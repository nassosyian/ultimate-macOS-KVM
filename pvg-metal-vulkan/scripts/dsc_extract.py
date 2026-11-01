#!/usr/bin/env python3
"""Extract one image from an x86_64 dyld shared cache into a standalone Mach-O.

Usage:
  dsc_extract.py CACHE_DIR list [SUBSTRING]
  dsc_extract.py CACHE_DIR extract IMAGE_PATH OUT.macho

CACHE_DIR holds dyld_shared_cache_x86_64[h] plus its subcaches (.1, .2, ...) and
.symbols file. The output keeps the original VM addresses, rebuilds __LINKEDIT
with the image's exported, imported and local symbols, and undoes slide-info v2
pointer encoding in data segments. A sidecar OUT.macho.ptrs.tsv maps every
pointer-sized slot in the image's data segments whose target lies outside the
image to a resolved name (ObjC selector string, class name or exported symbol),
which llvm-objdump cannot do on its own.
"""
import bisect
import glob
import os
import struct
import sys

LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_DYSYMTAB = 0xB
LC_FUNCTION_STARTS = 0x26
LC_DATA_IN_CODE = 0x29
LINKEDIT_DATA_CMDS = {0x1D, 0x1E, 0x26, 0x29, 0x2B, 0x2E, 0x80000033, 0x80000034}
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022


class Cache:
    def __init__(self, cache_dir):
        mains = [p for p in glob.glob(os.path.join(cache_dir, "dyld_shared_cache_x86_64*"))
                 if not p.endswith((".map", ".symbols", ".atlas")) and "." not in os.path.basename(p)]
        if len(mains) != 1:
            raise SystemExit(f"expected one main cache in {cache_dir}, found {mains}")
        self.main_path = mains[0]
        files = [self.main_path] + sorted(
            p for p in glob.glob(self.main_path + ".*")
            if not p.endswith((".map", ".symbols", ".atlas")))
        self.files = {p: open(p, "rb") for p in files}
        self.maps = []  # (addr, size, fileoff, path, slide_info_off)
        for p, f in self.files.items():
            hdr = self._pread(f, 0, 0x200)
            mapping_off, mapping_cnt = struct.unpack_from("<II", hdr, 0x10)
            with_slide_off, with_slide_cnt = (0, 0)
            if mapping_off >= 0x140:
                with_slide_off, with_slide_cnt = struct.unpack_from("<II", hdr, 0x138)
            if with_slide_cnt:
                raw = self._pread(f, with_slide_off, 56 * with_slide_cnt)
                for i in range(with_slide_cnt):
                    a, s, fo, si_off, si_size, _flags, _mp, _ip = struct.unpack_from("<QQQQQQII", raw, 56 * i)
                    self.maps.append((a, s, fo, p, si_off if si_size else 0))
            else:
                raw = self._pread(f, mapping_off, 32 * mapping_cnt)
                for i in range(mapping_cnt):
                    a, s, fo, _mp, _ip = struct.unpack_from("<QQQII", raw, 32 * i)
                    self.maps.append((a, s, fo, p, 0))
        self.maps.sort()
        self.map_starts = [m[0] for m in self.maps]
        hdr = self._pread(self.files[self.main_path], 0, 0x200)
        self.mapping_off = struct.unpack_from("<I", hdr, 0x10)[0]
        img_off, img_cnt = struct.unpack_from("<II", hdr, 0x18)
        if img_off == 0 and self.mapping_off >= 0x1C8:
            img_off, img_cnt = struct.unpack_from("<II", hdr, 0x1C0)
        raw = self._pread(self.files[self.main_path], img_off, 32 * img_cnt)
        self.images = []
        for i in range(img_cnt):
            addr, _mt, _ino, path_off = struct.unpack_from("<QQQI", raw, 32 * i)
            self.images.append((self._cstr_file(self.files[self.main_path], path_off), addr))
        self.base = self.maps[0][0]
        self._slide_cache = {}

    @staticmethod
    def _pread(f, off, n):
        f.seek(off)
        return f.read(n)

    def _cstr_file(self, f, off):
        data = self._pread(f, off, 1024)
        return data.split(b"\0", 1)[0].decode()

    def locate(self, addr):
        i = bisect.bisect_right(self.map_starts, addr) - 1
        if i < 0:
            return None
        a, s, fo, p, si = self.maps[i]
        if addr >= a + s:
            return None
        return (a, s, fo, p, si)

    def read(self, addr, n):
        out = bytearray()
        while n > 0:
            m = self.locate(addr)
            if m is None:
                out += b"\0" * n
                break
            a, s, fo, p, _ = m
            chunk = min(n, a + s - addr)
            out += self._pread(self.files[p], fo + addr - a, chunk)
            addr += chunk
            n -= chunk
        return bytes(out)

    def cstr(self, addr, limit=512):
        return self.read(addr, limit).split(b"\0", 1)[0].decode("utf-8", "replace")

    def u64(self, addr):
        return struct.unpack("<Q", self.read(addr, 8))[0]

    def slide_v2(self, m):
        """Return (delta_mask, value_add) for a mapping that carries slide info v2."""
        a, s, fo, p, si = m
        if not si:
            return None
        key = (p, si)
        if key not in self._slide_cache:
            hdr = self._pread(self.files[p], si, 40)
            version = struct.unpack_from("<I", hdr)[0]
            if version != 2:
                self._slide_cache[key] = ("unsupported", version)
            else:
                _v, _ps, _pso, _psc, _peo, _pec, dmask, vadd = struct.unpack_from("<IIIIIIQQ", hdr)
                self._slide_cache[key] = (dmask, vadd)
        return self._slide_cache[key]

    def fix_ptr(self, addr, raw):
        """Decode a slide-info-v2 encoded pointer slot (best effort: mask the delta bits)."""
        m = self.locate(addr)
        info = self.slide_v2(m) if m else None
        if not info or info[0] == "unsupported":
            return raw
        dmask, vadd = info
        val = raw & ~dmask & 0xFFFFFFFFFFFFFFFF
        return val + vadd if val else 0


def parse_lcs(cache, mh_addr):
    hdr = cache.read(mh_addr, 32)
    magic, _cpu, _sub, _ft, ncmds, sizeofcmds, _fl, _r = struct.unpack("<IiiIIIII", hdr)
    if magic != 0xFEEDFACF:
        raise SystemExit(f"bad mach-o magic at {mh_addr:#x}")
    raw = bytearray(cache.read(mh_addr + 32, sizeofcmds))
    cmds, off = [], 0
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", raw, off)
        cmds.append((cmd, off, size))
        off += size
    return bytearray(hdr), raw, cmds


def segments(raw, cmds):
    segs = []
    for cmd, off, _size in cmds:
        if cmd == LC_SEGMENT_64:
            name = raw[off + 8:off + 24].split(b"\0")[0].decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", raw, off + 24)
            segs.append(dict(name=name, off=off, vmaddr=vmaddr, vmsize=vmsize, fileoff=fileoff, filesize=filesize))
    return segs


def global_exports(cache):
    """addr -> name for every external defined symbol in the cache (used for GOT/pointer resolution)."""
    out = {}
    for path, mh in cache.images:
        try:
            _h, raw, cmds = parse_lcs(cache, mh)
        except SystemExit:
            continue
        segs = segments(raw, cmds)
        le = next((s for s in segs if s["name"] == "__LINKEDIT"), None)
        st = next(((o, z) for c, o, z in cmds if c == LC_SYMTAB), None)
        dy = next(((o, z) for c, o, z in cmds if c == LC_DYSYMTAB), None)
        if not (le and st and dy):
            continue
        symoff, nsyms, stroff, _strsize = struct.unpack_from("<IIII", raw, st[0] + 8)
        iext, next_ = struct.unpack_from("<II", raw, dy[0] + 16)
        f2v = le["vmaddr"] - le["fileoff"]
        nl = cache.read(f2v + symoff + 16 * iext, 16 * next_)
        for i in range(next_):
            strx, ntype, _sect, _desc, value = struct.unpack_from("<IBBHQ", nl, 16 * i)
            if value and (ntype & 0x0E) == 0x0E:
                out.setdefault(value, cache.cstr(f2v + stroff + strx, 256))
    return out


def extract(cache, image_path, out_path):
    mh = next((a for p, a in cache.images if p == image_path), None)
    if mh is None:
        raise SystemExit(f"image not in cache: {image_path}")
    hdr, raw, cmds = parse_lcs(cache, mh)
    segs = segments(raw, cmds)
    le = next(s for s in segs if s["name"] == "__LINKEDIT")
    f2v = le["vmaddr"] - le["fileoff"]

    body = bytearray()
    cursor = 0x4000  # leave room for header + load commands (text segment starts at 0 below)
    seg_data = {}
    for s in segs:
        if s["name"] == "__LINKEDIT":
            continue
        data = bytearray(cache.read(s["vmaddr"], s["filesize"]))
        if s["name"] != "__TEXT":
            # undo slide-info pointer encoding: walk every 8-byte slot (best effort)
            for o in range(0, len(data) - 7, 8):
                v = struct.unpack_from("<Q", data, o)[0]
                if v:
                    struct.pack_into("<Q", data, o, cache.fix_ptr(s["vmaddr"] + o, v))
        seg_data[s["name"]] = data

    # file layout: __TEXT at 0 (it contains the mach header), others page aligned after it
    layout, cursor = {}, 0
    for s in segs:
        if s["name"] == "__LINKEDIT":
            continue
        layout[s["name"]] = cursor
        cursor += (len(seg_data[s["name"]]) + 0xFFF) & ~0xFFF

    # rebuild linkedit: symbols (locals from .symbols file first), strings, function starts
    st = next(o for c, o, z in cmds if c == LC_SYMTAB)
    dy = next(o for c, o, z in cmds if c == LC_DYSYMTAB)
    symoff, nsyms, stroff, _strsize = struct.unpack_from("<IIII", raw, st + 8)
    nl = cache.read(f2v + symoff, 16 * nsyms)
    strtab = bytearray(b"\0 \0")
    str_idx = {}

    def add_str(s):
        if s not in str_idx:
            str_idx[s] = len(strtab)
            strtab.extend(s.encode() + b"\0")
        return str_idx[s]

    locals_ = load_local_symbols(cache, mh)
    new_nl = bytearray()
    for name, ntype, sect, desc, value in locals_:
        new_nl += struct.pack("<IBBHQ", add_str(name), ntype, sect, desc, value)
    for i in range(nsyms):
        strx, ntype, sect, desc, value = struct.unpack_from("<IBBHQ", nl, 16 * i)
        new_nl += struct.pack("<IBBHQ", add_str(cache.cstr(f2v + stroff + strx, 512)), ntype, sect, desc, value)

    linkedit = bytearray()
    le_off = cursor
    fstarts = b""
    for c, o, _z in cmds:
        if c == LC_FUNCTION_STARTS:
            doff, dsize = struct.unpack_from("<II", raw, o + 8)
            fstarts = cache.read(f2v + doff, dsize)
    fs_off = le_off + len(linkedit)
    linkedit += fstarts
    linkedit += b"\0" * (-len(linkedit) % 8)
    sym_off = le_off + len(linkedit)
    linkedit += new_nl
    str_off = le_off + len(linkedit)
    linkedit += strtab

    # patch load commands
    for c, o, _z in cmds:
        if c == LC_SEGMENT_64:
            name = raw[o + 8:o + 24].split(b"\0")[0].decode()
            vmaddr, vmsize, _fo, _fs = struct.unpack_from("<QQQQ", raw, o + 24)
            if name == "__LINKEDIT":
                struct.pack_into("<QQQQ", raw, o + 24, vmaddr, (len(linkedit) + 0xFFF) & ~0xFFF, le_off, len(linkedit))
                continue
            struct.pack_into("<QQ", raw, o + 40, layout[name], len(seg_data[name]))
            nsects = struct.unpack_from("<I", raw, o + 64)[0]
            for k in range(nsects):
                so = o + 72 + 80 * k
                addr, _size, _off = struct.unpack_from("<QQI", raw, so + 32)
                flags = struct.unpack_from("<I", raw, so + 64)[0]
                zerofill = (flags & 0xFF) in (0x1, 0xC, 0x12)
                struct.pack_into("<I", raw, so + 48, 0 if zerofill else layout[name] + addr - vmaddr)
                struct.pack_into("<II", raw, so + 56, 0, 0)  # no relocations
        elif c == LC_SYMTAB:
            struct.pack_into("<IIII", raw, o + 8, sym_off, len(new_nl) // 16, str_off, len(strtab))
        elif c == LC_DYSYMTAB:
            vals = list(struct.unpack_from("<18I", raw, o + 8))
            nloc = len(locals_)
            vals[0], vals[1] = 0, nloc + vals[1]
            vals[2] += nloc
            vals[4] += nloc
            for k in range(6, 18):
                vals[k] = 0  # drop toc/modtab/extref/indirect/extrel/locrel tables
            struct.pack_into("<18I", raw, o + 8, *vals)
        elif c == LC_FUNCTION_STARTS:
            struct.pack_into("<II", raw, o + 8, fs_off, len(fstarts))
        elif c in LINKEDIT_DATA_CMDS:
            struct.pack_into("<II", raw, o + 8, 0, 0)
        elif c in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
            struct.pack_into("<10I", raw, o + 8, *([0] * 10))

    flags = struct.unpack_from("<I", hdr, 24)[0]
    struct.pack_into("<I", hdr, 24, flags & ~0x80000000)  # clear MH_DYLIB_IN_CACHE
    out = bytearray(cursor + len(linkedit))
    for s in segs:
        if s["name"] != "__LINKEDIT":
            out[layout[s["name"]]:layout[s["name"]] + len(seg_data[s["name"]])] = seg_data[s["name"]]
    out[0:32] = hdr
    out[32:32 + len(raw)] = raw
    out[le_off:le_off + len(linkedit)] = linkedit
    with open(out_path, "wb") as f:
        f.write(out)

    write_pointer_map(cache, segs, seg_data, out_path + ".ptrs.tsv")
    print(f"wrote {out_path}: {len(out)} bytes, {len(locals_)} local + {nsyms} cache symbols")


def load_local_symbols(cache, mh_addr):
    sym_path = cache.main_path + ".symbols"
    path = sym_path if os.path.exists(sym_path) else cache.main_path
    with open(path, "rb") as f:
        hdr = Cache._pread(f, 0, 0x200)
        lso, lss = struct.unpack_from("<QQ", hdr, 0x48)
        if not lso:
            return []
        info = Cache._pread(f, lso, lss)
    nl_off, nl_cnt, s_off, s_size, e_off, e_cnt = struct.unpack_from("<6I", info, 0)
    # entries are 16 bytes (64-bit dylibOffset relative to cache base) on macOS 12+, 12 bytes before
    candidates = []
    for esize, fmt in ((16, "<QII"), (12, "<III")):
        for i in range(e_cnt):
            d_off, start, cnt = struct.unpack_from(fmt, info, e_off + esize * i)
            candidates.append((esize, d_off, start, cnt))
    want = mh_addr - cache.base
    for esize, d_off, start, cnt in candidates:
        if d_off == want and start + cnt <= nl_cnt:
            out = []
            for i in range(start, start + cnt):
                strx, ntype, sect, desc, value = struct.unpack_from("<IBBHQ", info, nl_off + 16 * i)
                name = info[s_off + strx:s_off + strx + 512].split(b"\0", 1)[0].decode("utf-8", "replace")
                out.append((name, ntype, sect, desc, value))
            return out
    return []


def write_pointer_map(cache, segs, seg_data, path):
    lo = min(s["vmaddr"] for s in segs if s["name"] != "__LINKEDIT")
    hi = max(s["vmaddr"] + s["vmsize"] for s in segs if s["name"] != "__LINKEDIT")
    exports = global_exports(cache)
    with open(path, "w") as f:
        f.write("slot\ttarget\tname\n")
        for s in segs:
            if s["name"] in ("__TEXT", "__LINKEDIT"):
                continue
            data = seg_data[s["name"]]
            for o in range(0, len(data) - 7, 8):
                tgt = struct.unpack_from("<Q", data, o)[0]
                if not tgt or lo <= tgt < hi or cache.locate(tgt) is None:
                    continue
                name = exports.get(tgt)
                if name is None:
                    txt = cache.cstr(tgt, 200)
                    name = f'"{txt}"' if txt and txt.isprintable() else ""
                f.write(f"{s['vmaddr'] + o:#x}\t{tgt:#x}\t{name}\n")


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    cache = Cache(sys.argv[1])
    if sys.argv[2] == "list":
        sub = sys.argv[3] if len(sys.argv) > 3 else ""
        for p, a in cache.images:
            if sub.lower() in p.lower():
                print(f"{a:#x}\t{p}")
    elif sys.argv[2] == "extract":
        extract(cache, sys.argv[3], sys.argv[4])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
