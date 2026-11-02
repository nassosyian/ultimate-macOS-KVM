#!/usr/bin/env bash
# Guided first-time setup (Linux host): checks every step scripts/run-pvg-vm.sh needs, in order,
# and for each missing one offers to do it (asks first: nothing is downloaded, installed or booted
# without a yes) or prints what to do by hand. Rerun it any time; finished steps are skipped.
#   scripts/setup.sh              guided setup
#   scripts/setup.sh --check      only the report (exit 1 when a required step is missing)
#   scripts/setup.sh --yes        answer yes to every question, except booting the VM
#   --for trace                   what scripts/run-trace-vm.sh needs (no ROM)
# Order: 1 host packages, 2 KVM access, 3 the macOS VM (ULTMOS), 4 QEMU (scripts/build-qemu.sh),
# 5 AppleParavirtEFI.rom (scripts/collect-rom.sh), then optional: qemu-rdw viewer, bridged network,
# clipboard/file sharing. Answers that must persist (the VM location) go to local.conf.
# Windows: use setup-windows.cmd instead.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/setup-common.sh"

CHECK=0; NEED=run
while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK=1 ;;
        --yes|-y) export PVG_YES=1 ;;
        --for) NEED="$2"; shift ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
done
case "$(uname -s)" in MINGW*|MSYS*) echo "on Windows run setup-windows.cmd instead" >&2; exit 1 ;; esac

QEMU_OVERRIDE="${QEMU:-}"
pvg_resolve_ultmos
# without a terminal nobody can answer: report only
if [ "$CHECK" = 1 ] || { [ ! -t 0 ] && [ "${PVG_YES:-0}" != 1 ]; }; then
    pvg_report "$NEED"
    [ "$PVG_MISSING" = 0 ]; exit
fi

step() { echo; echo "${PVG_B}== $*${PVG_N}"; }
save_ultmos() {
    local conf="$ROOT/local.conf"
    touch "$conf"
    grep -v 'ULTMOS:=' "$conf" > "$conf.tmp" || true
    printf ': "${ULTMOS:=%s}"   # the ULTMOS VM (scripts/setup.sh)\n' "$1" >> "$conf.tmp"
    mv "$conf.tmp" "$conf"
    ULTMOS="$1"
    echo "saved in local.conf: ULTMOS=$1"
}
install_deps() {    # $1 = lines from pvg_missing_*_deps
    local cmd
    cmd=$(pvg_dep_install_cmd <<<"$1")
    echo "missing: $(pvg_dep_labels <<<"$1")"
    case "$cmd" in
        sudo*)
            echo "install command: $cmd"
            if pvg_ask "Run it now (asks for your sudo password)?"; then $cmd || echo "package install failed" >&2
            else echo "skipped: run it yourself, then rerun scripts/setup.sh"; fi ;;
        *) echo "$cmd" ;;
    esac
}

echo "This walks through the setup in order and asks before each change."
pvg_report "$NEED"

step "1. host build packages (needed to build QEMU)"
deps=$(pvg_missing_build_deps)
if [ -z "$deps" ]; then echo "ok"
elif pvg_qemu_ok && [ "$(pvg_patches_pending)" = 0 ]; then echo "QEMU is already built; skipping ($(pvg_dep_labels <<<"$deps") only needed to rebuild)"
else install_deps "$deps"; fi

step "2. KVM access"
kvm=$(pvg_kvm_problem)
if [ -z "$kvm" ]; then echo "ok"
else
    echo "$kvm"
    if [ -e /dev/kvm ] && pvg_ask "Add $USER to the kvm group now (sudo usermod -aG kvm $USER)?"; then
        sudo usermod -aG kvm "$USER" && echo "done: log out and in again for it to take effect"
    fi
fi

step "3. macOS VM (ULTMOS)"
if pvg_vm_ok "$ULTMOS"; then echo "ok: $ULTMOS"
else
    echo "no installed VM in $ULTMOS (needs HDD.qcow2, boot/OpenCore.qcow2, ovmf/OVMF_CODE.fd, ovmf/OVMF_VARS.fd)"
    found=0
    mapfile -t vms < <(pvg_find_vms)    # not a while-read loop: pvg_ask needs the terminal on stdin
    for vm in "${vms[@]}"; do
        if pvg_ask "Found a VM in $vm. Use it (saved in local.conf)?"; then save_ultmos "$vm"; found=1; break; fi
    done
    if [ "$found" = 0 ]; then
        echo "Create one with ULTMOS AutoPilot: macOS Tahoe (26), then rerun this script."
        echo "(Or set ULTMOS=/path/to/ultimate-macOS-KVM for a checkout with an installed VM.)"
        if [ -f "$ULTMOS/main.py" ]; then
            if pvg_ask_human "Start ULTMOS (./main.py in $ULTMOS) now to run AutoPilot?"; then (cd "$ULTMOS" && ./main.py) || true; fi
        elif pvg_ask "Download ULTMOS ($PVG_ULTMOS_URL) to $ULTMOS?"; then
            git clone "$PVG_ULTMOS_URL" "$ULTMOS" && echo "next: cd $ULTMOS && ./main.py, choose AutoPilot, install macOS Tahoe"
        else
            echo "manually: git clone $PVG_ULTMOS_URL; cd ultimate-macOS-KVM; ./main.py"
        fi
    fi
fi

step "4. QEMU with the pvg device"
if [ -n "${QEMU:-}" ]; then echo "QEMU=$QEMU set: not building"
elif pvg_qemu_ok && [ "$(pvg_patches_pending)" = 0 ]; then echo "ok"
else
    if pvg_qemu_ok; then echo "$(pvg_patches_pending) patches are newer than the build (rebuild: a few minutes)"
    else echo "not built. scripts/build-qemu.sh downloads QEMU v11.1.3 from gitlab.com, applies patches/ and builds it (~20-40 min)"; fi
    deps=$(pvg_missing_build_deps)
    if [ -n "$deps" ]; then
        echo "cannot build yet, step 1 is missing: $(pvg_dep_labels <<<"$deps")"
    elif pvg_ask "Run scripts/build-qemu.sh now?"; then
        "$ROOT/scripts/build-qemu.sh" || echo "build failed: see the output above; fix it and rerun scripts/build-qemu.sh" >&2
    else
        echo "manually: scripts/build-qemu.sh   (JOBS=N to limit parallel jobs)"
    fi
fi

step "5. AppleParavirtEFI.rom (the device's option ROM, from your own guest)"
if [ -f "$ROOT/$PVG_ROM_REL" ]; then echo "ok"
elif [ "$NEED" = trace ]; then echo "not collected (not needed for the trace VM)"
else
    if rom=$(pvg_find_rom) && pvg_ask "Another checkout has the ROM ($rom). Copy it here?"; then
        mkdir -p "$(dirname "$ROOT/$PVG_ROM_REL")" && cp "$rom" "$ROOT/$PVG_ROM_REL" && echo "copied"
    fi
    if [ ! -f "$ROOT/$PVG_ROM_REL" ]; then
        if ! pvg_vm_ok "$ULTMOS"; then
            echo "needs step 3 first: scripts/collect-rom.sh boots the VM once to copy the ROM out of macOS"
        else
            echo "scripts/collect-rom.sh boots the VM in $ULTMOS (its real disk, with its own boot.sh and"
            echo "stock graphics) once, with a transfer disk attached (~5 min, you work in the guest):"
            echo "in macOS open Terminal, run  sh /Volumes/PVGXFER/collect.sh rom  and shut the VM down."
            if pvg_ask_human "Boot $ULTMOS/HDD.qcow2 for that now?"; then
                ULTMOS="$ULTMOS" "$ROOT/scripts/collect-rom.sh" || echo "ROM not collected; rerun scripts/collect-rom.sh" >&2
            else
                echo "manually: scripts/collect-rom.sh"
            fi
        fi
    fi
fi

step "6. optional: qemu-rdw viewer (Wayland's fastest window; without it gtk-gl is used)"
RDW="$ROOT/tools/qemu-display"
if pvg_rdw_ok; then echo "ok"
elif [ -z "${WAYLAND_DISPLAY:-}" ]; then echo "not needed on X11"
elif pvg_ask "Build qemu-rdw (downloads qemu-display from gitlab.com and its Rust crates, ~5-10 min)?"; then
    deps=$(pvg_missing_rdw_deps)
    if [ -n "$deps" ]; then install_deps "$deps"; deps=$(pvg_missing_rdw_deps); fi
    if [ -n "$deps" ]; then
        echo "skipped: still missing $(pvg_dep_labels <<<"$deps")"
    else
        (
            set -e
            if [ ! -d "$RDW/.git" ]; then
                git clone "$PVG_RDW_URL" "$RDW"
                git -C "$RDW" checkout -q -b pvg "$PVG_RDW_COMMIT"
                ID=(); git -C "$RDW" config user.email >/dev/null || ID=(-c user.name="pvg build" -c user.email=pvg@localhost)
                git -C "$RDW" "${ID[@]}" am -q "$ROOT"/patches/qemu-display/*.patch
                # pure-Rust rdw4: no system-wide librdw4 needed
                sed -i 's/^\(rdw = { package = "rdw4", version = "0.1"\), features = \["bindings"\] }/\1 }/' "$RDW/qemu-rdw/Cargo.toml"
            fi
            cd "$RDW" && cargo build --release -p qemu-rdw
        ) || echo "qemu-rdw build failed (the launcher falls back to gtk-gl)" >&2
    fi
else
    echo "manually: see README, Run (clone into tools/qemu-display, cargo build --release -p qemu-rdw)"
fi

step "7. optional: bridged network (slirp stalls on QUIC/UDP, e.g. Safari with iCloud Private Relay)"
if pvg_bridge_ok; then echo "ok"
elif pvg_ask "Set it up now (sudo scripts/setup-bridge-net.sh: setuid qemu-bridge-helper, libvirt's virbr0)?"; then
    sudo "$ROOT/scripts/setup-bridge-net.sh" || echo "bridge setup failed; the VM uses slirp" >&2
else
    echo "later: sudo scripts/setup-bridge-net.sh"
fi

step "8. optional: clipboard / file sharing with the guest"
echo "once the VM runs (and has an address, e.g. with step 7): scripts/vm-share/install-guest.sh user@guest-ip"

echo
pvg_report "$NEED"
[ "$PVG_MISSING" = 0 ]
