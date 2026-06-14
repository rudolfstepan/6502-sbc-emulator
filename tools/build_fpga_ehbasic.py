#!/usr/bin/env python3
"""
Build the FPGA EhBASIC 16 KB ROM for UART monitor upload.

Pipeline:
  1. Read cached EhBASIC V2.22 source (tools/ehbasic_port/.cache/basic.asm).
     Aborts with a clear error if the cache is missing (run make_ehbasic_rom.sh
     or the emulator EhBASIC build once to populate it).
  2. Patch basic.asm for ca65 + FPGA:
       - remove embedded origin (*= $C000)
       - Ram_top = $8000   (FPGA SRAM ends at $7FFF; $8000+ is peripherals)
       - convert bracketed immediates  #[expr] -> #(expr)
       - convert bare label lines to ca65 syntax  LABEL -> LABEL:
       - convert inline data labels  FOO  .byte -> FOO:  .byte
  3. Assemble fpga/sw/ehbasic_fpga.s (which .includes the patched basic.asm).
  4. Link to a 12 KB binary (ehbasic ROM at $D000-$FFFF).
  5. Load roms/kernel.rom (4 KB, $C000-$CFFF).
  6. Combine: kernel (4 KB) || ehbasic (12 KB) -> 16 KB image.
  7. Write tools/roms/fpga_ehbasic_16kb.rom.

Optional flags:
  --upload          upload via UART monitor after building
  --port <port>     serial port (default COM15)
  --baud <baud>     serial baud rate (default: uploader default)
  --run             send G C000 after upload to start CPU

Usage:
  python tools/build_fpga_ehbasic.py
  python tools/build_fpga_ehbasic.py --upload --port COM15 --baud 230400 --run --verbose
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
ROOT        = Path(__file__).resolve().parent.parent
CACHE_ASM   = ROOT / "tools" / "ehbasic_port" / ".cache" / "basic.asm"
KERNEL_ROM  = ROOT / "roms" / "kernel.rom"
WRAPPER_S   = ROOT / "fpga" / "sw" / "ehbasic_fpga.s"
LINKER_CFG  = ROOT / "fpga" / "sw" / "ehbasic_fpga.cfg"
OUT_DIR     = ROOT / "tools" / "roms"
OUT_ROM     = OUT_DIR / "fpga_ehbasic_16kb.rom"
OUT_IMG     = OUT_DIR / "fpga_ehbasic_16kb.img"
SD_IMG_TOOL = ROOT / "fpga" / "tools" / "make_sd_boot_image.py"

KERNEL_SIZE  = 0x1000   # 4 KB
EHBASIC_SIZE = 0x3000   # 12 KB
TOTAL_SIZE   = KERNEL_SIZE + EHBASIC_SIZE  # 16 KB

CA65_CANDIDATES = [
    "C:/tools/cc65/bin/ca65.exe",
    "C:/Tools/cc65/bin/ca65.exe",
]
LD65_CANDIDATES = [
    "C:/tools/cc65/bin/ld65.exe",
    "C:/Tools/cc65/bin/ld65.exe",
]


# ---------------------------------------------------------------------------
# Toolchain detection
# ---------------------------------------------------------------------------
def find_tool(candidates: list[str], name: str) -> str:
    if path := shutil.which(name):
        return path
    for c in candidates:
        if Path(c).is_file():
            return c
    sys.exit(f"ERROR: {name} not found. Install cc65 (https://cc65.github.io/).")


# ---------------------------------------------------------------------------
# Patch basic.asm for ca65 + FPGA
# ---------------------------------------------------------------------------
def patch_basic_asm(src: Path, dst: Path) -> None:
    text = src.read_text(encoding="utf-8", errors="replace")

    # 1. Remove embedded origin
    text, n = re.subn(
        r"^\s*\*=\s*\$C000\s*(?:;.*)?\r?\n", "", text, count=1, flags=re.MULTILINE
    )
    if n == 0:
        sys.exit("ERROR: could not find '*= $C000' in basic.asm — wrong source?")
    print("  patched: removed *=$C000 origin")

    # 2. Set Ram_top = $8000 (FPGA SRAM ends at $7FFF)
    text, n = re.subn(r"(Ram_top\s*=\s*)\$C000", r"\g<1>$8000", text, count=1)
    if n == 0:
        sys.exit("ERROR: could not find 'Ram_top = $C000' in basic.asm")
    print("  patched: Ram_top $C000 -> $8000")

    # 2b. Relocate I/O vectors to ZP BRAM to avoid SDRAM indirect timing issue.
    # JMP (VEC_OUT) reads $E4/$E5 from ZP BRAM (single cycle) instead of
    # reading $0207/$0208 from SDRAM where sdram_if registered rdy causes
    # a one-cycle window where T65 can sample stale dout_reg.
    # VEC_CC ($0203) has the same issue: the BASIC inner loop calls JSR LAB_1629
    # -> JMP (VEC_CC) on every iteration.  Move it to $EA/$EB (ZP BRAM).
    # EhBASIC marks $E2-$EE unused; $E2/$E4/$E6/$E8 are our I/O vectors;
    # $EA/$EB are free for VEC_CC.
    patches = [
        (r"VEC_CC\s*=\s*ccnull\+1\b.*",   "VEC_CC\t\t= $EA\t\t; ctrl c check vector (ZP BRAM, was $0203)"),
        (r"VEC_IN\s*=\s*VEC_CC\+2\b.*",   "VEC_IN\t\t= $E2\t\t; input vector (ZP BRAM, was $0205)"),
        (r"VEC_OUT\s*=\s*VEC_IN\+2\b.*",  "VEC_OUT\t\t= $E4\t\t; output vector (ZP BRAM, was $0207)"),
        (r"VEC_LD\s*=\s*VEC_OUT\+2\b.*",  "VEC_LD\t\t= $E6\t\t; load vector (ZP BRAM, was $0209)"),
        (r"VEC_SV\s*=\s*VEC_LD\+2\b.*",   "VEC_SV\t\t= $E8\t\t; save vector (ZP BRAM, was $020B)"),
    ]
    for pattern, replacement in patches:
        text, n = re.subn(pattern, replacement, text, count=1)
        if n == 0:
            sys.exit(f"ERROR: could not patch '{pattern}' in basic.asm")
    print("  patched: VEC_CC/IN/OUT/LD/SV -> ZP BRAM $EA/$E2/$E4/$E6/$E8")

    # 2c. Bypass unreliable SDRAM write-read test in memory auto-detect.
    # LAB_COLD auto-detect (press Enter at "Memory size?") writes $55/$AA to
    # each SDRAM address and reads back immediately.  If the first test at $0301
    # fails (e.g., write-to-read turnaround issue in sdram_if), Itempl/h stays
    # at $0301 -> Ememl/h = $0301 (1 byte) -> immediate OOM.
    # Fix: pre-load Itempl=$FF, Itemph=$7F before the loop.  On the first
    # iteration: INC Itempl -> $00 (Z=1) -> falls through to INC Itemph -> $80
    # = hi(Ram_top) -> BEQ LAB_2DB6 exits immediately with Ememl/h = $8000.
    # Note: this patch runs before the bare-labels step (step 4), so the
    # label line is still "LAB_2D93\n" (no colon yet).
    old_autodet = (
        "\tBNE\tLAB_2DAA\t\t; branch if not null (user typed something)\n"
        "\n"
        "\tLDY\t#$00\t\t\t; else clear Y\n"
        "\t\t\t\t\t; character was null so get memory size the hard way\n"
        "\t\t\t\t\t; we get here with Y=0 and Itempl/h = Ram_base\n"
        "LAB_2D93\n"
    )
    new_autodet = (
        "\tBNE\tLAB_2DAA\t\t; branch if not null (user typed something)\n"
        "\n"
        "\tLDA\t#$FF\t\t\t; bypass SDRAM test: first INC->$00 (Z=1)\n"
        "\tSTA\tItempl\n"
        "\tLDA\t#(>Ram_top-1)\t\t; first INC Itemph->hi(Ram_top)->exit\n"
        "\tSTA\tItemph\n"
        "\tLDY\t#$00\t\t\t; else clear Y\n"
        "\t\t\t\t\t; Itempl/h preset: loop exits immediately at Ram_top\n"
        "\t\t\t\t\t; we get here with Y=0 and Itempl/h = Ram_top-1\n"
        "LAB_2D93\n"
    )
    if old_autodet not in text:
        sys.exit("ERROR: could not find auto-detect init block in basic.asm")
    text = text.replace(old_autodet, new_autodet, 1)
    print("  patched: auto-detect pre-init Itempl/h -> Ram_top-1 (bypasses SDRAM test)")

    # 3. Bracketed immediates  #[expr] -> #(expr)
    text, cnt = re.subn(r"#\[([^\]]+)\]", r"#(\1)", text)
    print(f"  patched: {cnt} bracketed immediate(s)")

    # 4. Bare labels  (line = only a label, no opcode) -> append ':'
    label_count = 0
    converted = []
    for line in text.splitlines(True):
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)(\s*(?:;.*)?)(\r?\n?)$", line)
        if m:
            line = f"{m.group(1)}:{m.group(2) or ''}{m.group(3)}"
            label_count += 1
        converted.append(line)
    text = "".join(converted)
    print(f"  patched: {label_count} bare labels -> ca65 syntax")

    # 5. Inline data labels  FOO  .byte/.word  -> FOO:  .byte/.word
    text, cnt = re.subn(
        r"^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s+)(\.(?:byte|word)\b.*)",
        r"\1\2:\3\4",
        text,
        flags=re.MULTILINE,
    )
    print(f"  patched: {cnt} inline data label(s)")

    dst.write_text(text, encoding="utf-8")


# ---------------------------------------------------------------------------
# Assemble + link
# ---------------------------------------------------------------------------
def build_ehbasic_rom(work: Path, ca65: str, ld65: str) -> bytes:
    asm_src  = work / "ehbasic_fpga.s"
    obj_file = work / "ehbasic_fpga.o"
    bin_file = work / "ehbasic_fpga.bin"
    cfg_file = work / "ehbasic_fpga.cfg"

    shutil.copy(WRAPPER_S, asm_src)
    shutil.copy(LINKER_CFG, cfg_file)

    # Assemble
    result = subprocess.run(
        [ca65, "--cpu", "65c02", "-o", str(obj_file), str(asm_src)],
        cwd=str(work),
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr)
        sys.exit("ERROR: ca65 assembly failed.")
    if result.stderr.strip():
        print(result.stderr)

    # Link
    result = subprocess.run(
        [ld65, "-C", str(cfg_file), "-o", str(bin_file), str(obj_file)],
        cwd=str(work),
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr)
        sys.exit("ERROR: ld65 link failed.")
    if result.stderr.strip():
        print(result.stderr)

    data = bin_file.read_bytes()
    if len(data) != EHBASIC_SIZE:
        sys.exit(
            f"ERROR: ehbasic binary is {len(data)} bytes, expected {EHBASIC_SIZE}."
        )
    return data


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--upload",   action="store_true", help="upload ROM via UART monitor")
    p.add_argument("--port",     default="COM15",     help="serial port (default COM15)")
    p.add_argument("--baud",     type=int,            help="serial baud rate (default: uploader default)")
    p.add_argument("--run",      action="store_true", help="send G C000 after upload")
    p.add_argument("--verbose",  action="store_true", help="verbose upload output")
    p.add_argument("--sd-image", action="store_true", help="also build SD card boot image (.img)")
    return p.parse_args()


def main() -> None:
    args = parse_args()

    print("=== FPGA EhBASIC ROM Builder ===")

    # Validate inputs
    if not CACHE_ASM.is_file():
        sys.exit(
            f"ERROR: EhBASIC source cache not found:\n  {CACHE_ASM}\n"
            "Run  tools/make_ehbasic_rom.sh  (or the emulator build) once to "
            "populate the cache."
        )
    if not KERNEL_ROM.is_file():
        sys.exit(
            f"ERROR: kernel ROM not found:\n  {KERNEL_ROM}\n"
            "Build it with  make -C tools/kernel  or copy it from the emulator."
        )

    ca65 = find_tool(CA65_CANDIDATES, "ca65")
    ld65 = find_tool(LD65_CANDIDATES, "ld65")
    print(f"ca65: {ca65}")
    print(f"ld65: {ld65}")

    with tempfile.TemporaryDirectory(prefix="fpga_ehbasic_") as tmp:
        work = Path(tmp)
        print(f"work dir: {work}")

        # Patch and place basic.asm in the work directory
        print("Patching basic.asm ...")
        patch_basic_asm(CACHE_ASM, work / "basic.asm")

        # Build the 12 KB EhBASIC binary
        print("Assembling ...")
        ehbasic_data = build_ehbasic_rom(work, ca65, ld65)
        print(f"  EhBASIC: {len(ehbasic_data)} bytes OK")

    # Load kernel
    kernel_data = KERNEL_ROM.read_bytes()
    if len(kernel_data) != KERNEL_SIZE:
        print(
            f"WARNING: kernel.rom is {len(kernel_data)} bytes "
            f"(expected {KERNEL_SIZE}); padding/truncating."
        )
    kernel_padded = (kernel_data + bytes([0xEA] * KERNEL_SIZE))[:KERNEL_SIZE]

    # Combine: kernel ($C000-$CFFF) || ehbasic ($D000-$FFFF) = 16 KB
    image = kernel_padded + ehbasic_data
    assert len(image) == TOTAL_SIZE

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    OUT_ROM.write_bytes(image)

    print(f"\nOutput: {OUT_ROM}")
    print(f"  Total: {len(image)} bytes ({len(image):#06x})")
    print(f"  Kernel  : {KERNEL_SIZE} bytes @ $C000-$CFFF")
    print(f"  EhBASIC : {EHBASIC_SIZE} bytes @ $D000-$FFFF")
    print(f"  Ram_top : $8000 (~31.5 KB BASIC RAM at $0200-$7FFF)")
    print(f"  Vectors : VEC_CC=$EA VEC_IN=$E2 VEC_OUT=$E4 VEC_LD=$E6 VEC_SV=$E8 (ZP BRAM)")

    if args.sd_image:
        print("\nBuilding SD boot image ...")
        sys.stdout.flush()
        subprocess.run(
            [sys.executable, str(SD_IMG_TOOL), "-o", str(OUT_IMG), str(OUT_ROM)],
            check=True,
        )
        print(f"SD image: {OUT_IMG}")
        print("  Write to SD card (Linux/macOS):")
        print(f"    dd if={OUT_IMG.name} of=/dev/sdX bs=512")
        print("  Write to SD card (Windows):")
        print(f"    tools\\write_sd.bat {OUT_IMG.name}")

    print("\nUpload command (UART monitor):")
    print(
        f"  python tools/upload_monitor_hex.py {OUT_ROM.name} "
        f"--port COM15 --baud 230400 --address 0xC000 --run --verbose"
    )
    print("  (run from the project root; press KEY0 on the board first)")

    if args.upload:
        uploader = ROOT / "tools" / "upload_monitor_hex.py"
        cmd = [
            sys.executable, str(uploader),
            str(OUT_ROM),
            "--port",    args.port,
            "--address", "0xC000",
        ]
        if args.baud:
            cmd.extend(["--baud", str(args.baud)])
        if args.run:
            cmd.append("--run")
        if args.verbose:
            cmd.append("--verbose")
        print(f"\nUploading to {args.port} ...")
        subprocess.run(cmd, check=True)

    print("\nDone.")


if __name__ == "__main__":
    main()
