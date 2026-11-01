# collect-rom.ps1 - Windows version of collect-rom.sh: collect AppleParavirtEFI.rom (the PVG option
# ROM) from the macOS guest, once before the first scripts\run-pvg-vm.ps1.
#
# Creates a FAT32 transfer disk (label PVGXFER) holding guest/collect.sh, boots the VM with plain VGA
# (run-pvg-vm.ps1 -NoPvg) and that disk attached, and after the VM shuts down copies the collected
# files into re\collected\. In the guest: open Terminal, run  sh /Volumes/PVGXFER/collect.sh rom
# and shut down.
#
# Needs MSYS2's dosfstools and mtools:
#   pacman -S dosfstools mingw-w64-x86_64-mtools
# (A Linux checkout's re/collected/ can be copied instead: the ROM is the same file.)

param([string]$Msys2 = "C:\msys64")

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$XferDir = "$Root\re\transfer"
$Img = "$XferDir\transfer.img"
$Rom = "$Root\re\collected\collected\frameworks\ParavirtualizedGraphics.framework\Versions\A\Resources\AppleParavirtEFI.rom"
$MkFs = "$Msys2\usr\bin\mkfs.fat.exe"
$MCopy = "$Msys2\mingw64\bin\mcopy.exe"

foreach ($t in $MkFs, $MCopy) {
    if (-not (Test-Path $t)) { throw "missing ${t}: pacman -S dosfstools mingw-w64-x86_64-mtools" }
}
New-Item -ItemType Directory -Force $XferDir | Out-Null
if (-not (Test-Path $Img)) {
    $f = [System.IO.File]::Create($Img)
    $f.SetLength(2GB)
    $f.Close()
    & $MkFs -F 32 -n PVGXFER $Img | Out-Null
    if ($LASTEXITCODE) { throw "mkfs.fat failed" }
}
& $MCopy -o -i $Img "$Root\guest\collect.sh" ::collect.sh
if ($LASTEXITCODE) { throw "mcopy failed" }

Write-Host "Booting the VM with the transfer disk. In macOS, open Terminal and run:"
Write-Host "    sh /Volumes/PVGXFER/collect.sh rom"
Write-Host "then shut the VM down."
& "$PSScriptRoot\run-pvg-vm.ps1" -NoPvg -NoShare -ExtraDisk $Img

New-Item -ItemType Directory -Force "$Root\re\collected" | Out-Null
$ErrorActionPreference = "Continue"     # mcopy's stderr must not end the script (PowerShell 5.1)
# a relative target: mtools takes "C:" for one of its own drive letters
Push-Location "$Root\re"
& $MCopy -s -n -o -i $Img ::collected collected 2>$null
Pop-Location
$ErrorActionPreference = "Stop"
if (Test-Path $Rom) {
    Write-Host "AppleParavirtEFI.rom collected: $Rom"
} else {
    throw "AppleParavirtEFI.rom not found on the transfer disk: run collect.sh in the guest and retry"
}
