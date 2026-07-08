#!/usr/bin/env bash
# Build the FPGA high-resolution rotating cube PRG.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."

CA65="${CA65:-ca65}"
LD65="${LD65:-ld65}"

mkdir -p "$ROOT/build/cube" "$ROOT/data/disk"

echo "Assembling cube.s ..."
"$CA65" -t none \
    -o "$ROOT/build/cube/cube.o" \
    "$ROOT/examples/cube.s"

echo "Linking cube PRG ..."
"$LD65" \
    -C "$ROOT/examples/cube.cfg" \
    "$ROOT/build/cube/cube.o" \
    -o "$ROOT/data/disk/cube.prg"

SIZE=$(wc -c < "$ROOT/data/disk/cube.prg")
echo "Built cube PRG: $ROOT/data/disk/cube.prg  ($SIZE bytes)"
ls -lh "$ROOT/data/disk/cube.prg"
