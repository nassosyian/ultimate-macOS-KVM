# Clipboard and file sharing (host ⇄ macOS guest)

Host daemon `kvm-share.py` (Python + GTK 3) and a guest menu-bar agent `guest/VMShare.swift`, connected over TCP port 7329 on the VM network. Works on Linux and Windows 10/11 hosts. The guest connects to the host: 192.168.122.1 with `NET=bridge` on Linux and with `run-pvg-vm.ps1` on Windows (user networking with the bridge's addresses), or 10.0.2.2 with `NET=user`. A token in `~/.config/kvm-osx/share-token` (Windows: `%USERPROFILE%\.config\kvm-osx\share-token`) authenticates it.

| | host → guest | guest → host |
|---|---|---|
| text, images | copy → paste (both together when the source offers both) | same |
| files / folders (clipboard) | copy in Nemo/Nautilus/Explorer → paste in Finder | copy in Finder → paste on the host (other apps get paths) |
| drag and drop | drop on the VM window → guest `~/Downloads`, shown in Finder | drop on the ⇄ menu-bar icon (or its "Send Files to Host…") → host `~/Downloads` |
| command line | `scripts/vm-share/kvm-share.py send FILE...` | — |

## Setup

1. The launcher starts the daemon: `scripts/run-pvg-vm.sh` (`SHARE=0` turns it off) or, on Windows, `scripts\run-pvg-vm.ps1` (`-NoShare`). Its log is `logs/kvm-share.log`. On Windows it runs under MSYS2's Python (PyGObject) and its control socket is `tcp:127.0.0.1:7330` (Windows Python has no unix sockets).
2. Install the guest agent once. Both ways run `guest/install.sh` in the guest, which compiles the agent with the guest's `swiftc` (Xcode command line tools) into `~/Applications/VMShare.app` and adds a LaunchAgent:
   - over ssh, while the VM is running: `scripts/vm-share/install-guest.sh user@guest-ip` (key `~/.ssh/macos-vm`; on Windows start the VM with `-SshPort 2222` and use `SSH_PORT=2222 ... user@127.0.0.1`);
   - Windows, without ssh: `scripts\vm-share\install-guest.ps1` boots the VM with a small `VMSHARE` disk; in macOS run `sh /Volumes/VMSHARE/install.sh`.

   If macOS asks whether VMShare may find devices on your local network, choose Allow. The agent has to be an app bundle: macOS's Local Network privacy refuses its connections to the host (`EHOSTUNREACH`, logged in `~/Library/Logs/VMShare.log`) when a bare binary is started by launchd. Agents installed before this change worked only until the next login: reinstall them.
3. Dropping files on the VM window works in QEMU's GTK window (patch 0084; on Windows over TCP, patch 0089). It also works in qemu-rdw on Wayland once `patches/qemu-display/0001-*` is applied and rebuilt, which needs `libgtk-4-dev`. Both read `QEMU_GTK_DROP_SOCKET`, which the launchers set.

## Limits

- **Dragging out of the VM window is impossible.** A drag can't leave the guest's screen, so guest → host drops go through the menu-bar icon.
- **Copied files are transferred when copied, not when pasted.** Clipboard file copies are capped at 1 GiB; drag-and-drop has no cap.
- **Symbolic links inside folders are skipped.** This includes the framework symlinks inside .app bundles.
- **Wayland host clipboard:** GNOME doesn't let a background program watch the clipboard. There, host → guest copying works only where the compositor allows it. X11 (Cinnamon) and Windows are fine.
- **Windows:** no desktop notifications for received files (they land in `Downloads`); file drops need the GTK window (`-DisplayMode gtk`, the default).
- **macOS paste prompt:** macOS may ask once whether VMShare may read the clipboard ("Paste from other apps"). Choose Allow.

## Tests (offline, private Xvfb display; the real clipboard and folders are not touched)

- `scripts/vm-share/test-host.py`: the daemon against a fake guest.
- `scripts/vm-share/test-drop.py`: an XDND drop on a paused QEMU GTK window.
