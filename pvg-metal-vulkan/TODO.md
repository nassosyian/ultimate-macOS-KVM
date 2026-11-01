# TODO

## Open (rendering / executor)
- [x] Rebuild QEMU/air2spv against host LLVM 23 (patch 0078; corpus 272/272)
- [x] Boot the macOS guest on the LLVM 23 build (desktop OK)
- [ ] Enable D-Bus display again: needs glib2-devel (gdbus-codegen), then reconfigure
- [x] Wayland GTK gl=on + dmabuf scanout: works (desktop updates)
- [x] SDL gl=on on Wayland: works (earlier failure = monitor asleep, output removed)
- [x] D-Bus display + qemu-rdw viewer on Wayland: works
- [x] Default display on Wayland: dbus + qemu-rdw (launcher starts/stops the viewer)
- [~] D-Bus exit SIGSEGV (NVIDIA thread): teardown before exit added (patch 0080); not reproducible on demand -> watch coredumpctl
- [x] FPS comparison: gtk 11, gtk-gl 25, sdl-gl 25, dbus 29 presents/s -> default gtk-gl on Wayland
- [x] Firmware hang at boot with GTK at 165 Hz: full redraw each 6 ms under BQL (patch 0079)
- [x] VNC keymaps: `ninja update-keymaps`
- [x] SetDepthClipMode (0x6d), SetTriangleFillMode (0x7c): pipeline variants
- [x] Atomics, SIMD-group ops (air2spv; synthetic test), indirect draws/dispatches, real MSAA
      (no captured workload uses them yet: verify when one does — census:
      `grep "not executed\|unhandled" logs/pvg-trace-*.log`)
- [x] Vertex+fragment shaders using the same texture index (vertex bindings at +64)
- [x] Mipmap generation for 3D textures; compressed formats still logged and skipped
- [x] Pipelines without a fragment function (were the remaining failed pipelines)
- [~] Depth clear value read at +32 instead of +28 (everything cleared to 0; forward-Z wgpu/RFinder
      3D drew nothing): fixed in patch 0081, verify with the wgpu_depth probe after a VM restart
- [~] Draws with a base instance / 64-bit draw forms (0x00 0x02 0x04 0x05 0x08 0x0a 0x0b 0x1c 0x1d)
      were unhandled and skipped (wgpu first_instance): patch 0082, verify after a VM restart
- [~] air2spv: phi/select/icmp over private pointers ("unsupported use of private memory
      (opcode 44)", RFinder vs_backdrop and mesh VS): patch 0083, verify after a VM restart

## Host <-> guest sharing (scripts/vm-share)
- [x] Host daemon: clipboard text/images/files both ways, drops, `send`, tests (test-host.py)
- [x] Drops on QEMU's GTK window (patch 0084, test-drop.py)
- [x] Guest agent: installed, live-tested clipboard both ways and host -> guest files; drops both ways confirmed by the user
- [ ] qemu-rdw drops: build after `sudo apt install libgtk-4-dev` (patch in patches/qemu-display/)

## Step 3 — integration with the normal VM
- [x] Fork cleanup: caches, RE notes untracked, home paths, dates, LICENSE, build-qemu.sh, collect-rom.sh
- [x] Fork branch pvg-metal-vulkan (history rewritten into pvg-metal-vulkan/, ULTMOS extras menu entry)
- [ ] User: create the GitHub fork, add it as a remote, push pvg-metal-vulkan
- [x] Fresh-checkout build test of build-qemu.sh (fixed a false failure in its own check)
- [ ] User: real collect-rom.sh run (only dry-run tested)
- [x] Launch script scripts/run-pvg-vm.sh (real disks; OVERLAY=1 test mode; gtk/sdl/vnc)
- [x] README.md: build, run, properties, guest fixup, limitations
- [x] User: try scripts/run-pvg-vm.sh with the real disks (first boot on the real VARS/disk)
- [x] Green Wallpaper/Displays previews (16-bit unorm mipmaps; 4:4:4 IOSurface planes)
- [x] Blank icons on one boot: the first archive load crashed before the RAM scan could patch;
      now patched at a KVM instruction breakpoint (no crash; verified incl. system_reset)
- [ ] Chess corruption while dragging (user's run): not reproduced in the trace VM yet
- [x] GPU mipmap generation (vkCmdBlitImage chain; CPU path kept as fallback): 2x with the
      Wallpaper pane open
- [x] Wallpaper pane private flushes (~290/500 cmdbufs): blur pyramid levels had separate host
      images; now rendered in place in the mip chain (0 flushes); blits flush only what they touch

- [x] Audio: USB audio device + PulseAudio/PipeWire backend in run-pvg-vm.sh (AUDIO=); verified
      (guest default output "QEMU" USB, host stream non-silent, user heard it)

- [x] Network: slirp stalls on QUIC/UDP (Safari + Private Relay: downloads froze at 1 MB) -> virbr0
      bridge + vhost-net (scripts/setup-bridge-net.sh once; NET=bridge|user)
- [x] YouTube in Safari: the "DecodeError" was a missing audio output device (VM without sound);
      plays with run-pvg-vm.sh's USB audio

- [x] Activity Monitor blank rows: >64 textures per render segment were not uploaded

- [x] Weather precipitation map black: 2DMultisample render targets; rint / is_null_texture

- [x] Games app crash: argument-encoder abort stub patched to return nil (guest fixup)
- [ ] Argument buffers are not supported at all (guest plugin + executor): VFX effects that
      need them do not draw

- [x] TV app posters green/magenta: chroma plane of odd-sized 4:2:0 surfaces

## Step 4 — performance
- [~] Async execution done (async=on) but no FPS gain: guest waits per command buffer stamp
- [x] Damage rectangles: attachments upload/write back only what a pass draws (damage-limit)
- [x] Root cause of GPU wait: host GPU stuck in P5/P8 -> launcher GPU_PERF=1 (PowerMizer max perf
      while the VM runs; ~+35% presents/s in the Mission Control test)
- [x] Texture-upload cache with KVM dirty logging: implemented (upload-cache=on) but no gain —
      guest pages physically scattered (1 run/page), high churn; default off (see PROGRESS_LOG)
- [x] Skip write-backs of GPU-only targets: MTLStorageModePrivate textures stay resident
      (private-resident, default on); managed IOSurfaces must still be written back
- [x] Round trips: early completion (no fence wait for ~70% of command buffers) + executor thread
      (async, default on): 11.5 -> 15.3 presents/s in the Mission Control test
- [ ] GPU clocks: GPU_PERF=1 remains opt-in (host-wide setting)
- [x] Queue stalls / allocation churn: retired images pooled (0 queue waits, ~99% image reuse)
- [x] CPU fallbacks: GPU mipmaps; copy blits are rare (8 per ~49k cmdbufs) and stay CPU copies
- [x] Translation cache (SHA-256 of inputs) + VkPipelineCache: 1.3 s hitches gone

- [x] Zero-copy: guest RAM imported into Vulkan, GPU gathers/scatters (zero-copy, default on):
      executor -14%, slowest cmdbuf -37%, CPU guest copies 0; GPU wait +30% (scattered 4 KiB pages)
- [x] Zero-copy follow-ups: regions batched per RAM piece and merged, dirty marking coalesced
- [ ] Guest buffers read in place by shaders: not done (buffers > 1 MiB span scattered pages;
      smaller ones are CPU-written to VRAM through BAR)

## Step 4b — remaining FPS items (all but GPU clocks)
- [x] §9 on-disk shader/pipeline caches (~/.cache/pvg)
- [x] §6 presents on the worker; only changed rows copied; gamma in the BH; GPU-only frames
      read from their image
- [x] §2 upload skipping driven by the guest's resource flags (resource-flags): 17 -> 24 presents/s
- [x] §2 one host image per IOSurface for all tasks (share-surfaces)
- [x] §3 task commands on the worker (async-cmds): no drains on the vCPU, doorbells 2 us
- [x] §1 write-back command buffers complete asynchronously (async-visible, timeline semaphore +
      completion thread); PVG_FRAMES=2..4 recording frames
- [x] §3 irqfd completion interrupts; ioeventfd not needed (doorbells 2 us after async-cmds)
- [x] §5 deferred destruction of pipelines/samplers; suballocator not needed (99% image reuse)
- [~] §6 dmabuf scanout for GL displays: frames verified in the exported images
      (PVG_SCANOUT_CHECK=1); QEMU's GL displays don't work on this host for any VM (GTK gl=on
      black even for bare std VGA; SDL2 2.30 can't create EGL windows) -> retry with a newer
      SDL/QEMU UI, a Wayland session or -display dbus
- [~] §2 deferred write-backs (defer-writeback, default off): app menus / Chess contents lost
- [ ] §7 GPU copy blits: not needed (13 per 78k command buffers)
- [ ] §2 guest buffers read in place: not done (pages scattered; small buffers go through BAR)

## Step 5 — robustness / polish
- [ ] Guest fixup race: the breakpoint needs the shared-cache slide, found only when a vCPU is
      caught in user mode; in a slow (validation) boot it was armed after the first crash
- [x] Device reset (system_reset) verified; executor caches reset; log formatting skipped when tracing off
- [ ] Trim remaining always-on diagnostics (tex_census, display-input logs) once stable
- [ ] Guest fixup: verify signature on other macOS builds; make it data-driven

## Done
- Boot picker without VGA; wallpaper colours; icons; Spotlight; crash loop (guest fixup); perf (cached arena)

## Windows 10 / WHPX host (patches 0085-0089, scripts/*.ps1)
- [x] MSYS2 UCRT64 build (build-qemu.sh: --enable-whpx, symlink-less configure: patch 0088)
- [x] CPUID leaves 2/4/5/0x80000005/6 from the CPU model (patch 0085; was divide error in cpu_thread_alloc)
- [x] SYSENTER / MISC_ENABLE / unknown faulting MSRs emulated (patch 0086, intercept-msr-gp=on);
      the OpenCore sysenter NOP patch (../scripts/whpx-oc-patch.py) is no longer needed
- [x] APIC in QEMU (kernel-irqchip=off): with Hyper-V's APIC "Failed to start CPU 01"
- [x] Desktop with pvg-linux-pci (Vulkan on the Windows NVIDIA driver), guest fixups on
- [x] Host breakpoints under WHPX (patch 0087): armed (slide found), no crash after pausing vCPUs
      for the #DB exit-bitmap change (was WHV_E_INVALID_VP_STATE)
- [x] WHPX breakpoint hit verified: PVG_FIXUPS_NO_SCAN=1 (patch 0091), launching apps ->
      "sliceIDForDevice nil-architecture branch patched (breakpoint, hit #1)" 26 s after arming
- [x] Sharing: was NOT libslirp (nc from the guest's Terminal reaches 192.168.122.1:7329). macOS
      Local Network privacy refused the agent (so_error 65 EHOSTUNREACH, no SYN sent): a bare
      binary started by launchd cannot get the permission; it only worked on Linux because
      install-guest.sh started it from ssh. Now VMShare.app with NSLocalNetworkUsageDescription
      (guest/install.sh), installed on the real disk via install-guest.ps1 (VMSHARE FAT disk).
      Fresh boot: agent connects by itself (58 s); host->guest file, both clipboards verified
- [x] Mouse hotspot left of the arrow's tip (GTK on Windows): guest glyph is 32x64, Windows
      stretches cursors to the square system size (48 here) -> square canvas (patch 0090)
- [x] User confirmed the GTK hotspot fix
- [ ] User: confirm the cursor in the SDL window (same canvas fix, patch 0092)
- [x] Upload cache: off by default on Linux too (upload-cache=false), so WHPX's all-dirty log
      costs nothing by default; zero-copy import works on Windows
- [x] Frame rate (Mission Control toggles): gtk ~15.5 presents/s, sdl,gl=on ~18 (patches 0092/0093:
      SDL GL crashed on EGL, pvg required dmabuf); Linux: gtk 10.8, gtk-gl 25, dbus 29
- [ ] gtk,gl=on on Windows: QEMU's GtkGLArea path assumes EGL and calls GL from vCPU threads
      (WGL needs the context current per thread): crashes; not supported upstream either
- [ ] SDL 2D renderer (-display sdl without gl) hangs at QEMU startup on Windows (monitor never
      listens); not investigated, run-pvg-vm.ps1 maps sdl to sdl,gl=on
- [~] Linux build with patch 0087: target/i386/host-breakpoints.c syntax-checked with
      -DCONFIG_KVM against QEMU's linux-headers on Windows; kvm.c only loses the moved walker
- [x] collect-rom.ps1 end to end: guest collect.sh rom -> transfer disk -> re/collected, ROM identical
      (fixed: mtools takes "C:" as its own drive letter -> relative target)
- [ ] Linux: reinstall the guest agent (install-guest.sh) so it survives a guest reboot there too

## Windows setup / docs
- [x] setup-windows.cmd -> scripts/setup-windows.ps1: guided, idempotent 9-step setup (-Status);
      tested: status on this PC, the fresh-VM path in a scratch ULTMOS folder (download, convert,
      64 GB disk, installer VM reaches macOS Recovery), shortcut creation
- [x] docs/windows.md: full guide (requirements, steps, running, updating, troubleshooting, manual setup)
- [x] .gitattributes: LF for patches / shell / Python / Swift (Windows checkouts with autocrlf)
- [ ] Not tested on a clean PC: WHPX enabling + reboot, winget MSYS2 install + first pacman update,
      a full macOS installation from Recovery under WHPX, copy-an-existing-VM path
- [ ] Replace "<repository URL>" in docs/windows.md once the fork is pushed

## Windows frame rate (measured 2026-11-01; Mission Control toggles, 32 s windows)
- [x] Display path: gtk 17.7, sdl 18.0, headless 18.0-20.4 presents/s (16 s windows were too noisy:
      15.5 / 18 / 21 earlier). No CPU frame readback (test switch): ~20 -> a native DirectX/Vulkan
      swapchain window could gain at most a few %. Not built.
- [x] Interrupt path: done->stamp (main-loop publish without irqfd) 15-30 us: not a problem.
      WHPX halt polling (200 us) tried: 18.1, reverted. 4 vCPUs: 18.7.
- [x] GPU clocks locked (nvidia-smi -lgc 1500,2100 / -lmc 7001): previous-frame GPU waits
      11-19 -> 2-3 ms, 20.0 headless / 19.5 gtk (+5-10 %). Documented: NVIDIA "Prefer maximum
      performance" for qemu-system-x86_64.exe.
- [ ] The remaining gap to Linux (28/s) is guest speed under WHPX (exits for timer/APIC with
      kernel-irqchip=off). Hyper-V's APIC (kernel-irqchip=on, -x2apic) boots but crawls (progress
      bar 30 -> 40 % in 8 min): find why (timer/IPI delivery) - the most promising lead
- [ ] Worker queue wait 5-7 ms per job (same on Linux: 7-9 ms) - frame pipelining, not Windows

## Guest app issues (both hosts)
- [ ] Desktop & Dock pane: rare SIGBUS KERN_MEMORY_ERROR at Metal+0x208b31 while decoding the HEIC
      wallpaper thumbnail (CMPhoto/ImageIO -> IOSurface); 3 reports (2 on Linux Oct 31, 1 on Windows),
      0 of 7 reproductions; not on a fixup-patched page; no kernel log errors
- [ ] Blender 4.5: Metal backend needs argument buffers tier 2, barycentrics and MTLGPUFamilyMac2
      (Apple's x86 PVG plugin has no argument buffers at all); crashes in GPU_storagebuf_update
      instead of reporting it. Blender 4.5 has no OpenGL backend on macOS (3.6 LTS untested)
