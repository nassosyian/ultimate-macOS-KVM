#!/usr/bin/env bash
# Boot the headless trace VM, press Enter at the OpenCore picker, and wait until the
# newest trace log matches PATTERN (or TIMEOUT seconds pass), then wait EXTRA more seconds.
# The VM keeps running afterwards; stop it with: scripts/vm-monitor.sh quit
# Usage: scripts/trace-boot.sh PATTERN [TIMEOUT=300] [EXTRA=20] [pvg-linux-pci props]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATTERN="$1"; TIMEOUT="${2:-300}"; EXTRA="${3:-20}"; PROPS="${4:-}"

if pgrep -f -- '-name pvg-trace' >/dev/null; then
    "$ROOT/scripts/vm-monitor.sh" quit >/dev/null 2>&1
    for _ in $(seq 30); do pgrep -f -- '-name pvg-trace' >/dev/null || break; sleep 1; done
    # older VMs whose monitor socket was replaced, or that ignore quit
    for p in $(pgrep -x qemu-system-x86); do
        grep -qa -- 'pvg-trace' "/proc/$p/cmdline" 2>/dev/null && kill -9 "$p"
    done
fi
before="$(ls -t "$ROOT"/logs/pvg-trace-*.log 2>/dev/null | head -1)"
setsid nohup "$ROOT/scripts/run-trace-vm.sh" $PROPS > "$ROOT/logs/vm-console.log" 2>&1 < /dev/null &
for _ in $(seq 30); do
    log="$(ls -t "$ROOT"/logs/pvg-trace-*.log 2>/dev/null | head -1)"
    [ -n "$log" ] && [ "$log" != "$before" ] && break
    sleep 1
done
sleep 14
"$ROOT/scripts/vm-monitor.sh" "sendkey ret" >/dev/null
for _ in $(seq "$TIMEOUT"); do
    grep -qE "$PATTERN" "$log" 2>/dev/null && break
    pgrep -f -- '-name pvg-trace' >/dev/null || { echo "VM exited"; cat "$ROOT/logs/vm-console.log"; exit 1; }
    sleep 1
done
sleep "$EXTRA"
echo "$log"
