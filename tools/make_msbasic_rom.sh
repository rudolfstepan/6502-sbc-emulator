#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT_DIR="$ROOT_DIR/tools/msbasic_port"
WORK_DIR="/tmp/msbasic-build-sbc"
SRC_DIR="$WORK_DIR/msbasic"
OUT_ROM="$ROOT_DIR/roms/msbasic.rom"

PYTHON_CMD=""
for candidate in "python3" "python" "py -3"; do
    if eval "$candidate -V >/dev/null 2>&1"; then
        PYTHON_CMD="$candidate"
        break
    fi
done

if [[ -z "$PYTHON_CMD" ]]; then
    echo "error: python interpreter not found (need python3, python, or py -3)." >&2
    exit 1
fi

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

mkdir -p "$WORK_DIR"
if [[ ! -d "$SRC_DIR/.git" ]]; then
  git clone --depth 1 https://github.com/mist64/msbasic "$SRC_DIR"
else
  git -C "$SRC_DIR" pull --ff-only
fi

# Reset source files to pristine state so patches apply cleanly
git -C "$SRC_DIR" checkout -- header.s defines.s extra.s iscntc.s loadsave.s init.s 2>/dev/null || true

cp "$PORT_DIR/defines_sbc6502.s" "$SRC_DIR/"
cp "$PORT_DIR/sbc6502_extra.s" "$SRC_DIR/"
cp "$PORT_DIR/sbc6502_iscntc.s" "$SRC_DIR/"
cp "$PORT_DIR/sbc6502_loadsave.s" "$SRC_DIR/"
cp "$PORT_DIR/sbc6502.cfg" "$SRC_DIR/"

$PYTHON_CMD - "$SRC_DIR" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1])

def replace_once(path: Path, old: str, new: str):
    t = path.read_text()
    if new.strip() in t:
        return  # already patched
    if old not in t:
        raise RuntimeError(f"needle not found in {path}: {repr(old[:60])}")
    path.write_text(t.replace(old, new, 1))

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

replace_once(
    src / "token.s",
    '\t\tkeyword_rts "NEW", NEW\n',
    '\t\tkeyword_rts "CLS", CLS\n'
    '\t\tkeyword_rts "NEW", NEW\n',
)

patch_once(
    src / "header.s",
    '.ifdef W65C816SXB\n; Disable emulation mode (is left on from the monitor)\n.setcpu "65816"\n        SEC ;set carry for emulation mode\n        XCE ;go into emulation mode\n.setcpu "65C02"\n        jsr INITUSBSERIAL\n\n        ; Add a small delay to allow monitor to connect the terminal after\n        ; starting execution\n        ldy #0\n        ldx #0\n@loop:\n        dex\n        bne @loop\n        dey\n        bne @loop\n        jmp COLD_START\n.endif\n',
    '.ifdef SBC6502\n        jmp COLD_START\n.endif\n',
)

# SBC6502: replace the entire memory-size prompt block (.ifndef CONFIG_CBM_ALL)
# with a SBC6502 / .else / original-code structure so that:
#   - For SBC6502 builds: MEMSIZ is pre-set to $7FFF (top of SRAM), FRETOP set
#     likewise, then jump past both prompts to SBC6502_INIT_DONE.
#   - The 'beq PR_WRITTEN_BY' branch is NOT assembled for SBC6502 (avoiding the
#     out-of-range branch error caused by the extra bytes).
#   - For all other builds: original code unchanged.
replace_once(
    src / "init.s",
    ".ifndef CONFIG_CBM_ALL\n"
    "        lda     #<QT_MEMORY_SIZE\n"
    "        ldy     #>QT_MEMORY_SIZE\n"
    "        jsr     STROUT\n"
    "  .ifdef APPLE\n"
    "        jsr     INLINX\n"
    "  .else\n"
    "        jsr     NXIN\n"
    "  .endif\n"
    "        stx     TXTPTR\n"
    "        sty     TXTPTR+1\n"
    "        jsr     CHRGET\n"
    "  .ifndef AIM65\n"
    "    .ifndef SYM1\n"
    "        cmp     #$41\n"
    "        beq     PR_WRITTEN_BY\n"
    "    .endif\n"
    "  .endif\n"
    "        tay\n"
    "        bne     L40EE\n"
    ".endif\n",
    ".ifndef CONFIG_CBM_ALL\n"
    ".ifdef SBC6502\n"
    "        ; SBC6502: pre-set memory to $7FFF (top of 32KB SRAM), skip prompts\n"
    "        lda     #$FF\n"
    "        sta     MEMSIZ\n"
    "        sta     FRETOP\n"
    "        lda     #$7F\n"
    "        sta     MEMSIZ+1\n"
    "        sta     FRETOP+1\n"
    "        jmp     SBC6502_INIT_DONE\n"
    ".else\n"
    "        lda     #<QT_MEMORY_SIZE\n"
    "        ldy     #>QT_MEMORY_SIZE\n"
    "        jsr     STROUT\n"
    "  .ifdef APPLE\n"
    "        jsr     INLINX\n"
    "  .else\n"
    "        jsr     NXIN\n"
    "  .endif\n"
    "        stx     TXTPTR\n"
    "        sty     TXTPTR+1\n"
    "        jsr     CHRGET\n"
    "  .ifndef AIM65\n"
    "    .ifndef SYM1\n"
    "        cmp     #$41\n"
    "        beq     PR_WRITTEN_BY\n"
    "    .endif\n"
    "  .endif\n"
    "        tay\n"
    "        bne     L40EE\n"
    ".endif\n"
    ".endif\n",
)

# SBC6502_INIT_DONE: entry point after all prompts — at RAMSTART2 setup
replace_once(
    src / "init.s",
    ".else\n        ldx     #<RAMSTART2\n        ldy     #>RAMSTART2\n.endif\n        stx     TXTTAB\n",
    ".else\nSBC6502_INIT_DONE:\n        ldx     #<RAMSTART2\n        ldy     #>RAMSTART2\n.endif\n        stx     TXTTAB\n",
)

replace_once(
    src / "init.s",
    "  .else\n        .byte   CR,LF,CR,LF\n  .endif\n",
    "  .else\n        .byte   CR,LF\n  .endif\n",
)
PY

mkdir -p "$SRC_DIR/tmp"
(
  cd "$SRC_DIR"
    "$CA65_BIN" -D sbc6502 msbasic.s -o tmp/sbc6502.o
    "$LD65_BIN" -C sbc6502.cfg tmp/sbc6502.o -o tmp/sbc6502.bin -Ln tmp/sbc6502.lbl
)

mkdir -p "$(dirname "$OUT_ROM")"
$PYTHON_CMD - "$SRC_DIR/tmp/sbc6502.bin" "$OUT_ROM" <<'PY'
from pathlib import Path
import sys

bin_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])

payload = bin_path.read_bytes()
if len(payload) > 0x3000:
    raise SystemExit(f"msbasic binary too large: {len(payload)} bytes (max 12288)")

rom = bytearray([0xEA] * 0x3000)   # 12 KB at $D000-$FFFF
rom[0:len(payload)] = payload

# 6502 vectors at end of 12KB ROM ($FFFA = $D000 + $2FFA).
# RESET points to kernel init at $C000; NMI and IRQ also handled by kernel.
rom[0x2FFA] = 0x1E  # NMI   low  -> $C01E  (NMI_HANDLER: RTI)
rom[0x2FFB] = 0xC0
rom[0x2FFC] = 0x00  # RESET low  -> $C000  (kernel INIT)
rom[0x2FFD] = 0xC0
rom[0x2FFE] = 0x1F  # IRQ   low  -> $C01F  (IRQ_HANDLER: RTI)
rom[0x2FFF] = 0xC0

out_path.write_bytes(rom)
print(f"Packed 12KB ROM: {out_path} ({len(rom)} bytes)")
PY

echo "Built MS BASIC ROM: $OUT_ROM"
ls -l "$OUT_ROM"
