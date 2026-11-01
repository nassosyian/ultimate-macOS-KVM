#!/usr/bin/env bash
# Boot the existing ULTMOS macOS VM headless with the pvg-linux-pci tracer device attached.
#
# Never writes to the original disks: HDD, OpenCore and OVMF vars are used through
# copy-on-write overlays in $RUN_DIR. Display goes to VNC on localhost only; the
# QEMU monitor is a unix socket (use scripts/vm-monitor.sh to talk to it).
#
# Usage: [NO_VGA=1] [TRACE_DISPLAY='-display ...'] [TRACE_EVENTS=file] [OC_IMAGE=file] [SERIAL_LOG=file] scripts/run-trace-vm.sh [extra -device pvg-linux-pci properties, e.g. vendor-id=0x106b,device-id=0xeeee]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# the ULTMOS VM: the ultimate-macOS-KVM checkout this folder sits in (pvg-metal-vulkan/ in its root),
# else one next to this folder
if [ -z "${ULTMOS:-}" ]; then
    if [ -f "$ROOT/../main.py" ]; then ULTMOS="$(cd "$ROOT/.." && pwd)"
    else ULTMOS="$(cd "$ROOT/.." && pwd)/ultimate-macOS-KVM"; fi
fi
QEMU="$ROOT/src/qemu/build/qemu-system-x86_64"
QEMU_IMG="$ROOT/src/qemu/build/qemu-img"
RUN_DIR="$ROOT/re/vm"
# UNIX socket paths must be < 108 bytes: keep the sockets out of the (long) project path
SOCK_DIR="${XDG_RUNTIME_DIR:-/tmp}/kvm-osx"
STAMP="$(date +%Y%m%d-%H%M%S)"
PVG_PROPS="${1:-}"
if [ -n "${NO_VGA:-}" ]; then VGA_ARGS="-vga none"; else VGA_ARGS="-device VGA,vgamem_mb=256"; fi
# TRACE_EVENTS=FILE: only those trace events (e.g. scripts/trace-light.events for long sessions)
# USB=ehci: keyboard/tablet on the -usb EHCI bus like ULTMOS (default xHCI: keys typed by
# scripts/guest-type.sh get dropped less)
if [ "${USB:-xhci}" = ehci ]; then USB_ARGS="-usb -device usb-kbd -device usb-tablet"; else
    USB_ARGS="-device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0"; fi
# EXTRA_ARGS="...": more QEMU arguments (e.g. audio devices to try)
# SERIAL_LOG=FILE: guest COM1 to a file (OpenCore debug Target 0x08)
SERIAL_ARGS=""; if [ -n "${SERIAL_LOG:-}" ]; then SERIAL_ARGS="-serial file:$SERIAL_LOG"; fi
if [ -n "${TRACE_EVENTS:-}" ]; then TRACE_ARGS="-trace events=$TRACE_EVENTS"; else TRACE_ARGS="-trace pvg_linux_*"; fi

mkdir -p "$SOCK_DIR" "$RUN_DIR" "$ROOT/logs"
# NET=bridge: libvirt's NAT bridge virbr0 with vhost-net (needs scripts/setup-bridge-net.sh once);
# NET=user: QEMU's user-mode network (slirp; stalls on QUIC/UDP, e.g. Safari + iCloud Private Relay).
# Default: bridge when the helper is set up, otherwise user.
BRIDGE_HELPER=/usr/lib/qemu/qemu-bridge-helper
if [ -z "${NET:-}" ]; then
    if [ -u "$BRIDGE_HELPER" ] && grep -qx "allow virbr0" /etc/qemu/bridge.conf 2>/dev/null; then
        NET=bridge
    else
        NET=user
        echo "note: using slirp networking (slow for QUIC/UDP); run 'sudo scripts/setup-bridge-net.sh' once for the bridge" >&2
    fi
fi
case "$NET" in
    bridge) NETDEV="tap,id=net0,vhost=on,helper=$BRIDGE_HELPER --br=virbr0" ;;
    user) NETDEV="user,id=net0" ;;
    *) echo "NET must be bridge or user" >&2; exit 1 ;;
esac
# Fresh overlays every run: stalled trace boots leave dirty guest state, and an overlay
# goes stale as soon as the original VM is booted and its base image changes.
if pgrep -f "file=$ULTMOS/HDD.qcow2" >/dev/null; then
    echo "The original ULTMOS VM is running; refusing to start the trace VM on top of its disk." >&2
    exit 1
fi
rm -f "$RUN_DIR/hdd-overlay.qcow2" "$RUN_DIR/oc-overlay.qcow2"
"$QEMU_IMG" create -q -f qcow2 -F qcow2 -b "$ULTMOS/HDD.qcow2" "$RUN_DIR/hdd-overlay.qcow2"
# OC_IMAGE=path: boot another OpenCore image (raw or qcow2), e.g. a test copy with changed settings
if [ -n "${OC_IMAGE:-}" ]; then
    OC_FMT=$(case "$OC_IMAGE" in *.raw) echo raw ;; *) echo qcow2 ;; esac)
    "$QEMU_IMG" create -q -f qcow2 -F "$OC_FMT" -b "$OC_IMAGE" "$RUN_DIR/oc-overlay.qcow2"
else
    "$QEMU_IMG" create -q -f qcow2 -F qcow2 -b "$ULTMOS/boot/OpenCore.qcow2" "$RUN_DIR/oc-overlay.qcow2"
fi
cp "$ULTMOS/ovmf/OVMF_VARS.fd" "$RUN_DIR/OVMF_VARS.fd"

# GDB=1: run under gdb in batch mode so a crash leaves a backtrace in the console log
# (GDB_CMDS=file: extra gdb commands, e.g. breakpoints, run before starting)
LAUNCH=("$QEMU")
if [ "${GDB:-0}" = 1 ]; then
    LAUNCH=(gdb -q -batch -ex "handle SIGUSR1 SIGPIPE nostop noprint" ${GDB_CMDS:+-x "$GDB_CMDS"} -ex run -ex "thread apply all bt 12" --args "$QEMU")
fi

exec "${LAUNCH[@]}" \
    -name pvg-trace \
    -enable-kvm -m 8G \
    -object memory-backend-memfd,id=ram0,size=8G,share=on \
    -machine q35,memory-backend=ram0 \
    -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off \
    -cpu Haswell-noTSX,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,-pcid,check \
    -smp threads=2,cores=4,sockets=1 \
    $USB_ARGS \
    -device isa-applesmc,osk="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc" \
    -drive if=pflash,format=raw,readonly=on,file="$ULTMOS/ovmf/OVMF_CODE.fd" \
    -drive if=pflash,format=raw,file="$RUN_DIR/OVMF_VARS.fd" \
    -smbios type=2 \
    -device ich9-ahci,id=sata \
    -drive id=OpenCore,if=none,format=qcow2,file="$RUN_DIR/oc-overlay.qcow2" \
    -drive id=HDD,if=none,format=qcow2,file="$RUN_DIR/hdd-overlay.qcow2" \
    -device ide-hd,bus=sata.2,drive=OpenCore,bootindex=1 \
    -device ide-hd,bus=sata.3,drive=HDD,rotation_rate=1 \
    -netdev "$NETDEV" -device virtio-net-pci,netdev=net0,id=net0,mac=00:16:cb:00:21:09 \
    $VGA_ARGS \
    -device pcie-root-port,id=rp1,bus=pcie.0,chassis=1,slot=1 \
    -device "pvg-linux-pci,id=pvg0,bus=rp1${PVG_PROPS:+,$PVG_PROPS}" \
    ${TRACE_DISPLAY:--display none -vnc 127.0.0.1:5} \
    -monitor unix:"$SOCK_DIR/monitor.sock",server,nowait \
    -qmp unix:"$SOCK_DIR/qmp.sock",server,nowait \
    -msg timestamp=on $SERIAL_ARGS $TRACE_ARGS -D "$ROOT/logs/pvg-trace-$STAMP.log" \
    ${EXTRA_ARGS:-}
