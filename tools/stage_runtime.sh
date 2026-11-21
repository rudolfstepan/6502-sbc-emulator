#!/usr/bin/env bash
set -eu
set -o pipefail

OUT_DIR="${1:-bin}"

mkdir -p "$OUT_DIR/roms" "$OUT_DIR/data/disk" "$OUT_DIR/data/sdcard"
OUT_DIR_REAL="$(cd "$OUT_DIR" && pwd -P)"
case "$OUT_DIR_REAL" in
    "$(pwd -P)"/*) ;;
    *) echo "Refusing to mirror runtime data outside workspace: $OUT_DIR_REAL" >&2; exit 1 ;;
esac

# Copy default runtime configs if present.
for cfg in sbc.ini ehbasic.ini fpga.ini chess.ini soundtest.ini avdemo.ini c64.ini nes.ini nes-sbc.ini; do
    if [[ -f "$cfg" ]]; then
        cp -f "$cfg" "$OUT_DIR/"
    fi
done

# Copy ROM payloads if present.
shopt -s nullglob
for rom in roms/*.rom; do
    cp -f "$rom" "$OUT_DIR/roms/"
done
if [[ -d roms/c64 ]]; then
    mkdir -p "$OUT_DIR/roms/c64"
    for rom in roms/c64/*.rom; do
        cp -f "$rom" "$OUT_DIR/roms/c64/"
    done
fi
shopt -u nullglob

FPGA_ROM_DIR="../6502-sbc-fpga/roms/6502"
for rom in fpga_ehbasic_16kb.rom mandelbrot_copro.bin; do
    if [[ -f "$FPGA_ROM_DIR/$rom" ]]; then
        cp -f "$FPGA_ROM_DIR/$rom" "$OUT_DIR/roms/"
    fi
done

# Mirror default disk folder content if present.
if [[ -d data/disk ]]; then
    find "$OUT_DIR/data/disk" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    cp -a data/disk/. "$OUT_DIR/data/disk/"
fi

if [[ -d data/sdcard ]]; then
    find "$OUT_DIR/data/sdcard" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    cp -a data/sdcard/. "$OUT_DIR/data/sdcard/"
fi
