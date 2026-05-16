#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT_DIR="$ROOT_DIR/tools/msbasic_port"
WORK_DIR="/tmp/msbasic-build-sbc"
SRC_DIR="$WORK_DIR/msbasic"
OUT_ROM="$ROOT_DIR/roms/msbasic.rom"

if ! command -v ca65 >/dev/null 2>&1 || ! command -v ld65 >/dev/null 2>&1; then
  echo "error: ca65/ld65 not found. install cc65 first." >&2
  exit 1
fi

mkdir -p "$WORK_DIR"
if [[ ! -d "$SRC_DIR/.git" ]]; then
  git clone --depth 1 https://github.com/mist64/msbasic "$SRC_DIR"
else
  git -C "$SRC_DIR" pull --ff-only
fi

cp "$PORT_DIR/defines_sbc6502.s" "$SRC_DIR/"
cp "$PORT_DIR/sbc6502_extra.s" "$SRC_DIR/"
cp "$PORT_DIR/sbc6502_iscntc.s" "$SRC_DIR/"
cp "$PORT_DIR/sbc6502_loadsave.s" "$SRC_DIR/"
cp "$PORT_DIR/sbc6502.cfg" "$SRC_DIR/"

python3 - "$SRC_DIR" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1])

def patch_once(path: Path, needle: str, add: str):
    t = path.read_text()
    if add.strip() in t:
        return

    targets = [needle]
    if needle.endswith("\n"):
        targets.append(needle[:-1])

    for target in targets:
        if target in t:
            t = t.replace(target, target + ("\n" if not target.endswith("\n") else "") + add, 1)
            path.write_text(t)
            return

    raise RuntimeError(f"needle not found in {path}")

patch_once(
    src / "defines.s",
    '.elseif .def(w65c816sxb)\nW65C816SXB := 1\n.include "defines_w65c816sxb.s"\n',
    '.elseif .def(sbc6502)\nSBC6502 := 1\n.include "defines_sbc6502.s"\n',
)

patch_once(
    src / "extra.s",
    '.ifdef W65C816SXB\n.include "w65c816sxb_extra.s"\n.endif\n',
    '.ifdef SBC6502\n.include "sbc6502_extra.s"\n.endif\n',
)

patch_once(
    src / "iscntc.s",
    '.ifdef W65C816SXB\n.include "w65c816sxb_iscntc.s"\n.endif\n',
    '.ifdef SBC6502\n.include "sbc6502_iscntc.s"\n.endif\n',
)

patch_once(
    src / "loadsave.s",
    '.ifdef SYM1\n.include "sym1_loadsave.s"\n.endif\n',
    '.ifdef SBC6502\n.include "sbc6502_loadsave.s"\n.endif\n',
)

patch_once(
    src / "header.s",
    '.ifdef W65C816SXB\n; Disable emulation mode (is left on from the monitor)\n.setcpu "65816"\n        SEC ;set carry for emulation mode\n        XCE ;go into emulation mode\n.setcpu "65C02"\n        jsr INITUSBSERIAL\n\n        ; Add a small delay to allow monitor to connect the terminal after\n        ; starting execution\n        ldy #0\n        ldx #0\n@loop:\n        dex\n        bne @loop\n        dey\n        bne @loop\n        jmp COLD_START\n.endif\n',
    '.ifdef SBC6502\n        jmp COLD_START\n.endif\n',
)
PY

mkdir -p "$SRC_DIR/tmp"
(
  cd "$SRC_DIR"
  ca65 -D sbc6502 msbasic.s -o tmp/sbc6502.o
  ld65 -C sbc6502.cfg tmp/sbc6502.o -o tmp/sbc6502.bin -Ln tmp/sbc6502.lbl
)

mkdir -p "$(dirname "$OUT_ROM")"
python3 - "$SRC_DIR/tmp/sbc6502.bin" "$OUT_ROM" <<'PY'
from pathlib import Path
import sys

bin_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])

payload = bin_path.read_bytes()
if len(payload) > 0x4000:
    raise SystemExit(f"msbasic binary too large: {len(payload)} bytes")

rom = bytearray([0xEA] * 0x4000)
rom[0:len(payload)] = payload

# Standard 6502 vectors inside the 16KB ROM window ($C000-$FFFF).
rom[0x3FFA] = 0x00  # NMI low  -> $C000
rom[0x3FFB] = 0xC0
rom[0x3FFC] = 0x00  # RESET low -> $C000
rom[0x3FFD] = 0xC0
rom[0x3FFE] = 0x00  # IRQ low   -> $C000
rom[0x3FFF] = 0xC0

out_path.write_bytes(rom)
print(f"Packed 16KB ROM: {out_path} ({len(rom)} bytes)")
PY

echo "Built MS BASIC ROM: $OUT_ROM"
ls -l "$OUT_ROM"
