#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:-bin}"

mkdir -p "$OUT_DIR/roms" "$OUT_DIR/data/disk"

# Copy default runtime configs if present.
for cfg in sbc.ini ehbasic.ini chess.ini soundtest.ini; do
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

# Mirror default disk folder content if present.
if [[ -d data/disk ]]; then
    cp -a data/disk/. "$OUT_DIR/data/disk/"
fi
