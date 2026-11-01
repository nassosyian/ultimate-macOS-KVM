#!/usr/bin/env bash
# Click the login password field (USB tablet, absolute 0..32767) and type dummy keys, then take
# screendumps at intervals. Never types a real password. Usage: scripts/login-type-test.sh OUTPREFIX [KEYS]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$1"; KEYS="${2:-q w e}"
M="$ROOT/scripts/vm-monitor.sh"
"$M" "screendump ${OUT}-0.png -f png" >/dev/null
"$M" "mouse_move $((960 * 32767 / 1920)) $((981 * 32767 / 1080))" >/dev/null; sleep 1
"$M" "mouse_button 1" >/dev/null; sleep 0.2; "$M" "mouse_button 0" >/dev/null; sleep 2
for k in $KEYS; do "$M" "sendkey $k" >/dev/null; sleep 0.4; done
for t in 1 3 6 12; do sleep "$t"; "$M" "screendump ${OUT}-${t}.png -f png" >/dev/null; done
