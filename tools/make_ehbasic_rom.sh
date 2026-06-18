#!/usr/bin/env bash
# Build EhBASIC V2.22 ROM for SBC6502 emulator
# Downloads EhBASIC from GitHub, patches for SBC6502 memory layout,
# and assembles with ca65/ld65 into roms/ehbasic.rom (12KB, loaded at $D000)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT_DIR="$ROOT_DIR/tools/ehbasic_port"
WORK_DIR="$ROOT_DIR/tmp/ehbasic_build_$$"
OUT_ROM="$ROOT_DIR/roms/ehbasic.rom"
CACHE_DIR="$ROOT_DIR/tools/ehbasic_port/.cache"

EHBASIC_URL="https://raw.githubusercontent.com/Klaus2m5/6502_EhBASIC_V2.22/master/basic.asm"

echo "=== EhBASIC V2.22 ROM Builder for SBC6502 ==="
echo "Working directory: $WORK_DIR"
mkdir -p "$WORK_DIR" "$CACHE_DIR"

# -------------------------------------------------------
# Find Python (needed for line-count check only; sed does patching)
# -------------------------------------------------------
PYTHON_CMD=""
for candidate in \
    "/c/Users/rudol/AppData/Local/Programs/Python/Python312/python.exe" \
    "/c/Users/rudol/AppData/Local/Programs/Python/Python311/python.exe" \
    "/c/Users/rudol/AppData/Local/Programs/Python/Python310/python.exe" \
    "python3" "python" "py -3"
do
    if "$candidate" -c "import sys; sys.exit(0)" 2>/dev/null; then
        PYTHON_CMD="$candidate"
        break
    fi
done

# -------------------------------------------------------
# Find assembler
# -------------------------------------------------------
CA65_BIN="$(command -v ca65 2>/dev/null || true)"
LD65_BIN="$(command -v ld65 2>/dev/null || true)"
for try in "/c/Tools/cc65/bin/ca65.exe" "/c/tools/cc65/bin/ca65.exe"; do
    [[ -z "$CA65_BIN" && -x "$try" ]] && CA65_BIN="$try"
done
for try in "/c/Tools/cc65/bin/ld65.exe" "/c/tools/cc65/bin/ld65.exe"; do
    [[ -z "$LD65_BIN" && -x "$try" ]] && LD65_BIN="$try"
done

if [[ -z "$CA65_BIN" || -z "$LD65_BIN" ]]; then
    echo "ERROR: ca65/ld65 not found. Install cc65 first." >&2
    exit 1
fi
echo "Assembler: ca65 = $CA65_BIN"

# -------------------------------------------------------
# Download EhBASIC source (or use cache)
# -------------------------------------------------------
CACHED_ASM="$CACHE_DIR/basic.asm"

if [[ -f "$CACHED_ASM" ]]; then
    echo "Using cached EhBASIC: $CACHED_ASM"
else
    echo "Downloading EhBASIC V2.22 from GitHub..."
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 30 -o "$CACHED_ASM" "$EHBASIC_URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$CACHED_ASM" "$EHBASIC_URL"
    else
        echo "ERROR: Neither curl nor wget found." >&2
        exit 1
    fi
    echo "Downloaded EhBASIC source."
fi

# -------------------------------------------------------
# Patch EhBASIC source for SBC6502
#
# Changes:
#   1. Remove "*= $C000"   (wrapper/linker set ROM placement)
#   2. "Ram_top = $C000"   -> "Ram_top = $D000"  (top of user SRAM)
#   3. Convert bare label lines to ca65 label syntax ("LABEL" -> "LABEL:")
#
# Everything else is left untouched -- EhBASIC labels will be exported
# so our wrapper can reference LAB_COLD and CTRLC.
# -------------------------------------------------------
PATCHED_ASM="$WORK_DIR/basic.asm"
cp "$CACHED_ASM" "$PATCHED_ASM"

# Patch EhBASIC source into ca65-compatible form.
"$PYTHON_CMD" - "$PATCHED_ASM" <<'PY'
import sys
import re
path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='replace') as f:
    text = f.read()

# Remove embedded origin; linker config owns ROM placement.
text, n = re.subn(r'^\s*\*=\s*\$C000\s*(?:;.*)?\r?\n', '', text, count=1, flags=re.MULTILINE)
if n == 0:
    print(f"ERROR: could not find '*= $C000' in {path}", file=sys.stderr)
    sys.exit(1)
print("  Removed embedded origin (*= $C000)")

# Patch Ram_top
old_top = 'Ram_top\t\t= $C000'
new_top = 'Ram_top\t\t= $D000'
if old_top not in text:
    text, n = re.subn(r'(Ram_top\s*=\s*)\$C000', r'\g<1>$D000', text, count=1)
    if n == 0:
        print(f"ERROR: could not find 'Ram_top = $C000' in {path}", file=sys.stderr)
        sys.exit(1)
    print(f"  Patched Ram_top ($C000 -> $D000) [regex match]")
else:
    text = text.replace(old_top, new_top, 1)
    print(f"  Patched Ram_top ($C000 -> $D000)")

# Convert EhBASIC's immediate #[expr] syntax to ca65's #(expr).
text, immediate_fix_count = re.subn(r'#\[([^\]]+)\]', r'#(\1)', text)
print(f"  Converted {immediate_fix_count} bracketed immediate expressions")

# Route EhBASIC's STOP/Ctrl-C vector through the wrapper. The stock CTRLC
# routine consumes ordinary keyboard bytes while BASIC polls for Ctrl-C.
text, ctrlc_patch_count = re.subn(
    r'(\.word\s+)CTRLC(\s*;\s*ctrl c check vector)',
    r'\1EHB_CTRLC\2',
    text,
    count=1,
)
if ctrlc_patch_count != 1:
    print("ERROR: could not patch CTRLC vector to EHB_CTRLC", file=sys.stderr)
    sys.exit(1)
print("  Patched Ctrl-C vector -> EHB_CTRLC")

# ca65 requires labels to end with ':'. EhBASIC uses bare label lines
# starting in column 1, while opcodes are indented.
label_fix_count = 0
converted_lines = []
for line in text.splitlines(True):
    match = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)(\s*(?:;.*)?)?(\r?\n?)$', line)
    if match:
        line = f"{match.group(1)}:{match.group(2) or ''}{match.group(3)}"
        label_fix_count += 1
    converted_lines.append(line)
text = ''.join(converted_lines)
print(f"  Converted {label_fix_count} bare labels to ca65 syntax")

# Convert same-line data labels like `ERR_NF  .byte ...` to `ERR_NF: .byte ...`.
text, inline_data_fix_count = re.subn(
    r'^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s+)(\.(?:byte|word)\b.*)$',
    r'\1\2:\3\4',
    text,
    flags=re.MULTILINE,
)
print(f"  Converted {inline_data_fix_count} inline data labels")

with open(path, 'w', encoding='utf-8') as f:
    f.write(text)
print("  Patch complete.")
PY

echo "EhBASIC patched."

# -------------------------------------------------------
# Copy wrapper and patched EhBASIC to work dir
# -------------------------------------------------------
cp "$PORT_DIR/ehbasic_sbc6502.s" "$WORK_DIR/"
# basic.asm is already in WORK_DIR

# -------------------------------------------------------
# Create linker config: 12KB ROM at $D000-$FFFF
# -------------------------------------------------------
cat > "$WORK_DIR/ehbasic_sbc6502.cfg" << 'CFG'
MEMORY {
    ROM:     start = $D000, size = $2FFA, fill = yes, fillval = $EA, file = %O;
    VECTORS: start = $FFFA, size = $0006, fill = yes, fillval = $EA, file = %O;
}
SEGMENTS {
    EHBASIC: load = ROM, type = ro;
    VECTORS: load = VECTORS, type = ro;
}
CFG

echo ""
echo "Assembling..."
"$CA65_BIN" --cpu 65c02 -o "$WORK_DIR/build.o" "$WORK_DIR/ehbasic_sbc6502.s" 2>&1

echo "Linking..."
"$LD65_BIN" -C "$WORK_DIR/ehbasic_sbc6502.cfg" \
    -o "$OUT_ROM" \
    "$WORK_DIR/build.o" 2>&1

# Verify output
ROM_SIZE=$(wc -c < "$OUT_ROM" 2>/dev/null || echo 0)
echo ""
echo "=== Build complete ==="
echo "ROM: $OUT_ROM"
echo "Size: $ROM_SIZE bytes (expected 12288 = \$3000)"

if [[ "$ROM_SIZE" -ne 12288 ]]; then
    echo "WARNING: unexpected size (expected 12288 bytes)"
fi

# Cleanup
rm -rf "$WORK_DIR"
echo "Done."
