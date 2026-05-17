#!/usr/bin/env bash
# Build the 6502 SBC kernel ROM (4KB at $C000)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT_DIR/tools/kernel/kernel.s"
CFG="$ROOT_DIR/tools/kernel/kernel.cfg"
OBJ="/tmp/kernel_sbc.o"
OUT="$ROOT_DIR/roms/kernel.rom"

if ! command -v ca65 >/dev/null 2>&1 || ! command -v ld65 >/dev/null 2>&1; then
    echo "error: ca65/ld65 not found. install cc65 first." >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT")"

ca65 "$SRC" -o "$OBJ"
ld65 -C "$CFG" "$OBJ" -o "$OUT"

SIZE=$(wc -c < "$OUT")
echo "Built kernel ROM: $OUT  ($SIZE bytes)"
ls -l "$OUT"
