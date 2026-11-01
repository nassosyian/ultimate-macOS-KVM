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
