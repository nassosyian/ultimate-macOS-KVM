#!/usr/bin/env bash
# Drag a window by its title bar for ~20 s (frame-rate test under load). Coordinates are 1920x1080
# screen pixels of the title bar to grab. Usage: scripts/drag-window-test.sh [X Y]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/scripts/vm-monitor.sh"
X="${1:-1100}"; Y="${2:-50}"
abs() { echo $(( $1 * 32767 / $2 )); }
"$M" "mouse_move $(abs $X 1920) $(abs $Y 1080)" >/dev/null; sleep 0.5
"$M" "mouse_button 1" >/dev/null
for i in $(seq 0 79); do
    dx=$(( (i % 40) < 20 ? (i % 20) * 15 : (20 - i % 20) * 15 ))
    "$M" "mouse_move $(abs $((X - dx)) 1920) $(abs $((Y + dx / 3)) 1080)" >/dev/null
    sleep 0.25
done
"$M" "mouse_button 0" >/dev/null
