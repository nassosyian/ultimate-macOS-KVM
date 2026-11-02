#!/usr/bin/env bash
# Build QEMU with the pvg-linux-pci device from a fresh checkout: clones QEMU v11.1.3 into
# src/qemu, applies patches/*.patch with git am, configures and builds it (src/qemu/build).
# Later runs reuse src/qemu, apply only patches added since (e.g. after a git pull) and rebuild.
#   JOBS=N            parallel compile jobs (default: all CPUs)
#   QEMU_REPO=URL     where to clone QEMU from (default: gitlab.com/qemu-project/qemu)
# Needs QEMU's build dependencies (ninja, python3, glib2, pixman, libslirp, gtk3, SDL2, epoxy),
# Vulkan development files and LLVM >= 19 (llvm-config / llvm-config-19).
# Windows: run it in an MSYS2 UCRT64 shell (packages: see README, "Windows host"); the build
# uses the Windows Hypervisor Platform (WHPX) instead of KVM.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src/qemu"
TAG=v11.1.3
REPO="${QEMU_REPO:-https://gitlab.com/qemu-project/qemu.git}"
JOBS="${JOBS:-$(nproc)}"
case "$(uname -s)" in
    MINGW*|MSYS*) WINDOWS=1; ACCEL=--enable-whpx; EXE=.exe ;;
    *) WINDOWS=0; ACCEL=--enable-kvm; EXE= ;;
esac
if [ "$WINDOWS" = 1 ] && [ "${MSYSTEM:-}" != UCRT64 ]; then
    echo "run this in an MSYS2 UCRT64 shell (MSYSTEM=UCRT64)" >&2
    exit 1
fi
# name the missing packages before downloading QEMU, not as a configure error later
if [ "$WINDOWS" = 0 ]; then
    . "$ROOT/scripts/lib/setup-common.sh"
    DEPS=$(pvg_missing_build_deps)
    if [ -n "$DEPS" ]; then
        echo "missing build dependencies: $(pvg_dep_labels <<<"$DEPS")" >&2
        echo "install them: $(pvg_dep_install_cmd <<<"$DEPS")   (or run scripts/setup.sh)" >&2
        exit 1
    fi
fi

if [ ! -d "$SRC/.git" ]; then
    echo "== cloning QEMU $TAG"
    mkdir -p "$ROOT/src"
    # no CRLF conversion: the patches must apply to the files byte for byte
    git -c core.autocrlf=false clone --depth 1 --branch "$TAG" "$REPO" "$SRC"
    git -C "$SRC" checkout -q -b pvg
fi
# the patches are applied in order, one commit each: apply the ones src/qemu does not have yet
PATCHES=("$ROOT"/patches/*.patch)
HAVE=$(git -C "$SRC" rev-list --count "$TAG..HEAD")
if [ "$HAVE" -lt "${#PATCHES[@]}" ]; then
    # git am records a committer; use a local one if git has none configured
    ID=()
    git -C "$SRC" config user.email >/dev/null || ID=(-c user.name="pvg build" -c user.email=pvg@localhost)
    echo "== applying $((${#PATCHES[@]} - HAVE)) patches"
    git -C "$SRC" -c core.autocrlf=false "${ID[@]}" am -q "${PATCHES[@]:$HAVE}"
fi

if [ ! -f "$SRC/build/build.ninja" ]; then
    echo "== configuring"
    mkdir -p "$SRC/build"
    (cd "$SRC/build" && ../configure --target-list=x86_64-softmmu "$ACCEL" --enable-slirp \
        --enable-vnc --enable-opengl --enable-gtk --enable-sdl --enable-download \
        --disable-docs --disable-werror)
    # without Vulkan or LLVM the device builds as a stub that cannot execute Metal
    for dep in vulkan LLVM; do
        grep -q "Run-time dependency $dep found: YES" "$SRC/build/meson-logs/meson-log.txt" || {
            echo "$dep not found: install its development files, delete src/qemu/build and rerun" >&2
            exit 1
        }
    done
fi

echo "== building ($JOBS jobs)"
# the whole tree, not just qemu-system-x86_64: qemu-img and the VNC keymaps are needed too
ninja -C "$SRC/build" -j "$JOBS"
BIN="$SRC/build/qemu-system-x86_64$EXE"
# ninja failures stop the script (set -e); also catch a binary left over from an older configure
if [ ! -x "$BIN" ] || [ ! "$BIN" -nt "$SRC/build/build.ninja" ]; then
    echo "build failed: $BIN is missing or stale" >&2
    exit 1
fi
echo "== done: $BIN"
