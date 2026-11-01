#!/usr/bin/env bash
# Record host memory every 10 s (top processes by RSS, kernel counters, per-process VRAM) into
# logs/mem-recorder-<time>.log until stopped. Run it while the VM runs to see what fills memory.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/logs/mem-recorder-$(date +%Y%m%d-%H%M%S).log"
echo "recording to $OUT"
while :; do
    {
        echo "=== $(date +%T)"
        grep -E "MemAvailable|SwapFree|AnonPages|Shmem:|Unevictable|SUnreclaim|VmallocUsed|KernelStack|PageTables" /proc/meminfo | tr -s ' ' | paste -sd' '
        ps -eo pid,rss,comm --sort=-rss | sed -n 2,7p | awk '{printf "  %s %d MiB %s\n",$1,$2/1024,$3}'
        nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null | sed 's/^/  vram /'
        nvidia-smi --query-gpu=memory.used --format=csv,noheader 2>/dev/null | sed 's/^/  vram total /'
    } >> "$OUT"
    sleep 10
done
