# run-pvg-vm.ps1 - Windows version of run-pvg-vm.sh: boot the ULTMOS macOS VM with the paravirtual
# GPU (pvg-linux-pci, Metal on the host GPU via Vulkan) under the Windows Hypervisor Platform (WHPX).
#
#   powershell -ExecutionPolicy Bypass -File scripts\run-pvg-vm.ps1 [options]
#
# Needs: scripts/build-qemu.sh run in an MSYS2 UCRT64 shell (src/qemu/build), the PVG option ROM
# in re/collected/ (scripts/collect-rom.sh, or copied from a Linux checkout), and the ULTMOS VM
# (HDD.qcow2, boot/OpenCore.qcow2, ovmf/) in the checkout this folder sits in.
#
# Options (defaults follow run-pvg-vm.sh):
#   -DisplayMode gtk|sdl|vnc|none  window type (gtk; vnc = 127.0.0.1:5901, none = headless).
#                                  sdl is SDL with OpenGL: same frame rate as gtk, but no file
#                                  drops and no menus. No gtk,gl=on (QEMU's GtkGLArea needs EGL)
#   -Overlay                       throwaway copy-on-write overlays in re/vm/ (nothing is kept)
#   -Ram 8G -Cores 8 -Threads 1    guest size
#   -Usb xhci|ehci                 keyboard/tablet controller
#   -Audio dsound|sdl|none         host audio for the guest's USB audio device (dsound)
#   -NoPvg                         plain VGA instead of the paravirtual GPU (boot tests)
#   -PvgProps "a=b,c=d"            extra pvg-linux-pci properties (e.g. gpu-validation=on)
#   -TraceEvents file              QEMU trace events (log in logs/)
#   -SerialLog file                guest serial port to a file (macOS kernel log with serial=3)
#   -NoShare                       no clipboard / file sharing (scripts/vm-share/kvm-share.py)
#   -IrqChip off|on                APIC in QEMU (off, default) or in Hyper-V (on: works since patch
#                                  0094, same frame rate; less tested)
#   -SshPort 2222                  forward 127.0.0.1:PORT to the guest's ssh (Remote Login), e.g. for
#                                  scripts/vm-share/install-guest.sh -p (user networking has no route in)
#   -Installer                     attach the macOS installer (BaseSystem.img in the ULTMOS folder),
#                                  for a fresh install (with -NoPvg; scripts\setup-windows.ps1)
#   -ExtraDisk file.img            a raw disk on the next AHCI port (scripts/collect-rom.ps1)
#   -OpenCore file.qcow2           another OpenCore image, e.g. a copy with boot-args -v serial=3
#                                  (scripts/whpx-oc-patch.py in the repository root) for kernel logs
#   -QemuExtra "..."               extra QEMU arguments
#   -Qemu path                     QEMU binary (default src/qemu/build/qemu-system-x86_64.exe)
#   -Msys2 dir                     MSYS2 root, for the build's DLLs (C:\msys64)

param(
    [ValidateSet("gtk", "sdl", "vnc", "none")][string]$DisplayMode = "gtk",
    [switch]$Overlay,
    [string]$Ram = "8G",
    [int]$Cores = 8,
    [int]$Threads = 1,
    [ValidateSet("xhci", "ehci")][string]$Usb = "xhci",
    [ValidateSet("dsound", "sdl", "none")][string]$Audio = "dsound",
    [switch]$NoPvg,
    [string]$PvgProps = "",
    [string]$TraceEvents = "",
    [string]$SerialLog = "",
    [switch]$NoShare,
    [ValidateSet("on", "off")][string]$IrqChip = "off",
    [int]$SshPort = 0,
    [switch]$Installer,
    [string]$ExtraDisk = "",
    [string]$OpenCore = "",
    [string]$QemuExtra = "",
    [string]$Qemu = "",
    [string]$Msys2 = "C:\msys64"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
# the ULTMOS VM: the ultimate-macOS-KVM checkout this folder sits in, else one next to it
$Ultmos = if ($env:ULTMOS) { $env:ULTMOS }
          elseif (Test-Path "$Root\..\main.py") { (Resolve-Path "$Root\..").Path }
          else { Join-Path (Resolve-Path "$Root\..").Path "ultimate-macOS-KVM" }
$Build = "$Root\src\qemu\build"
if (-not $Qemu) { $Qemu = "$Build\qemu-system-x86_64.exe" }
$QemuImg = Join-Path (Split-Path -Parent $Qemu) "qemu-img.exe"
$Rom = "$Root\re\collected\collected\frameworks\ParavirtualizedGraphics.framework\Versions\A\Resources\AppleParavirtEFI.rom"
$RunDir = "$Root\re\vm"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"

if (-not (Test-Path $Qemu)) { throw "build QEMU first (MSYS2 UCRT64 shell): scripts/build-qemu.sh" }
if (-not $NoPvg -and -not (Test-Path $Rom)) { throw "missing AppleParavirtEFI.rom (guest collect step): $Rom" }
foreach ($f in "$Ultmos\HDD.qcow2", "$Ultmos\boot\OpenCore.qcow2", "$Ultmos\ovmf\OVMF_CODE.fd", "$Ultmos\ovmf\OVMF_VARS.fd") {
    if (-not (Test-Path $f)) { throw "missing $f (create the VM with ULTMOS, or run boot-whpx.ps1 once)" }
}
if (Get-CimInstance Win32_Process -Filter "Name like 'qemu-system-x86_64%'" |
        Where-Object { $_.CommandLine -match [regex]::Escape("HDD.qcow2") -or $_.CommandLine -match "hdd-overlay" }) {
    throw "another VM is using the disk; stop it first"
}
# the development build needs MSYS2's runtime DLLs
if (Test-Path "$Msys2\ucrt64\bin") { $env:PATH = "$Msys2\ucrt64\bin;$env:PATH" }

New-Item -ItemType Directory -Force $RunDir, "$Root\logs" | Out-Null
if ($Overlay) {
    Remove-Item -Force -ErrorAction SilentlyContinue "$RunDir\hdd-overlay.qcow2", "$RunDir\oc-overlay.qcow2"
    & $QemuImg create -q -f qcow2 -F qcow2 -b "$Ultmos\HDD.qcow2" "$RunDir\hdd-overlay.qcow2"
    & $QemuImg create -q -f qcow2 -F qcow2 -b "$Ultmos\boot\OpenCore.qcow2" "$RunDir\oc-overlay.qcow2"
    Copy-Item -Force "$Ultmos\ovmf\OVMF_VARS.fd" "$RunDir\OVMF_VARS.fd"
    $Hdd = "$RunDir\hdd-overlay.qcow2"; $Oc = "$RunDir\oc-overlay.qcow2"; $Vars = "$RunDir\OVMF_VARS.fd"
} else {
    $Hdd = "$Ultmos\HDD.qcow2"; $Oc = "$Ultmos\boot\OpenCore.qcow2"; $Vars = "$Ultmos\ovmf\OVMF_VARS.fd"
}
if ($OpenCore) { $Oc = $OpenCore }     # e.g. a copy with debug boot-args (whpx-oc-patch.py)

# QEMU's option parser splits on commas; forward slashes avoid backslash surprises
function QPath([string]$p) { return ($p -replace '\\', '/') }

function Test-Listening([string]$h, [int]$port) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { $c.Connect($h, $port); return $true } catch { return $false } finally { $c.Close() }
}

$DisplayArgs = switch ($DisplayMode) {
    "gtk" { @("-display", "gtk,zoom-to-fit=off") }
    "sdl" { @("-display", "sdl,gl=on") }     # SDL's 2D renderer hangs at startup on Windows
    "vnc" { @("-display", "none", "-vnc", "127.0.0.1:1") }
    "none" { @("-display", "none") }
}
if ($Usb -eq "ehci") {
    $UsbArgs = @("-usb", "-device", "usb-kbd", "-device", "usb-tablet"); $AudioBus = ""
} else {
    $UsbArgs = @("-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0", "-device", "usb-tablet,bus=xhci.0")
    $AudioBus = ",bus=xhci.0"
}
$AudioArgs = if ($Audio -eq "none") { @() } else { @("-audiodev", "$Audio,id=snd0", "-device", "usb-audio,audiodev=snd0$AudioBus") }
$GpuArgs = if ($NoPvg) { @("-device", "VGA,vgamem_mb=64") } else {   # no qxl: built without spice
    @("-vga", "none",
      "-device", "pcie-root-port,id=rp1,bus=pcie.0,chassis=1,slot=1",
      "-device", "pvg-linux-pci,id=pvg0,bus=rp1,gpu=on,exec=on,romfile=$(QPath $Rom)$(if ($PvgProps) { ",$PvgProps" })")
}

$ShareProc = $null
if (-not $NoShare) {
    # clipboard + file sharing daemon; drops on the GTK window reach it over loopback TCP.
    # Runs under MSYS2's Python (PyGObject + GTK 3: pacman -S mingw-w64-ucrt-x86_64-python-gobject)
    $env:QEMU_GTK_DROP_SOCKET = "tcp:127.0.0.1:7330"
    $Py = "$Msys2\ucrt64\bin\python.exe"
    $Share = "$Root\scripts\vm-share\kvm-share.py"
    if (-not (Test-Path $Py)) {
        Write-Warning "no ${Py}: clipboard / file sharing off"
    } elseif (-not (Test-Listening 127.0.0.1 7330)) {      # reuse a running daemon
        $ShareProc = Start-Process -FilePath $Py -ArgumentList "`"$Share`"", "daemon" -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput "$Root\logs\kvm-share.log" -RedirectStandardError "$Root\logs\kvm-share.err.log"
    }
}

$qargs = @(
    "-name", "macOS (pvg)",
    # intercept-msr-gp: SYSENTER MSR writes of the Intel CPU model fault on AMD hosts (emulated)
    "-accel", "whpx,kernel-irqchip=$IrqChip,intercept-msr-gp=on",
    "-m", $Ram,
    "-machine", "q35",
    "-global", "ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off",
    "-cpu", "Haswell-noTSX,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,-pcid,-tsc-deadline,-invpcid",
    "-smp", "threads=$Threads,cores=$Cores,sockets=1",
    "-L", (QPath "$Root\src\qemu\pc-bios"), "-L", (QPath "$Build\pc-bios")
) + $UsbArgs + $AudioArgs + @(
    "-device", "isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc",
    "-drive", "if=pflash,format=raw,readonly=on,file=$(QPath "$Ultmos\ovmf\OVMF_CODE.fd")",
    "-drive", "if=pflash,format=raw,file=$(QPath $Vars)",
    "-smbios", "type=2",
    "-device", "ich9-ahci,id=sata",
    "-drive", "id=OpenCore,if=none,format=qcow2,file=$(QPath $Oc)",
    "-drive", "id=HDD,if=none,format=qcow2,file=$(QPath $Hdd)",
    "-device", "ide-hd,bus=sata.2,drive=OpenCore,bootindex=1",
    "-device", "ide-hd,bus=sata.3,drive=HDD,rotation_rate=1",
    # user networking with the libvirt bridge's addresses: the host (its loopback) is 192.168.122.1,
    # where the guest's sharing agent looks first, as with NET=bridge on Linux
    "-netdev", "user,id=net0,net=192.168.122.0/24,host=192.168.122.1,dhcpstart=192.168.122.15$(if ($SshPort) { ",hostfwd=tcp:127.0.0.1:${SshPort}-:22" })",
    "-device", "virtio-net-pci,netdev=net0,id=net0,mac=00:16:cb:00:21:09"
) + $GpuArgs + $DisplayArgs + @(
    "-monitor", "tcp:127.0.0.1:4444,server,nowait",
    "-qmp", "tcp:127.0.0.1:4445,server,nowait",
    "-msg", "timestamp=on"
)
if ($TraceEvents) { $qargs += "-trace", "events=$(QPath $TraceEvents)", "-D", (QPath "$Root\logs\pvg-vm-$Stamp.log") }
if ($SerialLog) { $qargs += "-serial", "file:$(QPath $SerialLog)" }
if ($Installer) {
    if (-not (Test-Path "$Ultmos\BaseSystem.img")) { throw "no installer: $Ultmos\BaseSystem.img (setup-windows.ps1 downloads it)" }
    $qargs += "-drive", "id=BaseSystem,if=none,format=raw,file=$(QPath "$Ultmos\BaseSystem.img")",
              "-device", "ide-hd,bus=sata.4,drive=BaseSystem"
}
if ($ExtraDisk) {
    $qargs += "-drive", "id=Extra,if=none,format=raw,file=$(QPath $ExtraDisk)", "-device", "ide-hd,bus=sata.5,drive=Extra"
}
if ($QemuExtra) { $qargs += $QemuExtra -split '\s+' }

Write-Host "QEMU: $Qemu"
Write-Host "monitor: telnet 127.0.0.1 4444   QMP: 127.0.0.1:4445"
try {
    & $Qemu @qargs
} finally {
    if ($ShareProc) { Stop-Process -Id $ShareProc.Id -ErrorAction SilentlyContinue }
}
