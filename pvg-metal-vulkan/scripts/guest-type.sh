#!/usr/bin/env bash
# Type a string into the trace VM through the QEMU monitor (USB keyboard, US layout).
# "\n" in the string presses Return. Usage: scripts/guest-type.sh 'ls -l ~\n'
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOCK="${VM_MONITOR:-${XDG_RUNTIME_DIR:-/tmp}/kvm-osx/monitor.sock}"
keys=()
s="$(printf '%b.' "$1")"; s="${s%.}"   # keep trailing newlines
for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
        [a-z0-9]) k="$c" ;;
        [A-Z]) k="shift-${c,}" ;;
        ' ') k=spc ;; $'\n') k=ret ;; $'\t') k=tab ;;
        -) k=minus ;; _) k=shift-minus ;; =) k=equal ;; +) k=shift-equal ;;
        .) k=dot ;; '>') k=shift-dot ;; ,) k=comma ;; '<') k=shift-comma ;;
        /) k=slash ;; '?') k=shift-slash ;; ';') k=semicolon ;; :) k=shift-semicolon ;;
        "'") k=apostrophe ;; '"') k=shift-apostrophe ;; '`') k=grave_accent ;; '~') k=shift-grave_accent ;;
        '\') k=backslash ;; '|') k=shift-backslash ;; '[') k=bracket_left ;; ']') k=bracket_right ;;
        '{') k=shift-bracket_left ;; '}') k=shift-bracket_right ;;
        '!') k=shift-1 ;; '@') k=shift-2 ;; '#') k=shift-3 ;; '$') k=shift-4 ;; '%') k=shift-5 ;;
        '^') k=shift-6 ;; '&') k=shift-7 ;; '*') k=shift-8 ;; '(') k=shift-9 ;; ')') k=shift-0 ;;
        *) echo "guest-type: no key for '$c'" >&2; continue ;;
    esac
    keys+=("$k")
done
# one monitor connection for the whole string (vm-monitor.sh costs ~2 s per command)
printf 'sendkey %s\n' "${keys[@]}" | python3 -I -c '
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.setblocking(False)

def drain():
    # read the monitor echo and prompt: unread output stalls QEMU after about 40 keys
    try:
        while s.recv(65536):
            pass
    except BlockingIOError:
        pass

for line in sys.stdin:
    s.sendall(line.encode())
    time.sleep(0.15)   # sendkey holds 100 ms; faster overflows the USB keyboard queue
    drain()
time.sleep(0.3)
drain()
' "$SOCK"
