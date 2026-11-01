#!/usr/bin/env bash
# Collect AppleParavirtEFI.rom (the PVG option ROM) from the macOS guest, once before the first
# scripts/run-pvg-vm.sh. Creates a FAT32 transfer disk (label PVGXFER) holding guest/collect.sh,
# boots the normal ULTMOS VM (its AutoPilot boot script, stock graphics) with that disk attached,
# and after the VM shuts down copies the collected files into re/collected/.
# In the guest: open Terminal, run  sh /Volumes/PVGXFER/collect.sh rom  and shut down.
#   ULTMOS=dir        the ultimate-macOS-KVM checkout (default: as in run-pvg-vm.sh)
#   BOOT_SCRIPT=file  its boot script (default: $ULTMOS/boot.sh)
# Needs dosfstools (mkfs.fat) and mtools (mcopy); no root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${ULTMOS:-}" ]; then
    if [ -f "$ROOT/../main.py" ]; then ULTMOS="$(cd "$ROOT/.." && pwd)"
    else ULTMOS="$(cd "$ROOT/.." && pwd)/ultimate-macOS-KVM"; fi
fi
BOOT_SCRIPT="${BOOT_SCRIPT:-$ULTMOS/boot.sh}"
XFER_DIR="$ROOT/re/transfer"
IMG="$XFER_DIR/transfer.img"
ROM="$ROOT/re/collected/collected/frameworks/ParavirtualizedGraphics.framework/Versions/A/Resources/AppleParavirtEFI.rom"

[ -f "$BOOT_SCRIPT" ] || { echo "no boot script at $BOOT_SCRIPT: create the VM with ULTMOS AutoPilot first" >&2; exit 1; }
for t in mkfs.fat mcopy; do
    command -v "$t" >/dev/null || { echo "missing $t: install dosfstools and mtools" >&2; exit 1; }
done

mkdir -p "$XFER_DIR"
if [ ! -f "$IMG" ]; then
    truncate -s 2G "$IMG"
    mkfs.fat -F 32 -n PVGXFER "$IMG" >/dev/null
fi
mcopy -o -i "$IMG" "$ROOT/guest/collect.sh" ::collect.sh

# the boot script with the transfer disk on a free AHCI port after the system disk
PORT=4
while grep -q "^-device ide-hd,bus=sata\.$PORT," "$BOOT_SCRIPT"; do PORT=$((PORT + 1)); done
BOOT="$XFER_DIR/boot-with-transfer.sh"
awk -v img="$IMG" -v port="$PORT" '
    { print }
    /^-device ide-hd,bus=sata\.[0-9]+,drive=HDD/ && !done {
        print "-drive id=XFER,if=none,format=raw,file=\"" img "\""
        print "-device ide-hd,bus=sata." port ",drive=XFER"
        done = 1
    }
    END { if (!done) exit 1 }' "$BOOT_SCRIPT" > "$BOOT" ||
    { echo "could not find the HDD device line in $BOOT_SCRIPT" >&2; exit 1; }
chmod +x "$BOOT"

echo "Booting the VM with the transfer disk. In macOS, open Terminal and run:"
echo "    sh /Volumes/PVGXFER/collect.sh rom"
echo "then shut the VM down."
(cd "$ULTMOS" && "$BOOT")

mkdir -p "$ROOT/re/collected"
mcopy -s -n -o -i "$IMG" ::collected "$ROOT/re/collected/" 2>/dev/null || true
if [ -f "$ROM" ]; then
    echo "AppleParavirtEFI.rom collected: $ROM"
else
    echo "AppleParavirtEFI.rom not found on the transfer disk: run collect.sh in the guest and retry" >&2
    exit 1
fi
