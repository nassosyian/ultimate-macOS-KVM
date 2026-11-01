#!/usr/bin/env bash
# Build the offline translator checker against the QEMU tree's air2spv.c / spv.c
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; P="$D/../../src/qemu/hw/display/pvg"
cc -O1 -g -I"$P" $(${LLVM_CONFIG:-llvm-config} --cflags) -o "$D/a2s-check" "$D/a2s-check.c" "$P/air2spv.c" "$P/spv.c" \
   $(${LLVM_CONFIG:-llvm-config} --ldflags --libs core bitreader analysis) -lm
