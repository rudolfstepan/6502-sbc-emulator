#!/usr/bin/env python3
"""
Build the PIX16 SDRAM Write Path Diagnostic ROM.

Assembles fpga/asm/diag_sdram.s into a 16 KB ROM image
($C000-$FFFF) suitable for upload via the UART monitor.

The ROM tests the CPU->SDRAM write path to diagnose the
EhBASIC '?SYNTAX ERROR on all commands' issue.
See fpga/docs/EHBASIC_SYNTAX_ERROR_ANALYSIS.md for details.

Usage:
  python fpga/tools/build_diag_sdram.py
  python fpga/tools/build_diag_sdram.py --upload --port COM15

Upload manually:
  python fpga/tools/upload_monitor_hex.py fpga/roms/diag_sdram.rom \\
      --port COM15 --address 0xC000 --run --verbose
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT       = Path(__file__).resolve().parent.parent.parent
DIAG_S     = ROOT / "fpga" / "asm" / "diag_sdram.s"
DIAG_CFG   = ROOT / "fpga" / "asm" / "diag_sdram.cfg"
OUT_DIR    = ROOT / "fpga" / "roms"
OUT_ROM    = OUT_DIR / "diag_sdram.rom"

ROM_SIZE   = 0x4000     # 16 KB ($C000-$FFFF)

CA65_CANDIDATES = [
    "C:/tools/cc65/bin/ca65.exe",
    "C:/Tools/cc65/bin/ca65.exe",
]
LD65_CANDIDATES = [
    "C:/tools/cc65/bin/ld65.exe",
    "C:/Tools/cc65/bin/ld65.exe",
]


def find_tool(candidates: list[str], name: str) -> str:
    if path := shutil.which(name):
        return path
    for c in candidates:
        if Path(c).is_file():
            return c
    sys.exit(f"ERROR: {name} not found. Install cc65 (https://cc65.github.io/).")


def build(work: Path, ca65: str, ld65: str) -> bytes:
    asm_src  = work / "diag_sdram.s"
    obj_file = work / "diag_sdram.o"
    bin_file = work / "diag_sdram.bin"
    cfg_file = work / "diag_sdram.cfg"

    shutil.copy(DIAG_S,   asm_src)
    shutil.copy(DIAG_CFG, cfg_file)

    # Assemble (6502 mode — T65 runs as NMOS 6502)
    r = subprocess.run(
        [ca65, "--cpu", "6502", "-o", str(obj_file), str(asm_src)],
        cwd=str(work), capture_output=True, text=True,
    )
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr)
        sys.exit("ERROR: ca65 assembly failed.")
    if r.stderr.strip():
        print(r.stderr)

    # Link
    r = subprocess.run(
        [ld65, "-C", str(cfg_file), "-o", str(bin_file), str(obj_file)],
        cwd=str(work), capture_output=True, text=True,
    )
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr)
        sys.exit("ERROR: ld65 link failed.")
    if r.stderr.strip():
        print(r.stderr)

    data = bin_file.read_bytes()
    if len(data) != ROM_SIZE:
        sys.exit(
            f"ERROR: output is {len(data)} bytes, expected {ROM_SIZE} (16 KB)."
        )
    return data


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--upload",  action="store_true", help="upload via UART monitor after build")
    p.add_argument("--port",    default="COM15",     help="serial port (default COM15)")
    p.add_argument("--verbose", action="store_true", help="verbose upload output")
    return p.parse_args()


def main() -> None:
    args = parse_args()

    print("=== PIX16 SDRAM Diagnostic ROM Builder ===")

    if not DIAG_S.is_file():
        sys.exit(f"ERROR: {DIAG_S} not found.")
    if not DIAG_CFG.is_file():
        sys.exit(f"ERROR: {DIAG_CFG} not found.")

    ca65 = find_tool(CA65_CANDIDATES, "ca65")
    ld65 = find_tool(LD65_CANDIDATES, "ld65")
    print(f"ca65: {ca65}")
    print(f"ld65: {ld65}")

    with tempfile.TemporaryDirectory(prefix="pix16_diag_") as tmp:
        work = Path(tmp)
        print(f"work dir: {work}")
        print("Assembling diag_sdram.s ...")
        rom = build(work, ca65, ld65)
        print(f"  OK: {len(rom)} bytes")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    OUT_ROM.write_bytes(rom)
    print(f"\nOutput: {OUT_ROM}")
    print(f"  Size:    {len(rom)} bytes ({len(rom):#06x})")
    print(f"  Range:   $C000-$FFFF")
    print(f"  Vectors: $FFFA-$FFFF -> DIAG_ENTRY ($C000)")

    print("\nUpload command:")
    print(
        f"  python fpga/tools/upload_monitor_hex.py {OUT_ROM.name} "
        f"--port COM15 --address 0xC000 --run --verbose"
    )
    print("  (press KEY0 on the board first to enter monitor mode)")

    if args.upload:
        uploader = ROOT / "fpga" / "tools" / "upload_monitor_hex.py"
        cmd = [
            sys.executable, str(uploader),
            str(OUT_ROM),
            "--port",    args.port,
            "--address", "0xC000",
            "--run",
        ]
        if args.verbose:
            cmd.append("--verbose")
        print(f"\nUploading to {args.port} ...")
        subprocess.run(cmd, check=True)

    print("\nDone.")


if __name__ == "__main__":
    main()
