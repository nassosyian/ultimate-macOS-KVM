#!/usr/bin/env bash
# One-time host setup (run with sudo) so earlyoom stops picking the VM when something else
# (a compile, rust-analyzer) runs the host out of memory.
#
#   sudo scripts/setup-earlyoom.sh
#
# Why: earlyoom kills the process with the highest badness, which is roughly the largest one.
# With zero-copy the VM keeps all of guest RAM resident (~9 GiB for RAM=8G) from boot, so it is
# always the largest process: a host `cargo check` that adds 4 GB killed it three times.
#
# What it changes in /etc/default/earlyoom (EARLYOOM_ARGS, other options kept):
#   --avoid  QEMU and the desktop (Xorg, cinnamon): -300, so they go last
#   --prefer compilers, linkers and rust-analyzer (they restart; the guest's state does not)
# then restarts earlyoom. A copy of the old file is kept as /etc/default/earlyoom.bak.
set -euo pipefail

CONF=/etc/default/earlyoom
AVOID='^(qemu-system-x86|qemu-system-x86_64|Xorg|cinnamon|muffin|gnome-shell)$'
PREFER='^(rustc|cargo|cc1|cc1plus|clang|ld|ld.lld|mold|rust-analyzer|node)$'

[ "$(id -u)" = 0 ] || { echo "run with sudo: sudo $0" >&2; exit 1; }
[ -f "$CONF" ] || { echo "$CONF not found (is earlyoom installed?)" >&2; exit 1; }

[ -e "$CONF.bak" ] || cp "$CONF" "$CONF.bak"
# drop earlier --avoid/--prefer from the current arguments, keep the rest (e.g. -r 3600)
args=$(sed -n 's/^EARLYOOM_ARGS="\(.*\)"$/\1/p' "$CONF" |
       sed -E "s/--(avoid|prefer) ('[^']*'|[^ ]*)//g; s/  +/ /g; s/^ //; s/ $//")
# Unquoted: systemd splits $EARLYOOM_ARGS at spaces but keeps quote characters (the regexes have
# no spaces). They contain | ^ $: awk takes the line as a value, not as an edit command.
NEW="EARLYOOM_ARGS=\"$args --avoid $AVOID --prefer $PREFER\"" awk '
    /^EARLYOOM_ARGS=/ { print ENVIRON["NEW"]; done = 1; next }
    { print }
    END { if (!done) print ENVIRON["NEW"] }
' "$CONF" > "$CONF.new"
cat "$CONF.new" > "$CONF"
rm -f "$CONF.new"
systemctl restart earlyoom
grep '^EARLYOOM_ARGS=' "$CONF"
systemctl --no-pager --lines=3 status earlyoom | tail -3
