#!/usr/bin/env bash
# Boot the trace VM with extra pvg-linux-pci properties, run the Mission Control frame-rate test
# twice and summarise the executor's timing (medians per 500 command buffers).
#
#   scripts/bench-pvg.sh TAG ["pvg properties"]     e.g. scripts/bench-pvg.sh nobar rebar=off
#
# Writes logs/bench-TAG.txt (raw lines + summary) and logs/bench-TAG.png (desktop screenshot).
# Runs headless (VNC on localhost); needs the disk to be free (no other VM on it).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TAG=${1:?usage: bench-pvg.sh TAG [props]}
PROPS=${2:-}
OUT=logs/bench-$TAG.txt
EVENTS=$(mktemp)
printf '%s\n' pvg_linux_present pvg_linux_fps pvg_linux_exec_time pvg_linux_exec_stats \
    pvg_linux_exec_private pvg_linux_exec_zc pvg_linux_exec_alloc pvg_linux_exec_cache pvg_linux_exec_latency pvg_linux_exec_waits pvg_linux_exec_stats pvg_linux_present_shown \
    pvg_linux_exec > "$EVENTS"

TRACE_EVENTS=$EVENTS NO_VGA=1 scripts/run-trace-vm.sh "$PROPS" > logs/vm-console.log 2>&1 &
VM=$!
sleep 4
# the monitor socket is shared by all trace VMs: never go on without our own VM
kill -0 "$VM" 2>/dev/null || { echo "VM did not start:"; cat logs/vm-console.log; exit 1; }
L=$(ls -t logs/pvg-trace-*.log | head -1)
for _ in $(seq 100); do
    grep -q "kernel VTMTSComputeFunction\|executor disabled" "$L" && break
    kill -0 "$VM" 2>/dev/null || { echo "VM exited during boot"; exit 1; }
    sleep 3
done
sleep 35
scripts/vm-monitor.sh "screendump $ROOT/logs/bench-$TAG.png -f png"
n=$(wc -l < "$L")
{ scripts/fps-test.sh; scripts/fps-test.sh; } > "$OUT"
tail -n +"$n" "$L" | grep -E "exec_time|exec_zc|exec_alloc|exec_cache|exec_latency|exec_waits|exec_stats|GPU submit failed" | cut -c28-300 >> "$OUT"
grep -E "zero-copy: guest|unavailable|executor disabled|GPU submit failed" "$L" | cut -c28-240 | head -3 >> "$OUT"
scripts/vm-monitor.sh quit >/dev/null 2>&1
wait
rm -f "$EVENTS"
python3 -I - "$OUT" "$L" <<'EOF' | tee -a "$OUT"
import re, statistics as st, sys
L = open(sys.argv[1]).read().splitlines()
pat = r"exec (\d+) ms of (\d+) ms wall, slowest (\d+) us; guest read (\d+) ms (\d+) MiB, write (\d+) ms (\d+) MiB, gpu wait (\d+)"
ex = [list(map(int, m.groups())) for m in (re.search(pat, l) for l in L) if m][1:]
if ex:
    print("summary (medians per 500 cmdbufs): " + "  ".join(
        f"{n} {st.median([x[j] for x in ex])}" for n, j in
        (("exec_ms", 0), ("wall_ms", 1), ("slowest_us", 2), ("cpu_read_ms", 3),
         ("cpu_write_ms", 5), ("gpu_wait_ms", 7))))
sh = [int(m.group(1)) for m in (re.search(r"present_shown rows \d+-\d+, (\d+) us", l)
                                  for l in open(sys.argv[2], errors="replace")) if m]
if sh:
    print(f"present latency (Transaction3 -> shown): median {st.median(sh)} us, "
          f"mean {int(st.mean(sh))} us, n {len(sh)}")
EOF
