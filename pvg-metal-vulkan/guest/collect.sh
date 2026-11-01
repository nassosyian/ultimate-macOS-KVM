#!/bin/sh
# Runs INSIDE the macOS guest. Copies the PVG-related Apple binaries onto the transfer disk.
# Usage (macOS Terminal):  sh /Volumes/PVGXFER/collect.sh        everything (reverse engineering)
#                          sh /Volumes/PVGXFER/collect.sh rom    only what the host needs to boot:
#                          ParavirtualizedGraphics.framework (AppleParavirtEFI.rom)
set -u
DST=/Volumes/PVGXFER/collected
mkdir -p "$DST/extensions" "$DST/frameworks" "$DST/dyld"

sw_vers > "$DST/sw_vers.txt"
uname -a >> "$DST/sw_vers.txt"

echo "== PVG kexts / driver bundles"
for p in /System/Library/Extensions/*[Pp]aravirt*; do
    [ -e "$p" ] && echo "  $p" && cp -RL "$p" "$DST/extensions/"
done

echo "== ParavirtualizedGraphics.framework (headers, resources, option ROM)"
cp -RL /System/Library/Frameworks/ParavirtualizedGraphics.framework "$DST/frameworks/" 2>/dev/null
if [ "${1:-}" = rom ]; then
    ls -l "$DST/frameworks/ParavirtualizedGraphics.framework/Versions/A/Resources/AppleParavirtEFI.rom"
    echo "Done. Now shut down the VM."
    exit 0
fi

echo "== dyld shared cache (x86_64 only, can take a few minutes)"
for d in /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld /System/Cryptexes/OS/System/Library/dyld /System/Library/dyld; do
    if ls "$d"/dyld_shared_cache_x86_64* >/dev/null 2>&1; then
        echo "  from $d"
        for f in "$d"/dyld_shared_cache_x86_64*; do
            echo "    $(basename "$f")"
            cp "$f" "$DST/dyld/"
        done
        break
    fi
done

echo "== GPU devices seen by the guest"
ioreg -l -w0 -r -c IOPCIDevice | grep -iE '"(vendor-id|device-id|IOName|name)"' > "$DST/ioreg-pci.txt" 2>/dev/null
kextstat 2>/dev/null | grep -i paravirt > "$DST/kextstat.txt"

echo "== checksums"
(cd "$DST" && find . -type f ! -name SHA256SUMS -exec shasum -a 256 {} \; > SHA256SUMS)
du -sh "$DST"
echo "Done. Now run:  diskutil eject /Volumes/PVGXFER   and shut down the VM."
