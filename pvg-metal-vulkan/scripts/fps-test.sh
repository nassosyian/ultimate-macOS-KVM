#!/usr/bin/env bash
# Toggle Mission Control for ~16 s and report presents per second from the trace (trace VM).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L=$(ls -t "$ROOT"/logs/pvg-trace-*.log | head -1)
start=$(date -u +%Y-%m-%dT%H:%M:%S)
python3 -I - "${XDG_RUNTIME_DIR:-/tmp}/kvm-osx/monitor.sock" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.setblocking(False)
for i in range(8):
    s.sendall(b"sendkey ctrl-up\n" if i % 2 == 0 else b"sendkey ctrl-down\n")
    time.sleep(2)
    try:
        while s.recv(65536): pass
    except BlockingIOError: pass
PY
sleep 1
awk -v t="$start" '$1 >= t' "$L" | grep -c "pvg_linux_present " | awk '{printf "presents in 16 s: %d (%.1f/s)\n", $1, $1/16}'
