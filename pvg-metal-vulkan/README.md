# pvg-metal-vulkan

Metal hardware acceleration for a macOS (Tahoe, x86_64) guest under QEMU/KVM on a Linux host, or
QEMU/WHPX on a Windows 10/11 host (see [Windows host](#windows-host)), with a Vulkan GPU. A new QEMU
device, `pvg-linux-pci`, reimplements the host side of Apple's ParavirtualizedGraphics (PCI
`106b:eeee`, the device the guest's `AppleParavirtGPU.kext` drives). The guest's Metal command
buffers are executed on the host GPU: AIR shaders are translated to SPIR-V (`air2spv`), and render,
compute and blit work is replayed with Vulkan 1.3.

Status: login window and desktop, wallpaper (VideoToolbox YCbCr kernels), Liquid Glass
materials, Spotlight, System Settings/Dock icons, Safari, Maps, Photos and Chess (SceneKit 3D) render.
It is tested on an RTX 3060 Ti, on Linux and on Windows 10 (Windows 10/11 setup: [docs/windows.md](docs/windows.md)).

## Disclaimer

This was all written by Claude Opus 5.5 (high).  
**USE AT YOUR OWN RISK**

## Requirements

- A Linux host with KVM, or a Windows 10/11 host with the Windows Hypervisor Platform, and a
  Vulkan 1.3 GPU. Only NVIDIA (RTX 3060 Ti, proprietary driver) has been tested.
- LLVM 19 or newer and Vulkan development files (`llvm-config`, `vulkan/vulkan.h`, the loader),
  plus QEMU's usual build dependencies (ninja, python3, glib2, pixman, libslirp, gtk3, SDL2, epoxy).
- macOS Tahoe (26), x86_64, installed with ultimate-macOS-KVM (ULTMOS). The guest fixups match the
  tested Tahoe build.
- dosfstools and mtools for the one-time ROM collection.

## Layout

| Path | What |
|------|------|
| `patches/` | the QEMU changes, as `git format-patch` files on top of QEMU v11.1.3 |
| `scripts/build-qemu.sh` | clones QEMU, applies the patches and builds it into `src/qemu/build` (Linux, or MSYS2 UCRT64 on Windows) |
| `scripts/collect-rom.sh`, `collect-rom.ps1` | one-time copy of the PVG option ROM out of the guest (Linux, Windows) |
| `scripts/run-pvg-vm.sh`, `run-pvg-vm.ps1` | boots the ULTMOS VM with the paravirtual GPU (Linux, Windows) |
| `setup-windows.cmd` (`scripts/setup-windows.ps1`) | guided Windows setup, see [docs/windows.md](docs/windows.md) |
| `scripts/` | also trace/capture tools and `a2s-check` (offline shader translation check) |
| `guest/collect.sh` | runs in the guest, copies the PVG framework (and optionally more) to the transfer disk |

After `build-qemu.sh`, the device sources are in `src/qemu/hw/display/pvg-linux-pci.c` (the PCI
device: FIFOs, tasks, display, EFI framebuffer) and `src/qemu/hw/display/pvg/` (`pvg-exec.c`:
Metal command buffer executor on Vulkan; `air2spv.c`: AIR (Metal shader bitcode) to SPIR-V
translator; `pvg-guest-fixups.c`: guest-memory patches for Tahoe x86 Metal bugs, see below).

## Build

```sh
scripts/build-qemu.sh            # JOBS=N to limit parallel compile jobs
```

It clones QEMU v11.1.3 into `src/qemu`, applies `patches/*.patch` with `git am`, configures
(`--target-list=x86_64-softmmu --enable-kvm --enable-slirp --enable-vnc --enable-opengl --enable-gtk
--enable-sdl --enable-download --disable-docs --disable-werror`) and builds with ninja. It stops if
Vulkan or LLVM is not found: without them the device builds as a stub. Later runs only rebuild;
delete `src/qemu` to start over.

## Collect the option ROM (once)

The device needs Apple's PVG option ROM, `AppleParavirtEFI.rom`: it provides the firmware
framebuffer for the OpenCore picker and boot.efi. It is part of the guest's
ParavirtualizedGraphics.framework and is not distributed here; copy it out of your own guest:

```sh
scripts/collect-rom.sh
```

This creates a FAT32 transfer disk (`re/transfer/transfer.img`, label PVGXFER, sparse) holding
`guest/collect.sh` and boots the normal ULTMOS VM (its `boot.sh`, stock graphics) with the disk
attached. In macOS, open Terminal, run

```sh
sh /Volumes/PVGXFER/collect.sh rom
```

and shut the VM down. The script then copies the framework to `re/collected/`, where
`run-pvg-vm.sh` looks for the ROM. `re/` is never committed. Without `rom`, `collect.sh` also
copies the PVG kexts and the x86_64 dyld shared cache (several GB, only needed for reverse
engineering).

## Run

The guest disk is an existing ULTMOS VM. When this folder sits inside an ultimate-macOS-KVM
checkout (`pvg-metal-vulkan/` in its root) that checkout is used; otherwise an
`ultimate-macOS-KVM` checkout next to this folder. Set `ULTMOS=` to use another location. The
launcher uses the VM's own disks (`HDD.qcow2`, `boot/OpenCore.qcow2`, `ovmf/`).

```sh
scripts/run-pvg-vm.sh                    # real VM disks; Wayland: D-Bus display + qemu-rdw viewer
                                         # (gtk-gl if qemu-rdw isn't built), X11: GTK window
DISPLAY_MODE=gtk-gl scripts/run-pvg-vm.sh   # GTK OpenGL window (Wayland)
DISPLAY_MODE=sdl-gl scripts/run-pvg-vm.sh   # SDL OpenGL window (Wayland)
```

The viewer (`tools/qemu-display/target/release/qemu-rdw`) is started and closed by the launcher.
Closing its window leaves the VM running; reconnect with `qemu-rdw "macOS (pvg)"`. To build it
(needs `usbredir`), clone https://gitlab.com/marcandre.lureau/qemu-display into `tools/`, remove
`features = ["bindings"]` from the unix `rdw` dependency in `qemu-rdw/Cargo.toml` (otherwise it
needs a system-wide librdw4) and run `cargo build --release -p qemu-rdw`.

```sh
OVERLAY=1 DISPLAY_MODE=vnc scripts/run-pvg-vm.sh   # throwaway overlays, VNC on 127.0.0.1:5901
```

`GPU_PERF=1 scripts/run-pvg-vm.sh` sets the NVIDIA PowerMizer mode to "Prefer Maximum Performance"
while the VM runs and restores the previous mode when it exits. The guest's small, bursty GPU work
otherwise leaves the GPU in a low power state, which costs about a third of the frame rate.

Audio: the guest gets a QEMU USB audio device, which macOS drives with its built-in USB audio
class driver (Intel HDA and virtio-sound need third-party kexts). Sound goes to the host through
PulseAudio, or PipeWire's PulseAudio server, by default. `AUDIO=sdl` or `AUDIO=alsa` selects
another backend, and `AUDIO=none` disables audio. QEMU's USB audio device is output-only (no
microphone).

Network: QEMU's user-mode network (slirp) stalls on QUIC/UDP, which Safari uses for iCloud Private
Relay. After a one-time `sudo scripts/setup-bridge-net.sh`, the launchers attach the VM to libvirt's
NAT bridge `virbr0` with vhost-net instead (the guest gets a 192.168.122.x address). `NET=user`
forces slirp.

The launcher refuses to start while another VM uses the same disk. The monitor socket is
`re/vm/pvg-vm-monitor.sock`.

Device properties (`PVG_PROPS=`):
- `gpu=on`, `exec=on`: execute on the host GPU (the default in the launcher).
- `gpu-validation=on`: Vulkan validation layer. It is very slow; use it for short runs only.
- `guest-fixups=off`: disable the guest patch.
- `damage-limit=off`: always upload / write back whole attachments (default: only the rectangle a
  pass draws into).
- `msaa=off`: render multisample passes single-sampled into their resolve texture.
- `async=off`: execute command buffers in the doorbell's MMIO handler (under QEMU's global
  lock) instead of on the executor thread.
- `early-complete=off`: wait for every command buffer to finish on the GPU. By default, command
  buffers whose results the guest cannot see (no write-back) complete as soon as they are
  submitted and their inputs are copied.
- `private-resident=off`: write back private (GPU-only) textures after every pass like other
  textures (default: they stay on the GPU and are written back only when the guest needs them).
- `zero-copy=off`: copy textures and buffers between guest RAM and the GPU with the CPU. By
  default guest RAM is imported into Vulkan (`VK_EXT_external_memory_host`) and the GPU copies
  them itself. This keeps all of guest RAM resident and pinned on the host while the VM runs
  (8 GiB for the default `RAM=8G`). It is off automatically with `dump-dir`.
- `rebar=off`: with zero-copy and a GPU with resizable BAR enabled (all of VRAM CPU-visible),
  small uploads (up to 64 KiB: vertex and uniform buffers) are CPU writes straight into VRAM.
  This turns that off.
- `upload-cache=on`: keep textures on the GPU while KVM dirty logging shows their guest pages
  unchanged (experimental; no gain measured; superseded by `resource-flags`).
- `resource-flags=off`: upload every texture a command buffer uses. By default a texture equal
  to the guest's copy is reused until the guest reports a CPU write to it (the resource flags of
  `ExecIndirect2` and `InvalidateResources`, as Apple's host uses them).
- `share-surfaces=off`: separate host images per texture object. By default all textures of an
  IOSurface (plane and view shape) share one host image, in every task.
- `async-cmds=off`: run task commands (Map/Unmap, Delete*, SetObjectList, Invalidate/Synchronize)
  on the vCPU after draining the executor thread (default: on the executor thread, in order).
- `async-visible=off`: wait for command buffers whose results the guest sees. By default they
  complete when the GPU is done, without holding up the executor thread.
- `irqfd=off`: completion interrupts from QEMU's main loop instead of a KVM irqfd.
- `dmabuf=off`: with a GL display (`DISPLAY_MODE=gtk-gl`), copy frames into the console
  surface instead of handing the display the GPU image.
- `defer-writeback=on`: keep rendered surfaces on the GPU until the guest asks for them
  (experimental: some cross-process content is lost).
- Environment: `PVG_FRAMES=2..4` command buffers recorded ahead of the GPU (default 3);
  `PVG_NO_DISK_CACHE=1` disables the shader caches in `~/.cache/pvg`.
- `dump-dir=DIR`: dump shaders and command buffers, and allow frame capture with `echo N > DIR/capture`.

## Guest fixup

On Tahoe x86, `AppleParavirtGPUMetal.bundle` does not implement `-[MTLDevice targetDeviceArchitecture]`.
Every process that loads an `MTLBinaryArchive` therefore aborts in
`+[MTLLoader sliceIDForDevice:legacyDriverVersion:airntDriverVersion:]`: iconservicesagent, Spotlight,
and Dock extras crash-loop. The device patches the branch into that assertion (and the assertion
itself) in guest RAM. The loader then sees no matching archive slice and the shaders are compiled
from source. The guest disk is never modified.

The code is in the dyld shared cache, which is compressed and sealed on disk, and its page is first
read in by the very call that aborts, so a RAM scan alone loses that race (one crash per boot,
placeholder icons in apps open at that moment). With KVM or WHPX the device therefore finds the cache's
per-boot slide from a vCPU's page tables and sets an instruction breakpoint on the branch: the
first process to reach it gets the page patched before the instruction runs. The RAM scan remains
as a fallback. The signatures and the branch address belong to the tested Tahoe build.

A second fixup covers `-[MTLIOAccelDevice newIndirectArgumentEncoderWithLayout:]`: the base
class only calls `abort()`, and the paravirtual GPU plugin does not override it (it reports no
argument buffer support), yet VFX (for example the Games app's animated icons) asks for an
argument encoder anyway. The method is patched to return nil, and callers carry on without an
encoder.

## Known limitations

- Frame rate is limited by the executor pipeline: command buffers wait 5-9 ms in the worker's
  queue (see TODO.md). On Windows the guest itself also runs slower under WHPX (~18-20 against
  ~25-29 presents/s in Mission Control).
- Atomics, SIMD-group operations, indirect draws/dispatches and MSAA are implemented, but no
  captured workload uses them yet; they are only tested offline (shader translation) or by the
  validation layer.
- Shared/managed textures (IOSurfaces) are uploaded and written back for every command buffer:
  the guest does not signal CPU writes to them, and the dirty-logging cache (`upload-cache=on`)
  costs about what it saves.
- No argument buffers (Apple's x86 paravirtual Metal plugin implements none): VFX effects that need
  them do not draw, and Blender 4.x (argument buffers tier 2, barycentrics, Metal 2.2 family)
  crashes at start.
- System Settings -> Desktop & Dock rarely crashes (SIGBUS in Metal while it decodes the
  wallpaper preview); not reproducible on demand.

## Windows host

Tested on Windows 10 22H2 (19045), Ryzen 9 5950X, RTX 3060 Ti (driver 617.42): the desktop renders
through the paravirtual GPU, with the guest fixups. The accelerator is WHPX (Hyper-V) instead of KVM;
patches 0085-0093 make that work for macOS:

- **CPUID** (0085): WHPX answered the cache/topology leaves (2, 4, 5, 0x80000005/6) from the host;
  with the Intel CPU model on an AMD host leaf 4 was empty and macOS divided by zero in
  `cpu_thread_alloc`. They now come from the CPU model, as under KVM.
- **MSRs** (0086, needs `-accel whpx,intercept-msr-gp=on`): Hyper-V on AMD faults on the 64-bit
  SYSENTER MSR writes of macOS's early CPU setup, and on Intel-only MSRs (`IA32_MISC_ENABLE`).
  These are emulated; other faulting MSRs read 0 and ignore writes (KVM's `ignore_msrs`).
- **Guest fixup breakpoints** (0087): an accelerator-neutral host breakpoint API. Under WHPX the
  breakpoints use the guest's own debug registers (#DB exits; re-armed every 2 s, since the guest
  can overwrite them).
- **Build** (0088): configure works without symlink privilege (Developer Mode off).
- **File drops** (0089): `QEMU_GTK_DROP_SOCKET=tcp:HOST:PORT`.
- **Mouse pointer** (0090): Windows stretches cursor images to the square system cursor size but
  keeps the hotspot; the guest's 32x64 arrow is now put on a square canvas (clicks landed left of
  the tip).
- **Testing** (0091): `PVG_FIXUPS_NO_SCAN=1` applies the guest fixups through breakpoints only
  (verified under WHPX: "patched (breakpoint, hit #1)").
- **SDL with OpenGL** (0092, 0093): `-display sdl,gl=on` no longer assumes EGL (Windows has WGL),
  SDL cursors get the same square canvas, and the device needs no dmabuf on Windows.

Use the APIC in QEMU (`kernel-irqchip=off`, the default of `run-pvg-vm.ps1`): with Hyper-V's APIC
macOS fails to start its other CPUs ("Failed to start CPU 01"), and with x2APIC hidden it boots but
extremely slowly. No dmabuf scanout on Windows
(presents take the CPU path); the upload cache (`upload-cache=on`, off by default) gains nothing
under WHPX, which reports all RAM dirty; zero-copy guest RAM import works. Displays, Mission
Control toggles, 32 s windows: `gtk`, `sdl` (SDL with OpenGL) and headless all ~18-20 presents/s (Linux: gtk 10.8, gtk-gl 25,
dbus 29). `gtk` stays the default (file drops, menus). `gtk,gl=on` crashes (QEMU's GtkGLArea code
needs EGL and a GL context on any thread; Windows has WGL) and SDL's 2D renderer hangs at startup,
so `run-pvg-vm.ps1 -DisplayMode sdl` means `sdl,gl=on`. `qxl-vga` is not built (no SPICE);
`-NoPvg` uses `VGA`.

**Setup: double-click `setup-windows.cmd`.** It checks the PC, enables the Windows Hypervisor
Platform, installs MSYS2 and the build packages, builds QEMU, copies or creates the macOS VM
(downloading and installing macOS Tahoe if needed), gets the PVG option ROM, installs the sharing
agent and creates a desktop shortcut, asking before each step and skipping what is done.
**[docs/windows.md](docs/windows.md)** is the full guide: requirements, every step and its manual
equivalent, running the VM, updating, troubleshooting.

Guest networking is QEMU's user mode with the libvirt bridge's addresses (`192.168.122.0/24`, host
`192.168.122.1`, where the sharing agent looks first). Clipboard / file sharing works as on Linux:
`kvm-share.py` runs under MSYS2's Python (control socket `tcp:127.0.0.1:7330`, drops on the GTK
window). Install the guest agent once with `scripts\vm-share\install-guest.ps1` (boots the VM with a
small disk; in macOS run `sh /Volumes/VMSHARE/install.sh`), or `install-guest.sh` over ssh
(`-SshPort`). The agent is now an app bundle (`~/Applications/VMShare.app`): macOS's Local Network
privacy refuses connections to the host (`EHOSTUNREACH`) from a bare binary started by launchd,
which is what the earlier install was (it only worked until the next login; reinstall on Linux
too). The Linux-only tools (`trace-boot.sh`, `bench-pvg.sh`, `setup-*.sh`, qemu-rdw, ...) are not
ported.

## License

GPL-3.0 (see `LICENSE`), like ultimate-macOS-KVM. The QEMU patches are derived from QEMU and
remain under GPL-2.0-or-later, QEMU's license.
