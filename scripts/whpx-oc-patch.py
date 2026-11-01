"""Add OpenCore kernel patches that turn XNU's wrmsr to IA32_SYSENTER_CS/ESP/EIP (0x174-0x176)
into 2-byte NOPs. Hyper-V (WHPX) on AMD raises #GP on these writes; KVM emulates them.
Extra arguments are set as boot-args (e.g. -v serial=3 debug=0x100); --no-sysenter skips the
patches (QEMU with the pvg-metal-vulkan WHPX patches emulates the writes: intercept-msr-gp=on).

Usage (Windows, for boot-whpx.ps1; needs `pip install pyfatfs`):
  qemu-img convert -O raw boot/OpenCore.qcow2 OpenCore.raw
  python whpx-oc-patch.py OpenCore.raw [boot-arg ...]   # edits EFI/OC/config.plist in place
  qemu-img convert -O qcow2 OpenCore.raw boot/OpenCore.qcow2"""
import plistlib, struct, sys
from pyfatfs.PyFatFS import PyFatFS

sysenter = "--no-sysenter" not in sys.argv     # not needed with -accel whpx,intercept-msr-gp=on
sys.argv = [a for a in sys.argv if a != "--no-sysenter"]
raw = sys.argv[1]
with open(raw, "rb") as f:
    hdr = f.read(1 << 20)
lba = struct.unpack("<Q", hdr[512 + 72:512 + 80])[0]
ent = hdr[lba * 512:lba * 512 + 128]
first, last = struct.unpack("<QQ", ent[32:48])
off, size = first * 512, (last - first + 1) * 512
part = raw + ".part"
with open(raw, "rb") as f, open(part, "wb") as g:
    f.seek(off); g.write(f.read(size))

fs = PyFatFS(part, read_only=False)
with fs.openbin("/EFI/OC/config.plist", "r") as f:
    cfg = plistlib.loads(f.read())
patches = cfg["Kernel"]["Patch"]
patches[:] = [p for p in patches if not p.get("Comment", "").startswith("WHPX sysenter")]
for msr in (0x174, 0x175, 0x176) if sysenter else ():
    find = bytes([0xB9, msr & 0xFF, msr >> 8, 0, 0, 0x0F, 0x30])
    patches.append({
        "Arch": "x86_64", "Base": "", "Comment": "WHPX sysenter MSR 0x%x wrmsr -> nop" % msr,
        "Count": 0, "Enabled": True, "Find": find, "Identifier": "kernel", "Limit": 0,
        "Mask": b"", "MaxKernel": "", "MinKernel": "", "Replace": find[:5] + b"\x66\x90",
        "ReplaceMask": b"", "Skip": 0})
nv = cfg["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]
args = nv.get("boot-args", "").split()
for a in sys.argv[2:]:
    args = [x for x in args if x.split("=")[0] != a.split("=")[0]] + [a]
nv["boot-args"] = " ".join(args)
# boot-args from config only apply if NVRAM is (re)written: delete the stored value first
cfg["NVRAM"].setdefault("Delete", {}).setdefault("7C436110-AB2A-4BBB-A880-FE41995C9F82", [])
if "boot-args" not in cfg["NVRAM"]["Delete"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]:
    cfg["NVRAM"]["Delete"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"].append("boot-args")
data = plistlib.dumps(cfg)
fs.remove("/EFI/OC/config.plist")
with fs.openbin("/EFI/OC/config.plist", "w") as f:
    f.write(data)
fs.close()

with open(part, "rb") as g, open(raw, "r+b") as f:
    f.seek(off); f.write(g.read())
print("patched: %d kernel patches, boot-args=%r" % (
    len(patches), cfg["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"].get("boot-args")))
