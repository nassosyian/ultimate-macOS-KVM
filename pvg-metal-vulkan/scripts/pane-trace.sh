#!/usr/bin/env bash
# Boot the trace VM with pvg properties $2, open a System Settings pane through Spotlight
# ($3, default "Wallpaper"), trace the executor for 40 s and summarise private flushes.
#   scripts/pane-trace.sh TAG ["props"] ["Pane name"]
# Output: logs/pane-TAG.txt and logs/pane-TAG.png
cd "$(dirname "$0")/.."
TAG=${1:?tag}; PROPS=${2:-}; PANE=${3:-Wallpaper}; OUT=logs/pane-$TAG.txt
EV=$(mktemp); printf '%s\n' pvg_linux_exec pvg_linux_exec_time pvg_linux_exec_private pvg_linux_exec_zc pvg_linux_exec_alloc > "$EV"
TRACE_EVENTS=$EV NO_VGA=1 scripts/run-trace-vm.sh "$PROPS" > logs/vm-console.log 2>&1 &
sleep 4; L=$(ls -t logs/pvg-trace-*.log | head -1)
for _ in $(seq 80); do grep -q "kernel VTMTSComputeFunction" "$L" && break; sleep 3; done; sleep 30
scripts/vm-monitor.sh "sendkey meta_l-spc" >/dev/null; sleep 1.5
scripts/guest-type.sh "$PANE"; sleep 2
scripts/vm-monitor.sh "sendkey ret" >/dev/null; sleep 10
n=$(wc -l < "$L"); sleep 40
scripts/vm-monitor.sh "screendump $PWD/logs/pane-$TAG.png -f png"
{
  echo "flushes by reason/shape:"
  tail -n +"$n" "$L" | grep "priv flush" | cut -c28- | sed 's/va 0x[0-9a-f]*/va X/' | sort | uniq -c | sort -rn | head -12
  tail -n +"$n" "$L" | grep -E "exec_private|exec_time|exec_zc|exec_alloc" | cut -c28-260 | tail -6
} > "$OUT"
scripts/vm-monitor.sh quit >/dev/null 2>&1; wait; rm -f "$EV"
cat "$OUT"
