"""Add a title screen to a directory of existing FPGA SID split ROMs."""

import argparse
from pathlib import Path
import re
import subprocess
import tempfile

from build_sid_rom import ROM_SIZE, ROOT, TOOL_DIR, find_tool, run_tool
from rom_screen import DEFAULT_CREDIT, SCREEN_CODE, bytes_directive, title_screen
from sid_metadata import read_sid_metadata


SPLASH_ADDRESS = 0xF800
SPLASH_OFFSET = 0x3800
VECTOR_OFFSET = 0x3FFA
RESET_PROLOGUE = bytes.fromhex("78 D8 A2 FF 9A")  # SEI, CLD, LDX #$FF, TXS


def rom_title(source: Path, sid: Path, credit: str, build: Path, ca65: str, ld65: str) -> bytes:
    original = source.read_bytes()
    if len(original) != ROM_SIZE:
        raise ValueError("expected a 16 KiB FPGA split ROM")
    reset = int.from_bytes(original[-4:-2], "little")
    entry_offset = {0xA000: 0, 0xF000: 0x3000}.get(reset)
    if entry_offset is None or not original.startswith(RESET_PROLOGUE, entry_offset):
        raise ValueError("unrecognised native SID reset entry")
    if any(byte != 0xEA for byte in original[SPLASH_OFFSET:VECTOR_OFFSET]):
        raise ValueError("the kernel ROM has no reserved title-screen space")

    metadata = read_sid_metadata(sid, allow_rsid=True)
    screen = title_screen(metadata.title, credit, metadata.composer)
    # Run the original prologue, then preserve its register state across the
    # screen drawing. Both the reset vector and the monitor's entry still work.
    assembly = f"""
.segment "CODE"
    .byte {", ".join(str(byte) for byte in RESET_PROLOGUE)}
    php
    pha
    jsr draw_title
    pla
    ldx #$FF
    plp
    jmp ${reset + len(RESET_PROLOGUE):04X}
{SCREEN_CODE}
.segment "RODATA"
{bytes_directive("screen_text", screen)}
"""
    (build / "title.s").write_text(assembly, encoding="ascii", newline="\n")
    run_tool([ca65, "-t", "none", "-o", "title.o", "title.s"], build, "Assembling the title")
    run_tool([ld65, "-C", str(TOOL_DIR / "sid_title.cfg"), "title.o", "-o", "title.bin"],
             build, "Linking the title")
    splash = (build / "title.bin").read_bytes()
    if not splash or len(splash) > VECTOR_OFFSET - SPLASH_OFFSET:
        raise ValueError("the title code does not fit in the kernel ROM")

    updated = bytearray(original)
    updated[entry_offset:entry_offset + 3] = b"\x4C" + SPLASH_ADDRESS.to_bytes(2, "little")
    updated[SPLASH_OFFSET:SPLASH_OFFSET + len(splash)] = splash
    return bytes(updated)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rom_dir", type=Path, help="existing native ROM directory")
    parser.add_argument("sid_dir", type=Path, help="original SID files for title and music credits")
    parser.add_argument("output_dir", type=Path, help="write titled ROM copies here")
    parser.add_argument("--credit", default=DEFAULT_CREDIT)
    parser.add_argument("--world-record", type=Path,
                        default=ROOT / "sid_demo" / "World_Record_2.sid")
    args = parser.parse_args()
    if args.output_dir.resolve() == args.rom_dir.resolve():
        parser.error("choose a separate output directory for the titled copies")
    if not 1 <= len(args.credit.strip()) <= 60:
        parser.error("the credit must be 1–60 characters")
    roms = sorted(args.rom_dir.glob("sound_*.rom"))
    world_record = args.rom_dir / "soundsid.rom"
    if world_record.is_file():
        roms.append(world_record)
    if not roms:
        parser.error("no SID ROMs found in the input directory")

    sids = {
        re.sub(r"[^a-zA-Z0-9]+", "_", path.stem).strip("_").lower(): path
        for path in args.sid_dir.glob("*.sid")
    }
    ca65 = find_tool("CA65", "ca65")
    ld65 = find_tool("LD65", "ld65")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    output_dir = args.output_dir.resolve()
    failures = []
    with tempfile.TemporaryDirectory(prefix="sid-titles-", dir=output_dir) as temporary:
        build = Path(temporary)
        staged = build / "titled.rom"
        for rom in roms:
            sid = args.world_record if rom == world_record else sids.get(rom.stem[6:])
            if sid is None:
                failures.append(f"{rom.name}: no matching SID metadata")
                continue
            try:
                staged.write_bytes(rom_title(rom, sid, args.credit, build, ca65, ld65))
                staged.replace(output_dir / rom.name)
            except (OSError, ValueError, subprocess.TimeoutExpired) as error:
                failures.append(f"{rom.name}: {error}")
    print(f"Created {len(roms) - len(failures)} of {len(roms)} titled ROMs in {output_dir}")
    for failure in failures:
        print(failure)
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
