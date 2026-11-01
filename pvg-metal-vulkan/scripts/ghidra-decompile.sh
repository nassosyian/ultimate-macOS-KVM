#!/usr/bin/env bash
# Headless Ghidra: import one binary, auto-analyze, export decompiled C + strings.
# Usage: scripts/ghidra-decompile.sh BINARY OUT_DIR [FUNCTION_NAME_REGEX]
# Output: OUT_DIR/<name>.c, OUT_DIR/<name>.strings.tsv; Ghidra project kept in re/ghidra-projects/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(realpath "$1")"
OUT="$(realpath -m "$2")"
export JAVA_HOME="$ROOT/tools/jdk-21.0.13+9"
PROJ="$ROOT/re/ghidra-projects"
mkdir -p "$PROJ" "$OUT"
exec "$ROOT/tools/ghidra_12.1.4_PUBLIC/support/analyzeHeadless" "$PROJ" "$(basename "$BIN")" \
    -import "$BIN" -overwrite \
    -scriptPath "$ROOT/scripts/ghidra" -postScript ExportDecomp.java "$OUT" ${3:+"$3"} \
    -max-cpu 16
