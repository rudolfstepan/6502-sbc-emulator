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
for cfg in sbc.ini ehbasic.ini fpga.ini chess.ini soundtest.ini avdemo.ini; do
    if [[ -f "$cfg" ]]; then
        cp -f "$cfg" "$OUT_DIR/"
    fi
done

# Copy ROM payloads if present.
shopt -s nullglob
for rom in roms/*.rom; do
    cp -f "$rom" "$OUT_DIR/roms/"
done
shopt -u nullglob

FPGA_ROM="../6502-sbc-fpga/roms/6502/fpga_ehbasic_16kb.rom"
if [[ -f "$FPGA_ROM" ]]; then
    cp -f "$FPGA_ROM" "$OUT_DIR/roms/"
fi

# Mirror default disk folder content if present.
if [[ -d data/disk ]]; then
    find "$OUT_DIR/data/disk" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    cp -a data/disk/. "$OUT_DIR/data/disk/"
fi

if [[ -d data/sdcard ]]; then
    find "$OUT_DIR/data/sdcard" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    cp -a data/sdcard/. "$OUT_DIR/data/sdcard/"
fi
