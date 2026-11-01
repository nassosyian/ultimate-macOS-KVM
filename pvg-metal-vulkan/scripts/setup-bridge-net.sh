#!/usr/bin/env bash
# One-time host setup (run with sudo) so the VM can use libvirt's NAT bridge (virbr0) with
# vhost-net instead of QEMU's user-mode network (slirp). slirp stalls on QUIC/UDP, which Safari
# uses for iCloud Private Relay and YouTube.
#
#   sudo scripts/setup-bridge-net.sh
#
# What it changes:
#   - /usr/lib/qemu/qemu-bridge-helper becomes setuid root (via dpkg-statoverride, so package
#     upgrades keep it). The helper creates the VM's tap device and attaches it to an allowed
#     bridge on behalf of the unprivileged QEMU process.
#   - /etc/qemu/bridge.conf allows virbr0 (and only virbr0).
#   - libvirt's "default" network (virbr0, 192.168.122.0/24, NAT) is started and set to autostart.
set -euo pipefail

HELPER=/usr/lib/qemu/qemu-bridge-helper
BRIDGE=virbr0

[ "$(id -u)" = 0 ] || { echo "run with sudo: sudo $0" >&2; exit 1; }
[ -x "$HELPER" ] || { echo "$HELPER not found (package qemu-system-common)" >&2; exit 1; }

if ! dpkg-statoverride --list "$HELPER" >/dev/null 2>&1; then
    dpkg-statoverride --update --add root root 4755 "$HELPER"
else
    chmod 4755 "$HELPER"
fi

mkdir -p /etc/qemu
if ! grep -qx "allow $BRIDGE" /etc/qemu/bridge.conf 2>/dev/null; then
    echo "allow $BRIDGE" >> /etc/qemu/bridge.conf
fi
chmod 644 /etc/qemu/bridge.conf

if command -v virsh >/dev/null; then
    virsh -c qemu:///system net-start default 2>/dev/null || true
    virsh -c qemu:///system net-autostart default >/dev/null
fi

ls -l "$HELPER"
echo "/etc/qemu/bridge.conf:"; cat /etc/qemu/bridge.conf
ip -br addr show "$BRIDGE"
echo "done: scripts/run-pvg-vm.sh now uses the bridge (NET=user to go back to slirp)"
