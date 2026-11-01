#!/usr/bin/env bash
# Build and install the guest sharing agent (VMShare.app) over ssh; run on the host while the VM is up.
#   scripts/vm-share/install-guest.sh user@guest-ip   (or GUEST=user@guest-ip)
# Windows host (Git Bash), user networking: run-pvg-vm.ps1 -SshPort 2222, then
#   SSH_PORT=2222 scripts/vm-share/install-guest.sh user@127.0.0.1
# (without ssh: scripts/vm-share/install-guest.ps1, a transfer disk).
# Copies VMShare.swift, guest/install.sh and the host's share token into the guest and runs
# install.sh there: it compiles the agent with the guest's swiftc into ~/Applications/VMShare.app
# and installs a LaunchAgent so it starts at login (restarted if it exits).
# Uninstall in the guest: launchctl bootout gui/$(id -u)/com.kvm-osx.vmshare; rm -r
#   ~/Library/LaunchAgents/com.kvm-osx.vmshare.plist ~/Applications/VMShare.app "~/Library/Application Support/VMShare"
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
GUEST="${1:-${GUEST:-}}"
[ -n "$GUEST" ] || { echo "usage: $0 user@guest-ip (the guest's login and address, e.g. from NET=bridge)" >&2; exit 2; }
KEY="${SSH_KEY:-$HOME/.ssh/macos-vm}"
PORT="${SSH_PORT:-22}"
SSH=(ssh -p "$PORT" -o ConnectTimeout=5 -o BatchMode=yes -i "$KEY" "$GUEST")

TOKEN=$("${PYTHON:-python3}" "$D/kvm-share.py" token)
"${SSH[@]}" 'mkdir -p "$HOME/Library/Application Support/VMShare"'
scp -q -P "$PORT" -o BatchMode=yes -i "$KEY" "$D/guest/VMShare.swift" "$D/guest/install.sh" \
    "$GUEST:Library/Application Support/VMShare/"
printf '%s\n' "$TOKEN" | "${SSH[@]}" 'umask 077; cat > "$HOME/Library/Application Support/VMShare/token"'
"${SSH[@]}" 'sh "$HOME/Library/Application Support/VMShare/install.sh"'
