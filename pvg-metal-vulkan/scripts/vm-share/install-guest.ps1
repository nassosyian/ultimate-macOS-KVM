# install-guest.ps1 - install the guest sharing agent (VMShare.app) without ssh (Windows host).
#
# Writes VMShare.swift, guest/install.sh and the host's share token to a small FAT disk (label
# VMSHARE) and boots the VM with it attached (scripts\run-pvg-vm.ps1 -ExtraDisk; extra options are
# passed on, e.g. -Overlay). In macOS, open Terminal and run
#     sh /Volumes/VMSHARE/install.sh
# and click Allow if macOS asks whether VMShare may find devices on your local network.
# Needs MSYS2's dosfstools, mtools and Python: pacman -S dosfstools mingw-w64-x86_64-mtools
# (and the packages of README "Windows host").

param(
    [string]$Msys2 = "C:\msys64",
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$RunArgs
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Dir = "$Root\re\transfer"
$Img = "$Dir\vmshare.img"
$MkFs = "$Msys2\usr\bin\mkfs.fat.exe"
$MCopy = "$Msys2\mingw64\bin\mcopy.exe"
$Py = "$Msys2\ucrt64\bin\python.exe"

foreach ($t in $MkFs, $MCopy, $Py) {
    if (-not (Test-Path $t)) { throw "missing ${t}: see the header of this script" }
}
New-Item -ItemType Directory -Force $Dir | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $Img
$f = [System.IO.File]::Create($Img)
$f.SetLength(64MB)
$f.Close()
& $MkFs -F 32 -n VMSHARE $Img | Out-Null
if ($LASTEXITCODE) { throw "mkfs.fat failed" }

# the token the daemon expects (created on first use)
$Token = "$Dir\token"
$env:PATH = "$Msys2\ucrt64\bin;$env:PATH"
[System.IO.File]::WriteAllText($Token, ((& $Py "$PSScriptRoot\kvm-share.py" token) | Out-String).Trim() + "`n")
foreach ($src in "$PSScriptRoot\guest\VMShare.swift", "$PSScriptRoot\guest\install.sh", $Token) {
    & $MCopy -o -i $Img $src "::$(Split-Path -Leaf $src)"
    if ($LASTEXITCODE) { throw "mcopy $src failed" }
}
Remove-Item -Force $Token

# "-Name value" / "-Switch" strings -> named parameters (array splatting would pass them positionally)
$Named = @{ ExtraDisk = $Img }
for ($i = 0; $i -lt $RunArgs.Count; $i++) {
    $name = $RunArgs[$i].TrimStart('-')
    if ($i + 1 -lt $RunArgs.Count -and -not $RunArgs[$i + 1].StartsWith('-')) {
        $Named[$name] = $RunArgs[++$i]
    } else {
        $Named[$name] = $true
    }
}

Write-Host "Booting the VM with the VMSHARE disk. In macOS, open Terminal and run:"
Write-Host "    sh /Volumes/VMSHARE/install.sh"
Write-Host "(click Allow if macOS asks about local network access)"
& "$Root\scripts\run-pvg-vm.ps1" @Named
