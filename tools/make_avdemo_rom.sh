#!/usr/bin/env bash
# Build the audio-visual demo ROM (avdemo.s → roms/avdemo.rom)
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."

CA65="${CA65:-ca65}"
LD65="${LD65:-ld65}"

mkdir -p "$ROOT/build/avdemo" "$ROOT/roms"

echo "Assembling avdemo.s ..."
"$CA65" -t none \
    -o "$ROOT/build/avdemo/avdemo.o" \
    "$ROOT/examples/avdemo.s"

echo "Linking avdemo ROM ..."
"$LD65" \
    -C "$ROOT/examples/avdemo.cfg" \
    "$ROOT/build/avdemo/avdemo.o" \
    -o "$ROOT/roms/avdemo.rom"

SIZE=$(wc -c < "$ROOT/roms/avdemo.rom")
echo "Built avdemo ROM: $ROOT/roms/avdemo.rom  ($SIZE bytes)"
ls -lh "$ROOT/roms/avdemo.rom"
