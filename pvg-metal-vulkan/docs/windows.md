# Running pvg-metal-vulkan on Windows

This guide sets up a macOS Tahoe virtual machine on a Windows 10 or 11 PC, with Metal graphics
running on your own GPU through Vulkan. It uses QEMU with the Windows Hypervisor Platform (WHPX)
instead of Linux's KVM.

**Short version:** clone the repository, double-click `pvg-metal-vulkan\setup-windows.cmd`, and
answer its questions. The rest of this page explains what it does, how to run the VM day to day,
and what to do when something goes wrong.

## What you need

| | |
|---|---|
| Windows | Windows 10 version 2004 (build 19041) or newer, or Windows 11; Home works too |
| CPU | 64-bit Intel or AMD with virtualization turned on in the BIOS/UEFI setup (Intel VT-x, AMD SVM). Tested: Ryzen 9 5950X |
| GPU | Vulkan 1.3 with a current driver. Tested: NVIDIA RTX 3060 Ti, driver 617.42. AMD/Intel GPUs are untested |
| RAM | 16 GB or more (the VM uses 8 GB) |
| Disk | ~5 GB for the build, plus the VM: 30-80 GB, on an NTFS drive |
| Internet | to download MSYS2 (~1.5 GB of packages), QEMU's source and, for a new VM, macOS from Apple (~16 GB) |
| Time | first setup: ~45 minutes, plus ~1-2 hours if you install macOS from scratch |

The folder you clone into must not contain spaces (QEMU's build cannot handle them), e.g.
`C:\VMs\ultimate-macOS-KVM` rather than `C:\My VMs\...`.

## 1. Get the code

Install [Git for Windows](https://git-scm.com/download/win) if you do not have it, then in a
command prompt:

```
cd C:\VMs
git clone -c core.autocrlf=false -b pvg-metal-vulkan <repository URL> ultimate-macOS-KVM
```

(`core.autocrlf=false` keeps Unix line endings. If you forget it the setup converts the files for
you.)

## 2. Run the setup

Open `C:\VMs\ultimate-macOS-KVM\pvg-metal-vulkan` in Explorer and double-click
**`setup-windows.cmd`**. It goes through the steps below one by one, shows `[ok]` for what is
already done, and asks before changing anything. You can close it at any point and run it again
later: it continues where it stopped. To only see the status:
`setup-windows.cmd -Status`.

### Step 1: system checks
Windows version, CPU virtualization, RAM, free disk space, the folder path and your GPU's Vulkan
version. A red `[!!]` explains what to fix (most often: virtualization disabled in the BIOS, or
an old GPU driver).

### Step 2: Windows Hypervisor Platform
The setup asks the hypervisor itself whether it is available. If not, it enables the
**Windows Hypervisor Platform** feature (an administrator prompt appears) and asks you to
reboot; run the setup again afterwards. Manual equivalent: *Turn Windows features on or off* →
tick *Windows Hypervisor Platform* → reboot.

WSL2, Docker Desktop and Hyper-V keep working alongside it.

### Step 3: MSYS2 and the build packages
QEMU is built with [MSYS2](https://www.msys2.org)'s compilers. The setup installs MSYS2 with
`winget` into `C:\msys64` (set the `MSYS2_ROOT` environment variable if yours is elsewhere),
updates it and installs the packages: GCC, LLVM, Vulkan headers, GTK, SDL, Python with PyGObject
(for clipboard sharing) and the FAT tools used to exchange files with the guest.

### Step 4: line endings
Checks that the patches and shell scripts have Unix line endings and converts them if Git
changed them.

### Step 5: build QEMU
Runs `scripts/build-qemu.sh` in MSYS2: it downloads QEMU 11.1.3, applies the patches in
`patches/` (the paravirtual GPU device plus the Windows/WHPX fixes 0085-0094) and builds it into
`src\qemu\build`. The first build takes about 20-30 minutes. After a `git pull` that brings new
patches, the setup rebuilds only what changed.

### Step 6: the macOS VM
The VM lives in the ULTMOS folder (the repository root): `HDD.qcow2` (the disk),
`boot\OpenCore.qcow2` (the boot loader) and `ovmf\` (the firmware). You can:

1. **Copy an existing VM**, for example the one you use with ULTMOS on Linux. Give the setup the
   folder with `HDD.qcow2`; it copies the disk, `boot\OpenCore.qcow2` and `ovmf\`. Copy
   OpenCore too: it holds the VM's Mac serial number, which iCloud and your Apple ID know.
2. **Create a new VM and install macOS Tahoe.** The setup creates an empty disk (128 GB by
   default; the file only grows as it fills), downloads Apple's recovery image (~1 GB, the same
   way ULTMOS AutoPilot does), converts it to `BaseSystem.img`, and starts the installer VM:
   1. macOS Recovery appears after about a minute (choose a language if asked).
   2. Open **Disk Utility**, select **QEMU HARDDISK Media** (the empty disk, not *macOS Base
      System*) and **Erase** it: name `macOS`, format **APFS**, scheme **GUID Partition Map**.
      Close Disk Utility.
   3. Choose **Reinstall macOS Tahoe** → Continue → the `macOS` disk. It downloads macOS from
      Apple and restarts several times by itself (if the OpenCore menu waits, pick *macOS
      Installer*, later *macOS*). Then set up macOS and your user account.
   4. At the desktop, shut macOS down (Apple menu → Shut Down).

   If the installation is interrupted, run the setup again: it notices the disk is still almost
   empty and offers to boot the installer again. Afterwards `BaseSystem.img` can be deleted.

### Step 7: the PVG option ROM
The paravirtual GPU needs Apple's `AppleParavirtEFI.rom`, which is part of macOS and not
distributed here. Either:

1. **Collect it from the guest:** the VM starts with plain graphics and a small extra disk. In
   macOS open **Terminal** (Spotlight: Cmd+Space, type Terminal) and run
   `sh /Volumes/PVGXFER/collect.sh rom`, then shut macOS down. The setup copies the ROM out.
2. **Copy it** from another checkout, e.g. a Linux one: `pvg-metal-vulkan\re\collected`.

### Step 8: clipboard and file sharing (optional)
Installs the small *VMShare* agent in macOS: the VM starts with a disk named `VMSHARE`; in
Terminal run `sh /Volumes/VMSHARE/install.sh`. It needs Xcode's command line tools in macOS
(`xcode-select --install` if the script says `swiftc` is missing). If macOS asks whether
*VMShare* may find devices on your local network, click **Allow**. A ⇆ icon appears in the
macOS menu bar.

### Step 9: shortcut and first start
Creates a **macOS (pvg)** shortcut on your desktop and offers to start the VM.

## Running the VM

Double-click the **macOS (pvg)** shortcut, or in PowerShell:

```
powershell -ExecutionPolicy Bypass -File C:\VMs\ultimate-macOS-KVM\pvg-metal-vulkan\scripts\run-pvg-vm.ps1
```

The first boot after a cold start takes 1-2 minutes to the login screen. To stop the VM, shut
macOS down normally (Apple menu → Shut Down); closing the window is like pulling the power plug.

Useful options (all of them are listed at the top of `scripts\run-pvg-vm.ps1`):

| Option | Effect |
|---|---|
| `-DisplayMode sdl` | SDL window with OpenGL instead of GTK: same frame rate, but no file drops and no menu bar |
| `-DisplayMode vnc` | no window; connect a VNC viewer to `127.0.0.1:5901` |
| `-Overlay` | throwaway session: nothing the guest writes is kept |
| `-Ram 12G`, `-Cores 8` | VM size (default 8 GB, 8 cores) |
| `-Audio none` | no sound (default: the guest's sound plays through Windows) |
| `-NoShare` | no clipboard/file sharing |
| `-NoPvg` | plain graphics without the paravirtual GPU (for troubleshooting) |
| `-SshPort 2222` | forwards `127.0.0.1:2222` to the guest's SSH (enable *Remote Login* in macOS) |
| `-SerialLog file.txt` | writes the guest's serial port to a file (kernel log with boot argument `serial=3`) |
| `-Installer` | attaches the macOS installer (`BaseSystem.img` in the repository root), for a new installation; use with `-NoPvg` |
| `-QemuExtra "..."` | extra QEMU arguments |

While the VM runs, QEMU's monitor is reachable with `telnet 127.0.0.1 4444` (e.g. `info status`,
`system_powerdown`).

### Clipboard and files
With the guest agent installed (step 8) and the VM running:

- copy text, images or files on either side and paste on the other;
- drop files from Explorer onto the VM window: they land in the guest's `~/Downloads`;
- in macOS drop files onto the ⇆ menu bar icon (or *Send Files to Host…*): they land in your
  Windows `Downloads` folder.

The Windows side runs automatically with the VM (`scripts\vm-share\kvm-share.py`, log in
`pvg-metal-vulkan\logs\kvm-share.log`).

## Updating

```
cd C:\VMs\ultimate-macOS-KVM
git pull
```

then run `setup-windows.cmd` again: it rebuilds QEMU if new patches arrived and leaves everything
else alone.

## Troubleshooting

**"WHPX: No accelerator found" / the setup keeps asking to enable WHPX.** Reboot after enabling
the feature; check that virtualization is enabled in the BIOS/UEFI setup (Task Manager →
Performance → CPU: *Virtualization: Enabled*; with Hyper-V or WSL2 running, Windows may show
this differently).

**"another VM is using the disk; stop it first".** A QEMU from an earlier run is still running
(maybe without a window). End `qemu-system-x86_64.exe` in Task Manager.

**Stuck at the Apple logo, or the VM restarts in a loop.** Start once with
`-NoPvg -SerialLog C:\temp\serial.txt` to see whether it is graphics related. For a full kernel
log add `-v serial=3` to the boot arguments (ULTMOS's *Boot Argument Assistant*, or
`scripts\whpx-oc-patch.py` in the repository root). `PROGRESS_LOG.md` lists the faults found on
Windows so far.

**The build fails.** Look at the last lines it printed. Common causes: a folder path with spaces,
an interrupted package download (run the setup again), or antivirus software locking files in
`src\qemu\build` (exclude that folder). To start the build from scratch, delete `src\qemu`.

**Clipboard sharing does not connect.** The ⇆ icon in the macOS menu bar shows the state. In
macOS, `cat ~/Library/Logs/VMShare.log` shows the agent's attempts; *No route to host (Local
Network access denied?)* means macOS blocked it: System Settings → Privacy & Security → Local
Network → allow VMShare, or reinstall it (step 8). On Windows, `logs\kvm-share.log`.

**Keys type the wrong characters.** QEMU sends key positions, not characters: set the same
keyboard layout in macOS (System Settings → Keyboard → Input Sources) as on Windows.

**Low frame rate.** Expect ~18-20 frames/s in animations (Mission Control) on Windows, against
~25-29 on Linux on the same PC. Measured: the window type (GTK, SDL, none), the CPU copy of each
frame, the interrupt controller, the number of vCPUs and halt polling make no difference; the
gap comes from running under WHPX instead of KVM. What helps a little (~5-10 %): keeping the GPU at full clocks.
NVIDIA Control Panel -> Manage 3D settings -> Program settings -> add
`src\qemuuild\qemu-system-x86_64.exe` -> *Power management mode: Prefer maximum
performance* (the GPU otherwise idles at its lowest clocks between the guest's small frames).

## Limitations on Windows

- No dmabuf scanout: frames are copied through the CPU (Linux displays them directly from the
  GPU); `-display gtk,gl=on` is not supported.
- Frame rate: ~18-20 frames/s in animations, against ~25-29 on Linux on the same PC. Measured and
  ruled out: the display path, interrupt delivery (QEMU's and Hyper-V's interrupt controller give
  the same rate), halt polling, the number of vCPUs; full GPU clocks help a little (see *Low frame
  rate* above). The rest of the gap comes from running under WHPX instead of KVM; its exact cause
  is not identified yet.
- The launcher uses QEMU's interrupt controller (`kernel-irqchip=off`). Hyper-V's (`-IrqChip on`)
  works too since patch 0094, at the same frame rate, but has had less testing.
- macOS on an AMD host runs as an Intel CPU model; Intel-only CPU registers are emulated by the
  Windows patches (0085, 0086).
- Only the tools needed to build and run are ported; the Linux tracing and benchmark scripts are
  not.

Guest apps with known problems (on Linux too):

- **Blender 4.x** crashes at start: its Metal backend needs argument buffers tier 2, barycentric
  coordinates and Metal 2.2 GPU family support, which the paravirtual GPU does not provide, and
  Blender 4.5 has no OpenGL fallback on macOS.
- **System Settings → Desktop & Dock** very rarely closes with *Extension process exited* while it
  loads the wallpaper preview. Opening it again works.

## Manual setup (without the setup script)

The same steps by hand, for reference:

1. Windows features → *Windows Hypervisor Platform* → reboot.
2. Install MSYS2 into `C:\msys64`, open **MSYS2 UCRT64** from the Start menu and run:

   ```sh
   pacman -Syu        # twice if it asks to restart
   pacman -S --needed git base-devel mingw-w64-ucrt-x86_64-{toolchain,meson,ninja,python,python-distlib,glib2,pixman,libslirp,gtk3,SDL2,libepoxy,pkgconf,vulkan-headers,vulkan-loader,llvm,zstd,lzo2,curl,libpng,libjpeg-turbo,python-gobject,gdb} dosfstools mingw-w64-x86_64-mtools
   cd /c/VMs/ultimate-macOS-KVM/pvg-metal-vulkan
   scripts/build-qemu.sh
   ```
3. Put the VM into the repository root: `HDD.qcow2`, `boot\OpenCore.qcow2` and
   `ovmf\OVMF_CODE.fd`, `ovmf\OVMF_VARS.fd` (templates: `resources\oc_store\compat_new\OpenCore.qcow2`,
   `resources\ovmf\`). A new disk: `src\qemu\build\qemu-img.exe create -f qcow2 HDD.qcow2 128G`;
   the installer: `python scripts\dlosx-arg.py --action download -b Mac-AF89B6D9451A490B -m
   00000000000000000 -os latest --disable-progress`, then `qemu-img convert -f dmg -O raw
   BaseSystem.dmg BaseSystem.img`, and boot it with `scripts\run-pvg-vm.ps1 -NoPvg -Installer`.
4. The ROM: `scripts\collect-rom.ps1`, or copy `re\collected` from another checkout.
5. Sharing (optional): `scripts\vm-share\install-guest.ps1`.
6. Run: `scripts\run-pvg-vm.ps1`.

## Uninstalling

Delete the repository folder (the VM disk is in it: keep `HDD.qcow2` if you want your macOS),
the **macOS (pvg)** desktop shortcut, and, if you no longer need them, MSYS2 (*Apps & features*)
and the Windows Hypervisor Platform feature. The setup stores nothing else except the sharing
token in `%USERPROFILE%\.config\kvm-osx` and the shader cache in
`%LOCALAPPDATA%\Microsoft\Windows\INetCache\pvg`.
