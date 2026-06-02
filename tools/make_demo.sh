#!/usr/bin/env bash
# Build the graphics demo ROM (demo.s → roms/demo.rom)
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."

CA65="${CA65:-ca65}"
LD65="${LD65:-ld65}"

mkdir -p "$ROOT/build/demo" "$ROOT/roms"

echo "Assembling demo.s ..."
"$CA65" -t none \
    -o "$ROOT/build/demo/demo.o" \
    "$ROOT/examples/demo.s"

echo "Linking demo ROM ..."
"$LD65" \
    -C "$ROOT/examples/demo.cfg" \
    "$ROOT/build/demo/demo.o" \
    -o "$ROOT/roms/demo.rom"

SIZE=$(wc -c < "$ROOT/roms/demo.rom")
echo "Built demo ROM: $ROOT/roms/demo.rom  ($SIZE bytes)"
ls -lh "$ROOT/roms/demo.rom"
