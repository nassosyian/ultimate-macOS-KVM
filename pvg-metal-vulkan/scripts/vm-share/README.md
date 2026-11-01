# Clipboard and file sharing (host ⇄ macOS guest)

Host daemon `kvm-share.py` (Python + GTK 3) and a guest menu-bar agent `guest/VMShare.swift`, connected over TCP port 7329 on the VM network. The guest connects to the host: 192.168.122.1 with `NET=bridge`, or 10.0.2.2 with `NET=user`. A token in `~/.config/kvm-osx/share-token` authenticates it.

| | host → guest | guest → host |
|---|---|---|
| text, images | copy → paste (both together when the source offers both) | same |
| files / folders (clipboard) | copy in Nemo/Nautilus → paste in Finder | copy in Finder → paste in Nemo/Nautilus (other apps get paths) |
| drag and drop | drop on the VM window → guest `~/Downloads`, shown in Finder | drop on the ⇄ menu-bar icon (or its "Send Files to Linux…") → host `~/Downloads` |
| command line | `scripts/vm-share/kvm-share.py send FILE...` | — |

## Setup

1. `scripts/run-pvg-vm.sh` starts the daemon (`SHARE=0` turns it off). Its log is `logs/kvm-share.log`.
2. Install the guest agent once, while the VM is running: `scripts/vm-share/install-guest.sh`. It needs the ssh key `~/.ssh/macos-vm`. It compiles the agent in the guest and adds a LaunchAgent.
3. Dropping files on the VM window works in QEMU's GTK window (patch 0084). It also works in qemu-rdw on Wayland once `patches/qemu-display/0001-*` is applied and rebuilt, which needs `libgtk-4-dev`. Both read `QEMU_GTK_DROP_SOCKET`, which `run-pvg-vm.sh` sets.

## Limits

- **Dragging out of the VM window is impossible.** A drag can't leave the guest's screen, so guest → host drops go through the menu-bar icon.
- **Copied files are transferred when copied, not when pasted.** Clipboard file copies are capped at 1 GiB; drag-and-drop has no cap.
- **Symbolic links inside folders are skipped.** This includes the framework symlinks inside .app bundles.
- **Wayland host clipboard:** GNOME doesn't let a background program watch the clipboard. There, host → guest copying works only where the compositor allows it. X11 (Cinnamon) is fine.
- **macOS paste prompt:** macOS may ask once whether VMShare may read the clipboard ("Paste from other apps"). Choose Allow.

## Tests (offline, private Xvfb display; the real clipboard and folders are not touched)

- `scripts/vm-share/test-host.py`: the daemon against a fake guest.
- `scripts/vm-share/test-drop.py`: an XDND drop on a paused QEMU GTK window.
