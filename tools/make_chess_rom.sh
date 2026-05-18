#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT_DIR/tools/chess/chess.s"
CFG="$ROOT_DIR/tools/chess/chess.cfg"
OBJ="/tmp/chess_sbc.o"
OUT="$ROOT_DIR/roms/chess.rom"

CA65_BIN="$(command -v ca65 2>/dev/null || true)"
LD65_BIN="$(command -v ld65 2>/dev/null || true)"
if [[ -z "$CA65_BIN" && -x "/c/tools/cc65/bin/ca65.exe" ]]; then
    CA65_BIN="/c/tools/cc65/bin/ca65.exe"
fi
if [[ -z "$LD65_BIN" && -x "/c/tools/cc65/bin/ld65.exe" ]]; then
    LD65_BIN="/c/tools/cc65/bin/ld65.exe"
fi

if [[ -z "$CA65_BIN" || -z "$LD65_BIN" ]]; then
    echo "error: ca65/ld65 not found. install cc65 first." >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT")"

"$CA65_BIN" "$SRC" -o "$OBJ"
"$LD65_BIN" -C "$CFG" "$OBJ" -o "$OUT"

SIZE=$(wc -c < "$OUT")
echo "Built chess ROM: $OUT  ($SIZE bytes)"
ls -l "$OUT"