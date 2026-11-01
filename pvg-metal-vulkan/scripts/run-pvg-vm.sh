#!/usr/bin/env bash
# Boot the ULTMOS macOS VM with the paravirtual GPU (pvg-linux-pci, Metal on the host GPU via
# Vulkan) instead of qxl-vga. This is the everyday launcher; scripts/run-trace-vm.sh is the
# headless tracing variant.
#
# By default it uses the VM's real disks (HDD, OpenCore, OVMF vars) like ULTMOS's boot.sh does.
# OVERLAY=1 boots throwaway copy-on-write overlays instead (nothing the guest does is kept).
#
# Environment:
#   DISPLAY_MODE=gtk|gtk-gl|sdl|sdl-gl|dbus|vnc|none   window type (default dbus + qemu-rdw viewer on Wayland,
#                              gtk-gl if the viewer isn't built, gtk on X11; gtk-gl: OpenGL window, frames
#                              stay on the GPU - QEMU's GL windows stay black on this host
#                              for any VM (X11 + NVIDIA EGL); vnc = 127.0.0.1:5901, no window)
#   OVERLAY=1                  test mode on overlays in re/vm/
#   RAM=8G CORES=8 THREADS=1   guest size (defaults follow ULTMOS boot.sh's RAM, 8 cores)
#   USB=ehci                   keyboard/tablet on EHCI like ULTMOS (default xHCI)
#   NET=bridge|user            network: libvirt NAT bridge virbr0 + vhost-net (default once
#                              'sudo scripts/setup-bridge-net.sh' has been run) or QEMU user-mode
#                              (slirp: QUIC/UDP stalls, e.g. YouTube in Safari with Private Relay)
#   AUDIO=pa|sdl|alsa|none     host audio backend for the guest's sound output (default pa: PulseAudio,
#                              or PipeWire's PulseAudio server). The guest gets a USB audio device,
#                              which macOS drives natively (no kext); HDA and virtio-sound need one.
#                              Output only: QEMU's USB audio device has no input.
#   PVG_PROPS=...              extra pvg-linux-pci properties (e.g. gpu-validation=on)
#   VIEWER=path                D-Bus display viewer (default tools/qemu-display/target/release/qemu-rdw)
#   QEMU_EXTRA="..."           extra QEMU arguments (e.g. -debugcon file:x -global isa-debugcon.iobase=0x402)
#   TRACE_EVENTS=file          QEMU trace events (log in logs/)
#   QEMU=path                  QEMU binary (default: the development build in src/qemu/build;
#                              re/stable/qemu-system-x86_64 is a frozen known-good copy)
#   SHARE=0                    no clipboard / file sharing with the guest (default on: starts
#                              scripts/vm-share/kvm-share.py; the guest needs its agent once:
#                              scripts/vm-share/install-guest.sh). Drop files on the VM window to
#                              copy them to the guest's ~/Downloads.
#   GPU_PERF=1                 NVIDIA: PowerMizer "Prefer Maximum Performance" while the VM runs
#                              (restored on exit). The guest's small, bursty GPU work otherwise
#                              keeps the GPU in P5/P8 and roughly halves the frame rate.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# the ULTMOS VM: the ultimate-macOS-KVM checkout this folder sits in (pvg-metal-vulkan/ in its root),
# else one next to this folder
if [ -z "${ULTMOS:-}" ]; then
    if [ -f "$ROOT/../main.py" ]; then ULTMOS="$(cd "$ROOT/.." && pwd)"
    else ULTMOS="$(cd "$ROOT/.." && pwd)/ultimate-macOS-KVM"; fi
fi
QEMU="${QEMU:-$ROOT/src/qemu/build/qemu-system-x86_64}"
QEMU_IMG="$ROOT/src/qemu/build/qemu-img"
ROM="$ROOT/re/collected/collected/frameworks/ParavirtualizedGraphics.framework/Versions/A/Resources/AppleParavirtEFI.rom"
RUN_DIR="$ROOT/re/vm"
# UNIX socket paths must be < 108 bytes: keep the sockets out of the (long) project path
SOCK_DIR="${XDG_RUNTIME_DIR:-/tmp}/kvm-osx"
STAMP="$(date +%Y%m%d-%H%M%S)"

[ -x "$QEMU" ] || { echo "build QEMU first: ninja -C src/qemu/build qemu-system-x86_64" >&2; exit 1; }
[ -f "$ROM" ] || { echo "missing AppleParavirtEFI.rom (guest collect step): $ROM" >&2; exit 1; }
if pgrep -f "file=$ULTMOS/HDD.qcow2" >/dev/null || pgrep -f "file=$RUN_DIR/hdd-overlay.qcow2" >/dev/null; then
    echo "another VM is using the disk (the ULTMOS VM or a trace VM); stop it first" >&2
    exit 1
fi

mkdir -p "$SOCK_DIR" "$RUN_DIR" "$ROOT/logs"
if [ "${OVERLAY:-0}" = 1 ]; then
    rm -f "$RUN_DIR/hdd-overlay.qcow2" "$RUN_DIR/oc-overlay.qcow2"
    "$QEMU_IMG" create -q -f qcow2 -F qcow2 -b "$ULTMOS/HDD.qcow2" "$RUN_DIR/hdd-overlay.qcow2"
    "$QEMU_IMG" create -q -f qcow2 -F qcow2 -b "$ULTMOS/boot/OpenCore.qcow2" "$RUN_DIR/oc-overlay.qcow2"
    cp "$ULTMOS/ovmf/OVMF_VARS.fd" "$RUN_DIR/OVMF_VARS.fd"
    HDD="$RUN_DIR/hdd-overlay.qcow2"; OC="$RUN_DIR/oc-overlay.qcow2"; VARS="$RUN_DIR/OVMF_VARS.fd"
else
    HDD="$ULTMOS/HDD.qcow2"; OC="$ULTMOS/boot/OpenCore.qcow2"; VARS="$ULTMOS/ovmf/OVMF_VARS.fd"
fi

# default on Wayland: D-Bus display + qemu-rdw viewer (~29 fps, 8 ms; gtk-gl ~25 fps, gtk ~11),
# gtk-gl when the viewer isn't built. X11 + NVIDIA EGL GL windows stay black here: plain gtk.
VIEWER="${VIEWER:-$ROOT/tools/qemu-display/target/release/qemu-rdw}"
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    DEFAULT_DISPLAY=gtk
elif [ -x "$VIEWER" ]; then
    DEFAULT_DISPLAY=dbus
else
    DEFAULT_DISPLAY=gtk-gl
    echo "note: $VIEWER not built, using gtk-gl (see README to build qemu-rdw)" >&2
fi
DISPLAY_MODE="${DISPLAY_MODE:-$DEFAULT_DISPLAY}"
if [ "$DISPLAY_MODE" = dbus ] && [ ! -x "$VIEWER" ]; then
    echo "DISPLAY_MODE=dbus needs the qemu-rdw viewer ($VIEWER); set VIEWER= or build it" >&2
    exit 1
fi
case "$DISPLAY_MODE" in
    gtk) DISPLAY_ARGS="-display gtk,zoom-to-fit=off" ;;
    gtk-gl) DISPLAY_ARGS="-display gtk,gl=on,zoom-to-fit=off" ;;   # frames as dmabufs (no copies)
    sdl) DISPLAY_ARGS="-display sdl" ;;
    sdl-gl) DISPLAY_ARGS="-display sdl,gl=on" ;;
    dbus) DISPLAY_ARGS="-display dbus,gl=on" ;;    # QEMU has no window: qemu-rdw (started below) shows it
    vnc) DISPLAY_ARGS="-display none -vnc 127.0.0.1:1" ;;
    none) DISPLAY_ARGS="-display none" ;;   # headless (tests; screendump via the monitor)
    *) echo "DISPLAY_MODE must be gtk, gtk-gl, sdl, sdl-gl, dbus, vnc or none" >&2; exit 1 ;;
esac
if [ "${USB:-xhci}" = ehci ]; then USB_ARGS="-usb -device usb-kbd -device usb-tablet"; else
    USB_ARGS="-device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0"; fi
case "${AUDIO:-pa}" in
    none) AUDIO_ARGS="" ;;
    pa|sdl|alsa)
        if [ "${USB:-xhci}" = ehci ]; then AUDIO_BUS=""; else AUDIO_BUS=",bus=xhci.0"; fi
        AUDIO_ARGS="-audiodev ${AUDIO:-pa},id=snd0 -device usb-audio,audiodev=snd0$AUDIO_BUS" ;;
    *) echo "AUDIO must be pa, sdl, alsa or none" >&2; exit 1 ;;
esac
if [ -n "${TRACE_EVENTS:-}" ]; then TRACE_ARGS="-trace events=$TRACE_EVENTS -D $ROOT/logs/pvg-vm-$STAMP.log"; else TRACE_ARGS=""; fi
RAM="${RAM:-8G}"
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

OLD_MODE=; VIEWER_PID=; SHARE_PID=
cleanup() {       # keeps QEMU's exit status
    local rc=$?
    if [ -n "$SHARE_PID" ]; then kill "$SHARE_PID" 2>/dev/null || true; fi
    if [ -n "$VIEWER_PID" ]; then kill "$VIEWER_PID" 2>/dev/null || true; fi   # may be closed already
    if [ -n "$OLD_MODE" ]; then nvidia-settings -a "[gpu:0]/GpuPowerMizerMode=$OLD_MODE" >/dev/null; fi
    return $rc
}
if [ "${GPU_PERF:-0}" = 1 ] && command -v nvidia-settings >/dev/null; then
    OLD_MODE=$(nvidia-settings -t -q "[gpu:0]/GpuPowerMizerMode" 2>/dev/null || echo 2)
    nvidia-settings -a "[gpu:0]/GpuPowerMizerMode=1" >/dev/null
fi
if [ "${SHARE:-1}" = 1 ]; then
    # clipboard + file sharing daemon (reused if one is already running); drops on the window
    # reach it through QEMU_GTK_DROP_SOCKET (gtk / gtk-gl displays, qemu-rdw)
    export QEMU_GTK_DROP_SOCKET="$SOCK_DIR/share.sock"
    if ! python3 "$ROOT/scripts/vm-share/kvm-share.py" status >/dev/null 2>&1; then
        python3 "$ROOT/scripts/vm-share/kvm-share.py" daemon >> "$ROOT/logs/kvm-share.log" 2>&1 &
        SHARE_PID=$!
    fi
fi
if [ "$DISPLAY_MODE" = dbus ]; then
    # waits until QEMU is on the session bus; closing the viewer leaves the VM running
    # (reconnect with: $VIEWER "macOS (pvg)"); the viewer is closed when QEMU exits
    "$VIEWER" --wait "macOS (pvg)" > "$ROOT/logs/qemu-rdw.log" 2>&1 &
    VIEWER_PID=$!
fi
if [ -n "$OLD_MODE$VIEWER_PID$SHARE_PID" ]; then
    trap cleanup EXIT
    RUN=("$QEMU")       # not exec: cleanup runs when QEMU exits
else
    RUN=(exec "$QEMU")
fi

"${RUN[@]}" \
    -name "macOS (pvg)" \
    -enable-kvm -m "$RAM" \
    -object memory-backend-memfd,id=ram0,size="$RAM",share=on \
    -machine q35,memory-backend=ram0 \
    -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off \
    -cpu Haswell-noTSX,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,-pcid,check \
    -smp threads="${THREADS:-1}",cores="${CORES:-8}",sockets=1 \
    $USB_ARGS $AUDIO_ARGS \
    -device isa-applesmc,osk="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc" \
    -drive if=pflash,format=raw,readonly=on,file="$ULTMOS/ovmf/OVMF_CODE.fd" \
    -drive if=pflash,format=raw,file="$VARS" \
    -smbios type=2 \
    -device ich9-ahci,id=sata \
    -drive id=OpenCore,if=none,format=qcow2,file="$OC" \
    -drive id=HDD,if=none,format=qcow2,file="$HDD" \
    -device ide-hd,bus=sata.2,drive=OpenCore,bootindex=1 \
    -device ide-hd,bus=sata.3,drive=HDD,rotation_rate=1 \
    -netdev "$NETDEV" -device virtio-net-pci,netdev=net0,id=net0,mac=00:16:cb:00:21:09 \
    -vga none \
    -device pcie-root-port,id=rp1,bus=pcie.0,chassis=1,slot=1 \
    -device "pvg-linux-pci,id=pvg0,bus=rp1,gpu=on,exec=on,romfile=$ROM${PVG_PROPS:+,$PVG_PROPS}" \
    $DISPLAY_ARGS \
    -monitor unix:"$SOCK_DIR/pvg-vm-monitor.sock",server,nowait \
    -qmp unix:"$SOCK_DIR/pvg-vm-qmp.sock",server,nowait \
    -msg timestamp=on $TRACE_ARGS ${QEMU_EXTRA:-}
