#!/usr/bin/env bash
# Build the FPGA hardware-blitter fireworks PRG.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."

CA65="${CA65:-ca65}"
LD65="${LD65:-ld65}"

mkdir -p "$ROOT/build/fireworks" "$ROOT/data/disk"

echo "Assembling fireworks.s ..."
"$CA65" -t none \
    -o "$ROOT/build/fireworks/fireworks.o" \
    "$ROOT/examples/fireworks.s"

echo "Linking fireworks PRG ..."
"$LD65" \
    -C "$ROOT/examples/cube.cfg" \
    "$ROOT/build/fireworks/fireworks.o" \
    -o "$ROOT/data/disk/fireworks.prg"

SIZE=$(wc -c < "$ROOT/data/disk/fireworks.prg")
echo "Built fireworks PRG: $ROOT/data/disk/fireworks.prg  ($SIZE bytes)"
ls -lh "$ROOT/data/disk/fireworks.prg"
