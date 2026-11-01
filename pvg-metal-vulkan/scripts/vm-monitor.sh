#!/usr/bin/env bash
# Send one HMP command to the trace VM's monitor, e.g.:
#   scripts/vm-monitor.sh "screendump /path/shot.png -f png"
#   scripts/vm-monitor.sh "info pci"
set -euo pipefail
SOCK="${VM_MONITOR:-${XDG_RUNTIME_DIR:-/tmp}/kvm-osx/monitor.sock}"
printf '%s\n' "$1" | python3 -I -c '
import re, socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall(sys.stdin.read().encode()); time.sleep(1.5); s.settimeout(0.5)
out = b""
try:
    while True:
        d = s.recv(65536)
        if not d: break
        out += d
except socket.timeout:
    pass
txt = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", out.decode(errors="replace")).replace("\r", "")
lines = [l for l in txt.split("\n")[2:] if not l.startswith("(qemu)")]
print("\n".join(lines).strip())
' "$SOCK"
