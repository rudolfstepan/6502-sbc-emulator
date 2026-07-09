#!/usr/bin/env bash
# Build the FPGA hardware-blitter water PRG.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."

CA65="${CA65:-ca65}"
LD65="${LD65:-ld65}"

mkdir -p "$ROOT/build/water" "$ROOT/data/disk"

echo "Assembling water.s ..."
"$CA65" -t none \
    -o "$ROOT/build/water/water.o" \
    "$ROOT/examples/water.s"

echo "Linking water PRG ..."
"$LD65" \
    -C "$ROOT/examples/cube.cfg" \
    "$ROOT/build/water/water.o" \
    -o "$ROOT/data/disk/water.prg"

SIZE=$(wc -c < "$ROOT/data/disk/water.prg")
echo "Built water PRG: $ROOT/data/disk/water.prg  ($SIZE bytes)"
ls -lh "$ROOT/data/disk/water.prg"
