# setup-windows.ps1 - guided setup of pvg-metal-vulkan on a Windows 10/11 host.
#
#   Double-click setup-windows.cmd (next to the README), or in PowerShell:
#   powershell -ExecutionPolicy Bypass -File scripts\setup-windows.ps1 [-Status]
#
# Walks through every step and skips what is already done, so it can be run again at any time
# (after a reboot, after a git pull: it rebuilds QEMU when patches changed):
#   1. checks: Windows build, CPU virtualization, RAM, disk space, Vulkan GPU, folder path
#   2. Windows Hypervisor Platform (WHPX)        - enables it (administrator, reboot)
#   3. MSYS2 + build packages                    - installs MSYS2 with winget, then pacman
#   4. line endings of the checkout              - fixes CRLF in scripts and patches
#   5. QEMU with the pvg patches                 - scripts/build-qemu.sh (~25 min the first time)
#   6. the macOS VM (ULTMOS folder)              - copy an existing VM, or create a new one and
#                                                  install macOS Tahoe from Apple's recovery image
#   7. the PVG option ROM                         - copy it, or collect it from the guest
#   8. clipboard / file sharing agent (optional) - installs VMShare in the guest
#   9. desktop shortcut and first start
# -Status only prints what is done and what is missing.

param([switch]$Status)

# Continue: native tools (vulkaninfo, git, pacman) write to stderr, which PowerShell 5.1 turns
# into terminating errors under Stop; file operations below use -ErrorAction Stop instead
$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot                      # pvg-metal-vulkan
$Ultmos = if ($env:ULTMOS) { $env:ULTMOS }
          elseif (Test-Path "$Root\..\main.py") { (Resolve-Path "$Root\..").Path }
          else { Join-Path (Resolve-Path "$Root\..").Path "ultimate-macOS-KVM" }
$Msys2 = if ($env:MSYS2_ROOT) { $env:MSYS2_ROOT } else { "C:\msys64" }
$Bash = "$Msys2\usr\bin\bash.exe"
$Qemu = "$Root\src\qemu\build\qemu-system-x86_64.exe"
$QemuImg = "$Root\src\qemu\build\qemu-img.exe"
$Rom = "$Root\re\collected\collected\frameworks\ParavirtualizedGraphics.framework\Versions\A\Resources\AppleParavirtEFI.rom"
$Packages = @("git", "base-devel") + @("toolchain", "meson", "ninja", "python", "python-distlib", "glib2",
    "pixman", "libslirp", "gtk3", "SDL2", "libepoxy", "pkgconf", "vulkan-headers", "vulkan-loader",
    "llvm", "zstd", "lzo2", "curl", "libpng", "libjpeg-turbo", "python-gobject", "gdb" |
    ForEach-Object { "mingw-w64-ucrt-x86_64-$_" }) + @("dosfstools", "mingw-w64-x86_64-mtools")

# ---- helpers ----

function Say([string]$msg, [string]$color = "Gray") { Write-Host $msg -ForegroundColor $color }
function Ok([string]$msg) { Write-Host "  [ok] " -ForegroundColor Green -NoNewline; Write-Host $msg }
function Todo([string]$msg) { Write-Host "  [  ] " -ForegroundColor Yellow -NoNewline; Write-Host $msg }
function Bad([string]$msg) { Write-Host "  [!!] " -ForegroundColor Red -NoNewline; Write-Host $msg }
function Step([int]$n, [string]$title) { Write-Host ""; Write-Host "== $n. $title" -ForegroundColor Cyan }
function Ask([string]$q, [bool]$default = $true) {
    if ($Status) { return $false }
    $hint = if ($default) { "[Y/n]" } else { "[y/N]" }
    $a = Read-Host "  $q $hint"
    if ([string]::IsNullOrWhiteSpace($a)) { return $default }
    return $a.Trim().ToLower().StartsWith("y")
}
function Choose([string]$q, [string[]]$options) {
    for ($i = 0; $i -lt $options.Count; $i++) { Write-Host ("    {0}. {1}" -f ($i + 1), $options[$i]) }
    while ($true) {
        $a = Read-Host "  $q (1-$($options.Count), Enter to skip)"
        if ([string]::IsNullOrWhiteSpace($a)) { return 0 }
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $options.Count) { return $n }
    }
}
function Pause-Here([string]$msg = "Press Enter to continue") { if (-not $Status) { [void](Read-Host "  $msg") } }
function Stop-Setup([string]$msg) {
    Say ""; Say $msg Yellow
    Say "Run this setup again afterwards: it continues where it stopped." Yellow
    Pause-Here "Press Enter to close"
    exit 0
}
# a command in MSYS2's UCRT64 environment (output shown)
function Msys([string]$cmd) {
    $env:MSYSTEM = "UCRT64"; $env:CHERE_INVOKING = "1"
    & $Bash -lc $cmd
    return $LASTEXITCODE
}
function MsysPath([string]$p) { return (& "$Msys2\usr\bin\cygpath.exe" -u $p).Trim() }
function Gb([double]$bytes) { return [math]::Round($bytes / 1GB, 1) }

# WHPX usable? Asks the platform API itself (the Windows feature list is not reliable without admin)
function Test-Whpx {
    if (-not ("WhpxProbe" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class WhpxProbe {
    [DllImport("WinHvPlatform.dll")]
    static extern int WHvGetCapability(int code, out long buffer, uint size, out uint written);
    public static int Present() {
        try { long v; uint w; int hr = WHvGetCapability(0, out v, 8, out w); return hr == 0 && v != 0 ? 1 : 0; }
        catch (DllNotFoundException) { return -1; }
        catch (EntryPointNotFoundException) { return -1; }
    }
}
"@
    }
    return [WhpxProbe]::Present()
}

# ---- 1. checks ----

function Step-Checks {
    Step 1 "System checks"
    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    if ($build -ge 19041) { Ok "$($os.Caption) (build $build)" }
    else { Bad "$($os.Caption) (build $build): Windows 10 2004 (19041) or newer is needed" }

    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    if ($cs.HypervisorPresent -or $cpu.VirtualizationFirmwareEnabled) { Ok "CPU virtualization: $($cpu.Name.Trim())" }
    else { Bad "CPU virtualization is off: enable Intel VT-x / AMD SVM in the BIOS/UEFI setup" }

    $ram = Gb $cs.TotalPhysicalMemory
    if ($ram -ge 15) { Ok "RAM: $ram GB (the VM uses 8 GB)" } else { Bad "RAM: $ram GB (16 GB or more recommended; the VM uses 8 GB)" }

    $drive = (Get-Item $Root).PSDrive
    $free = Gb $drive.Free
    if ($free -ge 40) { Ok "Free space on ${drive}: $free GB" }
    else { Bad "Free space on ${drive}: $free GB (the build needs ~5 GB, a new VM 30-80 GB)" }

    if ($Root -match '\s') { Bad "The folder path contains spaces: $Root`n       QEMU's build cannot handle that. Move the checkout (e.g. C:\VMs\ultimate-macOS-KVM)." }
    else { Ok "Folder: $Root" }

    $vk = Get-Command vulkaninfo -ErrorAction SilentlyContinue
    if ($vk) {
        $sum = (& $vk.Source --summary 2>$null) | Out-String
        $api = [regex]::Matches($sum, "apiVersion\s*=\s*(\d+)\.(\d+)") | Select-Object -First 1
        $dev = [regex]::Match($sum, "deviceName\s*=\s*(.+)").Groups[1].Value.Trim()
        if ($api -and ([int]$api.Groups[1].Value -gt 1 -or [int]$api.Groups[2].Value -ge 3)) {
            Ok "Vulkan $($api.Groups[1].Value).$($api.Groups[2].Value): $dev"
        } else { Bad "Vulkan 1.3 GPU not found ($dev): update the GPU driver" }
    } else {
        Bad "vulkaninfo not found: install the current GPU driver (it brings Vulkan). Only NVIDIA is tested."
    }
}

# ---- 2. WHPX ----

function Step-Whpx {
    Step 2 "Windows Hypervisor Platform (WHPX)"
    $p = Test-Whpx
    if ($p -eq 1) { Ok "WHPX is enabled"; return }
    if ($p -eq -1) { Todo "the Windows Hypervisor Platform feature is not installed" }
    else { Todo "WHPX is installed but no hypervisor is running (reboot pending, or virtualization off in the BIOS)" }
    if ($Status) { return }
    if ($p -eq 0) { Stop-Setup "Reboot Windows (and check that virtualization is enabled in the BIOS/UEFI setup)." }
    if (-not (Ask "Enable it now? (administrator prompt, then a reboot)")) { Stop-Setup "WHPX is required." }
    $cmd = "Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All -NoRestart | Out-Null"
    $proc = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile", "-Command", $cmd
    if ($proc.ExitCode -ne 0) { Stop-Setup "Enabling the feature failed (exit code $($proc.ExitCode))." }
    Stop-Setup "Windows Hypervisor Platform enabled. Reboot Windows now."
}

# ---- 3. MSYS2 ----

function Step-Msys2 {
    Step 3 "MSYS2 and the build packages"
    if (-not (Test-Path $Bash)) {
        Todo "MSYS2 not found in $Msys2 (set MSYS2_ROOT if it is elsewhere)"
        if ($Status) { return }
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Stop-Setup "Install MSYS2 from https://www.msys2.org (default folder C:\msys64)."
        }
        if (-not (Ask "Install MSYS2 with winget now?")) { Stop-Setup "MSYS2 is required to build QEMU." }
        winget install --id MSYS2.MSYS2 -e --accept-source-agreements --accept-package-agreements
        if (-not (Test-Path $Bash)) { Stop-Setup "MSYS2 did not end up in $Msys2. Install it there, or set MSYS2_ROOT." }
        Say "  first start of MSYS2 and a full update (twice: the first may update pacman itself)..."
        [void](Msys "true")
        [void](Msys "pacman -Syu --noconfirm")
        [void](Msys "pacman -Syu --noconfirm")
    }
    Ok "MSYS2: $Msys2"
    $installed = (& $Bash -lc "pacman -Qq" 2>$null) -split "`n" | ForEach-Object { $_.Trim() }
    $missing = @($Packages | Where-Object { $_ -notin @("base-devel", "mingw-w64-ucrt-x86_64-toolchain") -and $installed -notcontains $_ })
    if (-not ($installed -contains "mingw-w64-ucrt-x86_64-gcc")) { $missing += "mingw-w64-ucrt-x86_64-toolchain" }
    if (-not ($installed -contains "make")) { $missing += "base-devel" }
    if ($missing.Count -eq 0) { Ok "build packages installed"; return }
    Todo "$($missing.Count) package(s) missing: $($missing -join ' ')"
    if ($Status) { return }
    if (-not (Ask "Install them now (about 1.5 GB download)?")) { Stop-Setup "The packages are required." }
    if ((Msys "pacman -S --noconfirm --needed $($Packages -join ' ')") -ne 0) { Stop-Setup "pacman failed (see above)." }
    Ok "build packages installed"
}

# ---- 4. line endings ----

function Step-LineEndings {
    Step 4 "Line endings of the checkout"
    $files = @(Get-ChildItem "$Root\patches\*.patch", "$Root\scripts\*.sh", "$Root\scripts\vm-share\*.sh",
               "$Root\scripts\vm-share\*.py", "$Root\scripts\vm-share\guest\*", "$Root\guest\*.sh" -ErrorAction SilentlyContinue)
    $crlf = @($files | Where-Object { [System.IO.File]::ReadAllText($_.FullName).Contains("`r`n") })
    if ($crlf.Count -eq 0) { Ok "scripts and patches have Unix line endings"; return }
    Todo "$($crlf.Count) file(s) have Windows (CRLF) line endings (git core.autocrlf): patches and shell scripts break"
    if ($Status) { return }
    if (-not (Ask "Convert them to LF?")) { Stop-Setup "Re-clone with: git clone -c core.autocrlf=false ..." }
    foreach ($f in $crlf) {
        $t = [System.IO.File]::ReadAllText($f.FullName).Replace("`r`n", "`n")
        [System.IO.File]::WriteAllText($f.FullName, $t, (New-Object System.Text.UTF8Encoding $false))
    }
    Ok "converted $($crlf.Count) file(s)"
}

# ---- 5. build ----

function Step-Build {
    Step 5 "QEMU with the pvg patches"
    $newest = (Get-ChildItem "$Root\patches\*.patch" | Sort-Object LastWriteTime | Select-Object -Last 1).LastWriteTime
    $have = Test-Path $Qemu
    if ($have) {
        $applied = 0
        if (Test-Path "$Root\src\qemu\.git") {
            $applied = [int](& git -C "$Root\src\qemu" rev-list --count v11.1.3..HEAD 2>$null)
        }
        $count = @(Get-ChildItem "$Root\patches\*.patch").Count
        if ($applied -ge $count -and (Get-Item $Qemu).LastWriteTime -ge $newest) { Ok "built: $Qemu ($applied patches)"; return }
        Todo "built, but $($count - $applied) new patch(es) since: rebuild"
    } else {
        Todo "not built yet"
    }
    if ($Status) { return }
    if (-not (Ask "Build now? (first build ~25 min; downloads QEMU's source)")) { Stop-Setup "QEMU must be built." }
    $jobs = [Math]::Max(1, [Environment]::ProcessorCount - 2)
    if ((Msys "cd '$(MsysPath $Root)' && JOBS=$jobs scripts/build-qemu.sh") -ne 0 -or -not (Test-Path $Qemu)) {
        Stop-Setup "The build failed (see above). The full log: src\qemu\build\meson-logs, or rerun to retry."
    }
    Ok "built: $Qemu"
}

# ---- 6. the VM ----

function Copy-Templates([bool]$OpenCoreToo) {
    New-Item -ItemType Directory -Force "$Ultmos\ovmf", "$Ultmos\boot" | Out-Null
    foreach ($f in "OVMF_CODE.fd", "OVMF_VARS.fd") {
        if (-not (Test-Path "$Ultmos\ovmf\$f")) { Copy-Item "$Ultmos\resources\ovmf\$f" "$Ultmos\ovmf\$f" -ErrorAction Stop }
    }
    if ($OpenCoreToo -and -not (Test-Path "$Ultmos\boot\OpenCore.qcow2")) {
        Copy-Item "$Ultmos\resources\oc_store\compat_new\OpenCore.qcow2" "$Ultmos\boot\OpenCore.qcow2" -ErrorAction Stop
    }
}

function Get-Installer {
    # Apple's recovery image for Tahoe, like ULTMOS AutoPilot (scripts/dlosx-arg.py), then BaseSystem.img
    if (Test-Path "$Ultmos\BaseSystem.img") { return $true }
    $dmg = "$Ultmos\BaseSystem.dmg"
    if (-not (Test-Path $dmg)) {
        Say "  downloading macOS Tahoe's recovery image from Apple (~1 GB)..."
        & "$Msys2\ucrt64\bin\python.exe" "$Ultmos\scripts\dlosx-arg.py" --action download -b Mac-AF89B6D9451A490B `
            -m 00000000000000000 -os latest -o $Ultmos --disable-progress
        if (-not (Test-Path $dmg) -or (Get-Item $dmg).Length -lt 100MB) {
            Remove-Item -Force -ErrorAction SilentlyContinue $dmg
            return $false
        }
    }
    Say "  converting BaseSystem.dmg to BaseSystem.img..."
    $env:PATH = "$Msys2\ucrt64\bin;$env:PATH"
    & $QemuImg convert -p -f dmg -O raw $dmg "$Ultmos\BaseSystem.img"
    if ($LASTEXITCODE -ne 0) { Remove-Item -Force -ErrorAction SilentlyContinue "$Ultmos\BaseSystem.img"; return $false }
    Remove-Item -Force $dmg
    return $true
}

function Start-InstallerVm {
    Say ""
    Say "  The VM now boots the macOS installer (macOS Recovery, plain graphics; ~1 minute):" White
    Say "   1. Choose a language if asked. In the Recovery window open 'Disk Utility'."
    Say "   2. Select 'QEMU HARDDISK Media' (the empty disk, not 'macOS Base System') -> Erase:"
    Say "      name 'macOS', format APFS, scheme GUID Partition Map. Close Disk Utility."
    Say "   3. 'Reinstall macOS Tahoe' -> Continue -> the 'macOS' disk. It downloads macOS from Apple"
    Say "      (~15 GB) and restarts several times on its own (if the OpenCore menu waits, pick"
    Say "      'macOS Installer', later 'macOS'). Then set up macOS and your user account."
    Say "   4. At the desktop, shut macOS down (Apple menu -> Shut Down)."
    Say "  Closing the window or a power cut midway is fine: run this setup again to continue."
    Pause-Here "Press Enter to start the installer VM"
    & "$PSScriptRootun-pvg-vm.ps1" -NoPvg -NoShare -Installer
    if ((Get-Item "$Ultmos\HDD.qcow2").Length -ge 10GB) {
        Ok "macOS is on the disk; BaseSystem.img ($Ultmos) is no longer needed and can be deleted"
    } else {
        Todo "the disk is still almost empty: run this setup again to continue the installation"
    }
}

function Step-Vm {
    Step 6 "The macOS VM ($Ultmos)"
    $hdd = Test-Path "$Ultmos\HDD.qcow2"
    $oc = Test-Path "$Ultmos\boot\OpenCore.qcow2"
    $ovmf = (Test-Path "$Ultmos\ovmf\OVMF_CODE.fd") -and (Test-Path "$Ultmos\ovmf\OVMF_VARS.fd")
    if ($hdd -and $oc -and $ovmf) {
        if ((Test-Path "$Ultmos\BaseSystem.img") -and (Get-Item "$Ultmos\HDD.qcow2").Length -lt 10GB) {
            Todo "HDD.qcow2 is still almost empty: macOS is not installed yet"
            if ($Status) { return }
            if (Ask "Boot the macOS installer?") { Start-InstallerVm }
            return
        }
        Ok "HDD.qcow2, boot\OpenCore.qcow2, ovmf\ present"
        return
    }
    if ($hdd) {
        Todo "HDD.qcow2 found, but $(if (-not $oc) { 'boot\OpenCore.qcow2 ' })$(if (-not $ovmf) { 'ovmf\ ' })missing"
        if ($Status) { return }
        Say "  If this disk comes from another computer, copy its boot\OpenCore.qcow2 and ovmf\OVMF_VARS.fd too:"
        Say "  OpenCore holds the VM's Mac serial number (iCloud / Apple ID). Otherwise ULTMOS's templates are used."
        if (Ask "Use the templates for what is missing?") { Copy-Templates $true; Ok "templates copied" }
        return
    }
    Todo "no VM yet (HDD.qcow2)"
    if ($Status) { return }
    $c = Choose "How do you want to get the macOS VM?" @(
        "copy an existing ULTMOS VM (e.g. from Linux: HDD.qcow2, boot\, ovmf\)",
        "create a new VM and install macOS Tahoe (~1-2 hours, mostly the macOS installer)")
    if ($c -eq 1) {
        $src = Read-Host "  Folder of the existing VM (the one with HDD.qcow2)"
        $src = $src.Trim('"', ' ')
        if (-not (Test-Path "$src\HDD.qcow2")) { Stop-Setup "No HDD.qcow2 in $src." }
        Say "  copying (the disk can be tens of GB)..."
        New-Item -ItemType Directory -Force "$Ultmos\boot", "$Ultmos\ovmf" | Out-Null
        Copy-Item "$src\HDD.qcow2" "$Ultmos\HDD.qcow2" -ErrorAction Stop
        foreach ($f in "boot\OpenCore.qcow2", "ovmf\OVMF_CODE.fd", "ovmf\OVMF_VARS.fd") {
            if (Test-Path "$src\$f") { Copy-Item "$src\$f" "$Ultmos\$f" -Force -ErrorAction Stop }
        }
        Copy-Templates $true
        Ok "VM copied"
        return
    }
    if ($c -ne 2) { Stop-Setup "A macOS VM is required." }
    Copy-Templates $true
    $size = Read-Host "  Disk size in GB (Enter: 128; the file grows as needed)"
    if (-not $size) { $size = "128" }
    $env:PATH = "$Msys2\ucrt64\bin;$env:PATH"
    & $QemuImg create -f qcow2 "$Ultmos\HDD.qcow2" "${size}G" | Out-Null
    if (-not (Get-Installer)) {
        Remove-Item -Force "$Ultmos\HDD.qcow2"
        Stop-Setup ("Could not get the installer. Put a BaseSystem.img (ULTMOS AutoPilot on Linux makes one) or " +
                    "BaseSystem.dmg into $Ultmos and run the setup again.")
    }
    Start-InstallerVm
}

# ---- 7. ROM ----

function Step-Rom {
    Step 7 "The PVG option ROM (AppleParavirtEFI.rom, from your macOS guest)"
    if (Test-Path $Rom) { Ok "present"; return }
    Todo "missing: $Rom"
    if ($Status) { return }
    $c = Choose "How?" @(
        "collect it from the guest (boots the VM; you type one command in Terminal)",
        "copy it from another checkout (e.g. Linux: pvg-metal-vulkan\re\collected) or a file")
    if ($c -eq 1) {
        & "$PSScriptRoot\collect-rom.ps1" -Msys2 $Msys2
    } elseif ($c -eq 2) {
        $src = (Read-Host "  Path to AppleParavirtEFI.rom, or to a re\collected folder").Trim('"', ' ')
        if (Test-Path "$src\collected\frameworks") { $src = Join-Path $src "collected\frameworks\ParavirtualizedGraphics.framework\Versions\A\Resources\AppleParavirtEFI.rom" }
        if (-not (Test-Path $src)) { Stop-Setup "Not found: $src" }
        New-Item -ItemType Directory -Force (Split-Path -Parent $Rom) | Out-Null
        Copy-Item $src $Rom -ErrorAction Stop
    } else {
        Stop-Setup "The ROM is required for the paravirtual GPU."
    }
    if (Test-Path $Rom) { Ok "ROM in place" } else { Stop-Setup "No ROM yet." }
}

# ---- 8. sharing ----

function Step-Share {
    Step 8 "Clipboard / file sharing (optional)"
    $marker = "$Root\re\vmshare-installed"
    if (Test-Path $marker) { Ok "guest agent installed (scripts\vm-share\install-guest.ps1 to reinstall)"; return }
    Todo "guest agent (VMShare) not installed by this setup"
    if ($Status) { return }
    Say "  Shares the clipboard (text, images, files) both ways and lets you drop files on the VM window."
    Say "  Needs Xcode's command line tools in macOS (the script tells you if they are missing)."
    if (-not (Ask "Install the guest agent now? (boots the VM; you type one command in Terminal)" $false)) { return }
    & "$PSScriptRoot\vm-share\install-guest.ps1" -Msys2 $Msys2
    if (Ask "Did the install in macOS finish with 'installed:'?") { New-Item -ItemType File -Force $marker | Out-Null }
}

# ---- 9. shortcut and start ----

function Step-Run {
    Step 9 "Start"
    $lnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "macOS (pvg).lnk"
    if (Test-Path $lnk) { Ok "desktop shortcut: $lnk" }
    else {
        Todo "no desktop shortcut"
        if (-not $Status -and (Ask "Create a desktop shortcut 'macOS (pvg)'?")) {
            $ws = New-Object -ComObject WScript.Shell
            $s = $ws.CreateShortcut($lnk)
            $s.TargetPath = "powershell.exe"
            $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\run-pvg-vm.ps1`""
            $s.WorkingDirectory = $Root
            $s.IconLocation = "$env:SystemRoot\System32\imageres.dll,184"
            $s.Description = "macOS VM with Metal on the host GPU (pvg-metal-vulkan)"
            $s.Save()
            Ok "shortcut created"
        }
    }
    if ($Status) { return }
    Say ""
    Say "Ready. Start the VM with the shortcut, or:" White
    Say "  powershell -ExecutionPolicy Bypass -File `"$PSScriptRoot\run-pvg-vm.ps1`""
    Say "Options: -DisplayMode sdl (SDL window), -Overlay (throwaway test run), -Ram 12G,"
    Say "-Cores 8; the full list is at the top of run-pvg-vm.ps1. To stop, shut macOS down (closing the"
    Say "window is like pulling the power plug)."
    if (Ask "Start it now?") { & "$PSScriptRoot\run-pvg-vm.ps1" }
}

# ---- main ----

Say "pvg-metal-vulkan setup for Windows" White
Say "  checkout: $Root"
Say "  VM folder (ULTMOS): $Ultmos"
if ($Status) { Say "  (status only)" }
Step-Checks
Step-Whpx
Step-Msys2
Step-LineEndings
Step-Build
Step-Vm
Step-Rom
Step-Share
Step-Run
if ($Status) { Pause-Here }
