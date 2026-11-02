# Shared setup checks, sourced (not run) by scripts/setup.sh and the launchers: where everything
# lives, what a first run needs, and a report that tells a new user what is missing and in which
# order to set it up. The caller sets ROOT (this folder) first.
#
# Setup order (scripts/setup.sh walks through it):
#   1. host packages (build dependencies)   only needed to build QEMU (step 4)
#   2. KVM access (/dev/kvm)
#   3. the macOS VM: an ultimate-macOS-KVM (ULTMOS) checkout with an installed Tahoe VM
#   4. QEMU with the pvg device             scripts/build-qemu.sh
#   5. AppleParavirtEFI.rom                 scripts/collect-rom.sh (boots the VM from step 3)
#   optional: qemu-rdw viewer (Wayland), bridged network, clipboard/file sharing agent
#
# local.conf (not committed) keeps answers given to scripts/setup.sh, e.g. the VM location.

PVG_ROM_REL="re/collected/collected/frameworks/ParavirtualizedGraphics.framework/Versions/A/Resources/AppleParavirtEFI.rom"
PVG_ULTMOS_URL="https://github.com/Coopydood/ultimate-macOS-KVM"
PVG_RDW_URL="https://gitlab.com/marcandre.lureau/qemu-display.git"
PVG_RDW_COMMIT=6ffedb95967dcd864991e1ac581d9e9d62d3e84a   # patches/qemu-display apply on top
PVG_BRIDGE_HELPER=/usr/lib/qemu/qemu-bridge-helper

if [ -t 1 ]; then
    PVG_B=$'\e[1m'; PVG_OK=$'\e[32m'; PVG_BAD=$'\e[31m'; PVG_OPT=$'\e[33m'; PVG_N=$'\e[0m'
else
    PVG_B=; PVG_OK=; PVG_BAD=; PVG_OPT=; PVG_N=
fi

# local.conf only fills in what the environment does not set
pvg_load_config() {
    if [ -f "$ROOT/local.conf" ]; then . "$ROOT/local.conf"; fi
}

# a usable ULTMOS VM: the disks and firmware the launchers boot
pvg_vm_ok() {
    [ -f "$1/HDD.qcow2" ] && [ -f "$1/boot/OpenCore.qcow2" ] &&
        [ -f "$1/ovmf/OVMF_CODE.fd" ] && [ -f "$1/ovmf/OVMF_VARS.fd" ]
}

# ULTMOS: the environment / local.conf, else the ultimate-macOS-KVM checkout this folder sits in
# (pvg-metal-vulkan/ in its root), else one next to this folder
pvg_resolve_ultmos() {
    if [ -n "${ULTMOS:-}" ]; then PVG_ULTMOS_ENV=1; fi
    pvg_load_config
    if [ -z "${ULTMOS:-}" ]; then
        if [ -f "$ROOT/../main.py" ]; then ULTMOS="$(cd "$ROOT/.." && pwd)"
        else ULTMOS="$(cd "$ROOT/.." && pwd)/ultimate-macOS-KVM"; fi
    fi
}

# other places with an installed VM: this checkout's parent, the folders next to this one and
# next to the parent (pvg-metal-vulkan/ standalone or inside an ultimate-macOS-KVM checkout)
pvg_find_vms() {
    local d
    for d in "$ROOT/.." "$ROOT/.."/*/ "$ROOT/../.."/*/; do
        [ -d "$d" ] || continue
        d="$(cd "$d" && pwd)"
        if [ "$d" != "${ULTMOS:-}" ] && pvg_vm_ok "$d"; then echo "$d"; fi
    done | sort -u
}

# a ROM collected by another pvg-metal-vulkan checkout (same two levels as pvg_find_vms)
pvg_find_rom() {
    local f
    for f in "$ROOT/.."/*/"$PVG_ROM_REL" "$ROOT/../.."/*/"$PVG_ROM_REL" "$ROOT/../.."/*/pvg-metal-vulkan/"$PVG_ROM_REL"; do
        [ -f "$f" ] || continue
        f="$(cd "$(dirname "$f")" && pwd)/${f##*/}"
        [ "$f" != "$ROOT/$PVG_ROM_REL" ] && { echo "$f"; return 0; }
    done
    return 1
}

pvg_qemu_ok() {
    [ -x "$ROOT/src/qemu/build/qemu-system-x86_64" ] && [ -x "$ROOT/src/qemu/build/qemu-img" ]
}

# patches in patches/ that src/qemu does not have yet (after a git pull): build-qemu.sh adds them
pvg_patches_pending() {
    local all have
    all=$(ls "$ROOT"/patches/*.patch 2>/dev/null | wc -l)
    have=$(git -C "$ROOT/src/qemu" rev-list --count v11.1.3..HEAD 2>/dev/null || echo "$all")
    echo $((all > have ? all - have : 0))
}

pvg_pm() {
    local pm
    for pm in apt-get dnf pacman zypper; do command -v "$pm" >/dev/null && { echo "$pm"; return; }; done
    echo unknown
}

# LLVM >= 19 the way meson looks for it (llvm-config, llvm-config-NN)
pvg_llvm_ok() {
    local c v
    for c in llvm-config llvm-config-{19..30}; do
        v=$("$c" --version 2>/dev/null) || continue
        [ "${v%%.*}" -ge 19 ] 2>/dev/null && return 0
    done
    return 1
}

# missing QEMU build dependencies, one "label|apt|dnf|pacman" per line
pvg_missing_build_deps() {
    local pc
    command -v git >/dev/null || echo "git|git|git|git"
    command -v cc >/dev/null || echo "C compiler|build-essential|gcc|base-devel"
    command -v ninja >/dev/null || echo "ninja|ninja-build|ninja-build|ninja"
    command -v python3 >/dev/null || echo "python3|python3 python3-venv|python3|python"
    python3 -c 'import venv, ensurepip' 2>/dev/null || echo "python3 venv|python3-venv|python3|python"
    command -v pkg-config >/dev/null || echo "pkg-config|pkg-config|pkgconf-pkg-config|pkgconf"
    command -v gdbus-codegen >/dev/null || echo "gdbus-codegen|libglib2.0-dev-bin|glib2-devel|glib2"
    pvg_llvm_ok || echo "LLVM >= 19|llvm-19-dev|llvm-devel|llvm"
    command -v pkg-config >/dev/null || return 0
    for pc in "glib-2.0|libglib2.0-dev|glib2-devel|glib2" "pixman-1|libpixman-1-dev|pixman-devel|pixman" \
              "gtk+-3.0|libgtk-3-dev|gtk3-devel|gtk3" "sdl2|libsdl2-dev|SDL2-devel|sdl2" \
              "epoxy|libepoxy-dev|libepoxy-devel|libepoxy" "gbm|libgbm-dev|mesa-libgbm-devel|mesa" \
              "vulkan|libvulkan-dev|vulkan-loader-devel vulkan-headers|vulkan-icd-loader vulkan-headers" \
              "libpulse|libpulse-dev|pulseaudio-libs-devel|libpulse"; do
        pkg-config --exists "${pc%%|*}" || echo "$pc"
    done
}

# missing qemu-rdw build dependencies (same format)
pvg_missing_rdw_deps() {
    local pc
    command -v cargo >/dev/null || echo "cargo (Rust)|cargo|cargo|rust"
    command -v pkg-config >/dev/null || return 0
    for pc in "gtk4|libgtk-4-dev|gtk4-devel|gtk4" \
              "gstreamer-app-1.0|libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev|gstreamer1-devel gstreamer1-plugins-base-devel|gstreamer gst-plugins-base-libs" \
              "libusbredirhost|libusbredir-dev|usbredir-devel|usbredir" \
              "libusb-1.0|libusb-1.0-0-dev|libusb1-devel|libusb"; do
        pkg-config --exists "${pc%%|*}" || echo "$pc"
    done
}

# "label, label" and the install command for lines from pvg_missing_*_deps
pvg_dep_labels() { cut -d'|' -f1 | paste -sd, - | sed 's/,/, /g'; }
pvg_dep_install_cmd() {
    local col
    case "$(pvg_pm)" in
        apt-get) col=2; printf 'sudo apt-get install ' ;;
        dnf) col=3; printf 'sudo dnf install ' ;;
        pacman) col=4; printf 'sudo pacman -S --needed ' ;;
        *) printf '(install the development packages for the above with your package manager)\n'; return ;;
    esac
    cut -d'|' -f"$col" | tr ' ' '\n' | sort -u | paste -sd' ' -
}

pvg_kvm_problem() {
    if [ ! -e /dev/kvm ]; then
        echo "/dev/kvm does not exist: enable virtualization (VT-x / AMD-V) in the firmware setup and load kvm_intel or kvm_amd"
    elif [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
        echo "no access to /dev/kvm: sudo usermod -aG kvm $USER, then log out and in again"
    fi
}

pvg_bridge_ok() {
    [ -u "$PVG_BRIDGE_HELPER" ] && grep -qx "allow virbr0" /etc/qemu/bridge.conf 2>/dev/null
}

pvg_rdw_ok() { [ -x "$ROOT/tools/qemu-display/target/release/qemu-rdw" ]; }

# one report line: number, title, state (ok / missing / optional), detail
pvg_line() {
    local col
    case "$3" in ok) col=$PVG_OK ;; missing) col=$PVG_BAD ;; *) col=$PVG_OPT ;; esac
    printf ' %s. %-28s %s%-8s%s %s\n' "$1" "$2" "$col" "$3" "$PVG_N" "${4:-}"
}
pvg_hint() { printf '       %s\n' "$@"; }

# The ordered setup report. $1 = what the caller needs: run (everything), trace (no ROM).
# Sets PVG_MISSING to the number of required steps that are missing.
pvg_report() {
    local need="${1:-run}" deps pending vms rom kvm
    PVG_MISSING=0
    echo "${PVG_B}pvg-metal-vulkan setup, in this order:${PVG_N}"

    deps=$(pvg_missing_build_deps)
    if [ -z "$deps" ]; then pvg_line 1 "host build packages" ok
    elif pvg_qemu_ok || [ -n "${QEMU_OVERRIDE:-}" ]; then pvg_line 1 "host build packages" optional "QEMU is built; to rebuild it you need: $(pvg_dep_labels <<<"$deps")"
    else
        pvg_line 1 "host build packages" missing "$(pvg_dep_labels <<<"$deps")"
        pvg_hint "install: $(pvg_dep_install_cmd <<<"$deps")"
        PVG_MISSING=$((PVG_MISSING + 1))
    fi

    kvm=$(pvg_kvm_problem)
    if [ -z "$kvm" ]; then pvg_line 2 "KVM access" ok
    else pvg_line 2 "KVM access" missing "$kvm"; PVG_MISSING=$((PVG_MISSING + 1)); fi

    if pvg_vm_ok "$ULTMOS"; then pvg_line 3 "macOS VM (ULTMOS)" ok "$ULTMOS"
    else
        pvg_line 3 "macOS VM (ULTMOS)" missing "no installed VM in $ULTMOS"
        vms=$(pvg_find_vms)
        if [ -n "$vms" ]; then
            pvg_hint "found one in: $(head -1 <<<"$vms")" \
                "use it: ULTMOS=$(head -1 <<<"$vms") $0   (scripts/setup.sh can remember it)"
        else
            pvg_hint "create one with ULTMOS AutoPilot ($PVG_ULTMOS_URL):" \
                "  run ./main.py in the ultimate-macOS-KVM checkout, choose AutoPilot, macOS Tahoe (26)," \
                "  install macOS, then come back here (or set ULTMOS=path to an existing checkout)"
        fi
        PVG_MISSING=$((PVG_MISSING + 1))
    fi

    if [ -n "${QEMU_OVERRIDE:-}" ]; then pvg_line 4 "QEMU with the pvg device" ok "QEMU=$QEMU_OVERRIDE"
    elif pvg_qemu_ok; then
        pending=$(pvg_patches_pending)
        if [ "$pending" -gt 0 ]; then
            pvg_line 4 "QEMU with the pvg device" optional "$pending new patches not built yet: scripts/build-qemu.sh"
        else pvg_line 4 "QEMU with the pvg device" ok; fi
    else
        pvg_line 4 "QEMU with the pvg device" missing "not built (src/qemu/build)"
        pvg_hint "build: scripts/build-qemu.sh   (needs step 1; downloads QEMU v11.1.3, ~20-40 min)"
        PVG_MISSING=$((PVG_MISSING + 1))
    fi

    if [ -f "$ROOT/$PVG_ROM_REL" ]; then pvg_line 5 "AppleParavirtEFI.rom" ok
    elif [ "$need" = trace ]; then pvg_line 5 "AppleParavirtEFI.rom" optional "not collected (the trace VM does not need it)"
    else
        pvg_line 5 "AppleParavirtEFI.rom" missing "not collected from the guest yet"
        if rom=$(pvg_find_rom); then
            pvg_hint "another checkout has one: $rom" "scripts/setup.sh copies it (or: mkdir -p ${PVG_ROM_REL%/*} && cp it there)"
        else
            pvg_hint "collect it: scripts/collect-rom.sh   (needs step 3: boots the VM with stock graphics;" \
                "  in macOS open Terminal, run  sh /Volumes/PVGXFER/collect.sh rom  and shut down)"
        fi
        PVG_MISSING=$((PVG_MISSING + 1))
    fi

    echo "${PVG_B}optional:${PVG_N}"
    if pvg_rdw_ok; then pvg_line 6 "qemu-rdw viewer (Wayland)" ok
    else pvg_line 6 "qemu-rdw viewer (Wayland)" optional "not built: fastest window on Wayland (else gtk-gl); scripts/setup.sh builds it"; fi
    if pvg_bridge_ok; then pvg_line 7 "bridged network" ok
    else pvg_line 7 "bridged network" optional "slirp for now (QUIC/UDP stalls): sudo scripts/setup-bridge-net.sh"; fi
    pvg_line 8 "clipboard / file sharing" optional "once the VM runs: scripts/vm-share/install-guest.sh user@guest-ip"

    if [ "$PVG_MISSING" = 0 ]; then
        echo "${PVG_OK}ready:${PVG_N} scripts/run-pvg-vm.sh"
    else
        echo "${PVG_BAD}$PVG_MISSING required step(s) missing.${PVG_N} Guided setup (asks before downloading or changing anything): scripts/setup.sh"
    fi
}

# y/N question on the terminal; PVG_YES=1 answers yes. Without a terminal: no.
pvg_ask() {
    if [ "${PVG_YES:-0}" = 1 ]; then echo "$1 [y/n] y"; return 0; fi
    pvg_ask_human "$1"
}
# the same, never answered by PVG_YES: booting the VM or other steps that need someone at it
pvg_ask_human() {
    local a
    [ -t 0 ] || return 1
    read -r -p "$1 [y/N] " a || return 1
    [[ "$a" =~ ^[Yy] ]]
}

# For the launchers: return when everything $1 needs (run / trace) is there; otherwise show the
# report and offer the guided setup (interactive), or exit with the report (non-interactive).
pvg_preflight() {
    local need="$1"
    PVG_MISSING=0
    pvg_vm_ok "$ULTMOS" || PVG_MISSING=1
    [ -n "${QEMU_OVERRIDE:-}" ] || pvg_qemu_ok || PVG_MISSING=1
    [ "$need" = trace ] || [ -f "$ROOT/$PVG_ROM_REL" ] || PVG_MISSING=1
    [ -z "$(pvg_kvm_problem)" ] || PVG_MISSING=1
    [ "$PVG_MISSING" = 0 ] && return 0

    pvg_report "$need" >&2
    [ "$PVG_MISSING" = 0 ] && return 0
    if pvg_ask "Start the guided setup now?"; then
        "$ROOT/scripts/setup.sh" --for "$need" || exit 1
        # setup.sh may have saved the VM location in local.conf
        if [ -z "${PVG_ULTMOS_ENV:-}" ]; then ULTMOS=; pvg_resolve_ultmos; fi
        return 0
    fi
    exit 1
}
