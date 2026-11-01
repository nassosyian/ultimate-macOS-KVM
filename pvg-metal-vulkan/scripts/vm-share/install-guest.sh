#!/usr/bin/env bash
# Build and install the guest sharing agent (VMShare) over ssh; run on the host while the VM is up.
#   scripts/vm-share/install-guest.sh user@guest-ip   (or GUEST=user@guest-ip)
# Copies VMShare.swift and the host's share token into the guest, compiles it with the guest's
# swiftc, and installs a LaunchAgent so it starts at login (restarted if it exits).
# Uninstall in the guest: launchctl bootout gui/$(id -u)/com.kvm-osx.vmshare;
#   rm -r ~/Library/LaunchAgents/com.kvm-osx.vmshare.plist "~/Library/Application Support/VMShare"
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
GUEST="${1:-${GUEST:-}}"
[ -n "$GUEST" ] || { echo "usage: $0 user@guest-ip (the guest's login and address, e.g. from NET=bridge)" >&2; exit 2; }
KEY="${SSH_KEY:-$HOME/.ssh/macos-vm}"
SSH=(ssh -o ConnectTimeout=5 -o BatchMode=yes -i "$KEY" "$GUEST")

TOKEN=$(python3 "$D/kvm-share.py" token)
"${SSH[@]}" 'mkdir -p "$HOME/Library/Application Support/VMShare" "$HOME/Library/Logs"'
scp -q -o BatchMode=yes -i "$KEY" "$D/guest/VMShare.swift" "$GUEST:Library/Application Support/VMShare/"
printf '%s\n' "$TOKEN" | "${SSH[@]}" 'umask 077; cat > "$HOME/Library/Application Support/VMShare/token"'
"${SSH[@]}" bash -s <<'EOF'
set -euo pipefail
S="$HOME/Library/Application Support/VMShare"
cd "$S"
swiftc -O -o VMShare.new VMShare.swift -framework AppKit
mv VMShare.new VMShare
PLIST="$HOME/Library/LaunchAgents/com.kvm-osx.vmshare.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.kvm-osx.vmshare</string>
  <key>ProgramArguments</key><array><string>$S/VMShare</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/VMShare.log</string>
</dict>
</plist>
PL
U=$(id -u)
launchctl bootout "gui/$U/com.kvm-osx.vmshare" 2>/dev/null || true
launchctl bootstrap "gui/$U" "$PLIST"
sleep 2
launchctl print "gui/$U/com.kvm-osx.vmshare" | grep -E "state =|pid =" | head -2
tail -3 "$HOME/Library/Logs/VMShare.log" 2>/dev/null || true
EOF
echo "installed; the arrows icon is in the guest's menu bar"
