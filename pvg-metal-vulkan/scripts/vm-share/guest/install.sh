#!/bin/sh
# Build and install the guest sharing agent (VMShare.app) and its LaunchAgent; runs in the guest.
# Expects VMShare.swift and token next to it: scripts/vm-share/install-guest.sh copies them over
# ssh, scripts/vm-share/install-guest.ps1 puts them on a transfer disk (sh /Volumes/VMSHARE/install.sh).
# Needs swiftc (Xcode command line tools: xcode-select --install).
#
# An app bundle, not a bare binary: macOS's Local Network privacy blocks connections to the host
# (EHOSTUNREACH) for a process launchd starts, unless it is a bundle with
# NSLocalNetworkUsageDescription, which can ask once (click Allow).
set -eu
SRC="$(cd "$(dirname "$0")" && pwd)"
S="$HOME/Library/Application Support/VMShare"
APP="$HOME/Applications/VMShare.app"
ID=com.kvm-osx.vmshare

mkdir -p "$S" "$HOME/Library/Logs" "$APP/Contents/MacOS"
if [ "$SRC" != "$S" ]; then
    cp "$SRC/VMShare.swift" "$S/"
    if [ -f "$SRC/token" ]; then (umask 077; tr -d '\r' < "$SRC/token" > "$S/token"); fi
fi
[ -s "$S/token" ] || { echo "no token in $S/token (kvm-share.py token on the host)" >&2; exit 1; }

swiftc -O -o "$S/VMShare.new" "$S/VMShare.swift" -framework AppKit
mv "$S/VMShare.new" "$APP/Contents/MacOS/VMShare"
rm -f "$S/VMShare"      # the bare binary of older installs
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>VMShare</string>
  <key>CFBundleExecutable</key><string>VMShare</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>VMShare connects to the virtual machine's host for clipboard and file sharing.</string>
</dict>
</plist>
PL
codesign --force -s - --identifier "$ID" "$APP"

PLIST="$HOME/Library/LaunchAgents/$ID.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$ID</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/VMShare</string></array>
  <key>AssociatedBundleIdentifiers</key><string>$ID</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/VMShare.log</string>
</dict>
</plist>
PL
U=$(id -u)
launchctl bootout "gui/$U/$ID" 2>/dev/null || true
launchctl bootstrap "gui/$U" "$PLIST"
sleep 2
launchctl print "gui/$U/$ID" | grep -E "state =|pid =" | head -2
tail -3 "$HOME/Library/Logs/VMShare.log" 2>/dev/null || true
echo "installed: the arrows icon is in the menu bar. If macOS asks whether VMShare may find"
echo "devices on your local network, click Allow."
