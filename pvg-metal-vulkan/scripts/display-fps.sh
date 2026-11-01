#!/usr/bin/env bash
# Frame rate of one display mode: boot run-pvg-vm.sh on overlays, toggle Mission Control for
# 16 s (twice) and count guest presents and frames shown on the display, then quit.
#
#   scripts/display-fps.sh MODE        MODE = a run-pvg-vm.sh DISPLAY_MODE (gtk, gtk-gl, sdl-gl, dbus)
#
# Opens a window (foreground; in dbus mode run-pvg-vm.sh starts the qemu-rdw viewer).
# Writes logs/display-fps-MODE.txt (summary + latency median of shown frames).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODE=${1:?usage: display-fps.sh MODE}
MON="${XDG_RUNTIME_DIR:-/tmp}/kvm-osx/pvg-vm-monitor.sock"
OUT=logs/display-fps-$MODE.txt
EVENTS=$(mktemp)
printf '%s\n' pvg_linux_present pvg_linux_present_shown > "$EVENTS"

mon() {
    python3 -I - "$MON" "$@" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.setblocking(False)
for cmd in sys.argv[2:]:
    s.sendall(cmd.encode() + b"\n")
    time.sleep(2)
    try:
        while s.recv(65536): pass
    except BlockingIOError: pass
PY
}

ulimit -c 0   # dbus mode can crash at exit (NVIDIA GL thread): no multi-GB cores
trap 'rm -f "$EVENTS"' EXIT
for try in 1 2 3; do
    OVERLAY=1 NET=user DISPLAY_MODE=$MODE TRACE_EVENTS=$EVENTS GDK_BACKEND=wayland \
        SDL_VIDEODRIVER=wayland scripts/run-pvg-vm.sh > "logs/display-fps-$MODE-console.log" 2>&1 &
    VM=$!
    sleep 4
    kill -0 "$VM" 2>/dev/null || { echo "VM did not start:"; cat "logs/display-fps-$MODE-console.log"; exit 1; }
    L=$(ls -t logs/pvg-vm-*.log | head -1)
    # firmware hang (seen ~1 in 4 boots): the guest never writes its disk overlay
    sleep 90
    [ "$(stat -c %s re/vm/hdd-overlay.qcow2)" -gt 1000000 ] && break
    VM_MONITOR="$MON" scripts/vm-monitor.sh "info registers" 2>/dev/null |
        grep -q 'RIP=\(ffffff80\|00007ff\)' && break    # in the macOS kernel / user space
    D=logs/boot-hang-$(date +%Y%m%d-%H%M%S).txt
    echo "boot hang (try $try): no disk writes after 90 s -> $D"
    for c in "info registers -a" "info pci" "x/64wx 0" "info mtree -f"; do
        echo "== $c"; VM_MONITOR="$MON" scripts/vm-monitor.sh "$c"
    done > "$D" 2>&1
    grep -c "" "$L" >> "$D"
    mon "quit"; wait "$VM" 2>/dev/null
    [ "$try" = 3 ] && { echo "giving up after 3 hangs"; exit 1; }
done

# desktop up: presents keep arriving for 20 s
for _ in $(seq 40); do
    a=$(grep -c "pvg_linux_present " "$L"); sleep 20; b=$(grep -c "pvg_linux_present " "$L")
    [ "$b" -gt "$a" ] && [ "$a" -gt 0 ] && break
    kill -0 "$VM" 2>/dev/null || { echo "VM exited during boot"; exit 1; }
done
sleep 10

{
    # GTK follows the monitor's refresh rate (none when a sleeping DP monitor drops off)
    echo "mode $MODE ($(date -Iseconds)), host outputs: $(wayland-info 2>/dev/null | grep -c wl_output)"
    for run in 1 2; do
        p0=$(grep -c "pvg_linux_present " "$L"); s0=$(grep -c "pvg_linux_present_shown" "$L")
        mon "sendkey ctrl-up" "sendkey ctrl-down" "sendkey ctrl-up" "sendkey ctrl-down" \
            "sendkey ctrl-up" "sendkey ctrl-down" "sendkey ctrl-up" "sendkey ctrl-down"
        sleep 1
        p1=$(grep -c "pvg_linux_present " "$L"); s1=$(grep -c "pvg_linux_present_shown" "$L")
        lat=$(tail -n +"$((s0 + 1))" <(grep "pvg_linux_present_shown" "$L") |
              grep -o '[0-9]* us after' | awk '{print $1}' | sort -n |
              awk '{a[NR]=$1} END {print NR ? a[int((NR + 1) / 2)] : "-"}')
        awk -v r="$run" -v p=$((p1 - p0)) -v s=$((s1 - s0)) -v l="$lat" 'BEGIN {
            printf "run %d: presents %d (%.1f/s), shown %d (%.1f/s), median latency %s us\n",
                   r, p, p / 16, s, s / 16, l }'
    done
} | tee "$OUT"
mon "quit"
wait "$VM" 2>/dev/null
