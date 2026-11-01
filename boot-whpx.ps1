# boot-whpx.ps1 - boot the ULTMOS macOS VM on Windows with QEMU + WHPX (Windows Hypervisor Platform).
#
# For stock QEMU builds. On an AMD host stock QEMU cannot boot macOS under WHPX (divide error in
# cpu_thread_alloc: CPUID leaf 4 comes from the host); use the patched build instead:
# pvg-metal-vulkan/scripts/run-pvg-vm.ps1 (-NoPvg for plain VGA).
#
# Test launcher derived from boot.sh: no paravirtual GPU, no passthrough, plain QXL display.
# By default the HDD is opened with -snapshot: nothing the guest writes reaches HDD.qcow2.
#
#   powershell -ExecutionPolicy Bypass -File .\boot-whpx.ps1                 # safe test boot
#   powershell -ExecutionPolicy Bypass -File .\boot-whpx.ps1 -Persist        # keep guest writes
#   powershell -ExecutionPolicy Bypass -File .\boot-whpx.ps1 -IrqChip on     # try in-hypervisor APIC
#   powershell -ExecutionPolicy Bypass -File .\boot-whpx.ps1 -Cpu host       # real CPU model (AMD)

param(
    [switch]$Persist,
    [string]$Ram = "8G",
    [int]$Cores = 4,
    [int]$Threads = 2,
    [string]$Cpu = "Haswell-noTSX,vendor=GenuineIntel,+invtsc,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,-pcid,-tsc-deadline,-invpcid",
    [ValidateSet("on", "off")][string]$IrqChip = "off",
    [ValidateSet("gtk", "sdl", "none")][string]$Display = "gtk",
    [switch]$Installer,
    [string]$SerialLog,
    [string]$Qemu = "C:\Program Files\qemu\qemu-system-x86_64.exe"
)

$ErrorActionPreference = "Stop"
$VM = $PSScriptRoot

if (-not (Test-Path $Qemu)) { throw "QEMU not found at $Qemu (pass -Qemu <path>)" }

# Firmware and OpenCore: copied from the templates once, as AutoPilot does (compat_new = Tahoe).
New-Item -ItemType Directory -Force "$VM\ovmf", "$VM\boot" | Out-Null
foreach ($f in @(
        @("$VM\resources\ovmf\OVMF_CODE.fd", "$VM\ovmf\OVMF_CODE.fd"),
        @("$VM\resources\ovmf\OVMF_VARS.fd", "$VM\ovmf\OVMF_VARS.fd"),
        @("$VM\resources\oc_store\compat_new\OpenCore.qcow2", "$VM\boot\OpenCore.qcow2"))) {
    if (-not (Test-Path $f[1])) {
        Copy-Item $f[0] $f[1]
        Write-Host "copied $(Split-Path -Leaf $f[0]) -> $($f[1])"
    }
}

# QEMU's option parser splits on commas; forward slashes avoid backslash surprises.
function QPath([string]$p) { return ($p -replace '\\', '/') }

$qargs = @(
    "-accel", "whpx,kernel-irqchip=$IrqChip",
    "-machine", "q35",
    "-global", "ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off",
    "-m", $Ram,
    "-cpu", $Cpu,
    "-smp", "threads=$Threads,cores=$Cores,sockets=1",
    "-boot", "menu=on,splash-time=8",
    "-usb", "-device", "usb-kbd", "-device", "usb-tablet",
    "-device", "pcie-root-port,bus=pcie.0,slot=1,x-speed=16,x-width=32",
    "-device", "isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc",
    "-drive", "if=pflash,format=raw,readonly=on,file=$(QPath "$VM\ovmf\OVMF_CODE.fd")",
    "-drive", "if=pflash,format=raw,file=$(QPath "$VM\ovmf\OVMF_VARS.fd")",
    "-smbios", "type=2",
    "-device", "ich9-ahci,id=sata",
    "-drive", "id=OpenCore,if=none,format=qcow2,file=$(QPath "$VM\boot\OpenCore.qcow2")",
    "-drive", "id=HDD,if=none,format=qcow2,file=$(QPath "$VM\HDD.qcow2")$(if (-not $Persist) { ',snapshot=on' })",
    "-device", "ide-hd,bus=sata.2,drive=OpenCore,bootindex=1",
    "-device", "ide-hd,bus=sata.3,drive=HDD,rotation_rate=1",
    "-netdev", "user,id=net0",
    "-device", "virtio-net-pci,netdev=net0,id=net0,mac=00:16:cb:00:21:09",
    "-device", "qxl-vga,vgamem_mb=512,vram_size_mb=512",
    "-display", $Display,
    "-monitor", "stdio"
)
if ($SerialLog) {
    $qargs += "-serial", "file:$(QPath $SerialLog)"   # guest kernel log with boot-arg serial=3
}
if ($Installer) {
    $qargs += "-drive", "id=BaseSystem,if=none,format=raw,file=$(QPath "$VM\BaseSystem.img")"
    $qargs += "-device", "ide-hd,bus=sata.4,drive=BaseSystem"
}

Write-Host "accel: whpx (kernel-irqchip=$IrqChip)  cpu: $Cpu"
Write-Host "smp: $($Cores * $Threads) vCPUs  ram: $Ram  HDD: $(if ($Persist) { 'read-write' } else { 'snapshot (writes discarded)' })"
Write-Host "QEMU monitor below: 'quit' stops the VM, 'info status' shows its state."
& $Qemu @qargs
