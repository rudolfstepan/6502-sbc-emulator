#!/usr/bin/env bash
# Build the sound test ROM (soundtest.s → roms/soundtest.rom)
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."

CA65="${CA65:-ca65}"
LD65="${LD65:-ld65}"

mkdir -p "$ROOT/build/soundtest" "$ROOT/roms"

echo "Assembling soundtest.s ..."
"$CA65" -t none \
    -o "$ROOT/build/soundtest/soundtest.o" \
    "$ROOT/tools/soundtest/soundtest.s"

echo "Linking soundtest ROM ..."
"$LD65" \
    -C "$ROOT/tools/soundtest/soundtest.cfg" \
    "$ROOT/build/soundtest/soundtest.o" \
    -o "$ROOT/roms/soundtest.rom"

SIZE=$(wc -c < "$ROOT/roms/soundtest.rom")
echo "Built soundtest ROM: $ROOT/roms/soundtest.rom  ($SIZE bytes)"
ls -lh "$ROOT/roms/soundtest.rom"
