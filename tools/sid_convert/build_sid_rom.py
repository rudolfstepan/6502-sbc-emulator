"""Build a bootable 16 KiB SBC soundtrack ROM from a PAL PSID subtune."""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from convert_sid import write_assembly
from native_sid import write_native_assembly
from rom_screen import DEFAULT_CREDIT, title_screen
from sid_metadata import read_sid_metadata


TOOL_DIR = Path(__file__).resolve().parent
ROOT = TOOL_DIR.parents[1]
ROM_SIZE = 0x4000


def find_tool(variable: str, default: str) -> str:
    name = os.environ.get(variable, default)
    executable = shutil.which(name)
    if executable is None:
        raise ValueError(f"{name} was not found. Install the tool or set {variable}.")
    return str(Path(executable).resolve())


def run_tool(command: list[str], cwd: Path, stage: str) -> None:
    result = subprocess.run(
        command, cwd=cwd, capture_output=True, encoding="utf-8", errors="replace",
        timeout=60, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    if result.returncode:
        details = result.stderr.strip() or result.stdout.strip()
        if stage == "Linking the ROM" and "overflow" in details.lower():
            raise ValueError("The soundtrack does not fit in 16 KiB. Choose a shorter excerpt.")
        raise ValueError(f"{stage} failed.\n{details}")


def build_rom(source: Path, output: Path, *, title: str | None, credit: str,
              seconds: int, song: int | None, delay: int, native: bool = False) -> int | None:
    if output.suffix.lower() != ".rom":
        raise ValueError("the output filename must end in .rom")
    if output.exists() and output.samefile(source):
        raise ValueError("the SID and ROM must be different files")
    metadata = read_sid_metadata(source)
    display_title = metadata.title if title is None else title.strip()
    if not 1 <= len(display_title) <= 64 or not 1 <= len(credit.strip()) <= 60:
        raise ValueError("use a title of 1–64 characters and a credit of 1–60 characters")
    selected_song = metadata.start_song if song is None else song
    if not 1 <= selected_song <= metadata.songs:
        raise ValueError(f"the SID contains subtunes 1–{metadata.songs}")
    if not 1 <= seconds <= 300 or not 10 <= delay <= 2000:
        raise ValueError("use 1–300 seconds and a frame delay of 10–2000 tenths of a millisecond")

    ca65 = find_tool("CA65", "ca65")
    ld65 = find_tool("LD65", "ld65")
    screen = title_screen(display_title, credit, metadata.composer)
    cpu_dir = ROOT / "src" / "core" / "cpu"
    linker_config = (TOOL_DIR / "sid_native.cfg" if native else
                     ROOT / "tools" / "soundtest" / "soundtest.cfg")
    dumper = "siddump.exe" if os.name == "nt" else "./siddump"

    with tempfile.TemporaryDirectory(prefix="sid-rom-", dir=output.parent) as temporary:
        build = Path(temporary).resolve()
        if native:
            write_native_assembly(source.read_bytes(), build / "player.s", song=selected_song,
                                  frame_ms=(delay + 5) // 10, screen=screen)
            frames = None
        else:
            cc = find_tool("CC", "gcc")
            shutil.copyfile(source, build / "input.sid")
            run_tool([
                cc, "-std=c99", "-Wall", "-Wextra", "-O2", "-I", str(ROOT / "src"),
                str(TOOL_DIR / "siddump.c"), str(cpu_dir / "cpu6502.c"), str(cpu_dir / "disasm.c"),
                "-o", dumper,
            ], build, "Building the SID extractor")
            run_tool([
                str(build / dumper), "input.sid", str(seconds), "--song", str(selected_song),
                "--raw", "frames.raw",
            ], build, "Extracting SID frames")
            frames = write_assembly((build / "frames.raw").read_bytes(), build / "player.s",
                                    delay, screen=screen)
        run_tool([ca65, "-t", "none", "-o", "player.o", "player.s"], build, "Assembling the player")
        run_tool([ld65, "-C", str(linker_config), "player.o", "-o", "player.rom"],
                 build, "Linking the ROM")
        rom = build / "player.rom"
        if rom.stat().st_size != ROM_SIZE:
            raise ValueError("the linker did not produce a 16 KiB ROM")
        rom.replace(output)
    return frames


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sid", type=Path)
    parser.add_argument("rom", type=Path)
    parser.add_argument("--title", help="game title to show on screen, defaults to the SID title")
    parser.add_argument("--credit", default=DEFAULT_CREDIT, help="name credited for the ROM")
    parser.add_argument("--seconds", type=int, help="sound_chip4 excerpt length, default 30")
    parser.add_argument("--native", action="store_true", help="preserve the original SID player in a split ROM")
    parser.add_argument("--song", type=int, help="subtune number, defaults to the SID start song")
    parser.add_argument("--delay", type=int, default=200,
                        help="tenths of a millisecond per frame, default 200")
    args = parser.parse_args()
    if args.native and args.seconds is not None:
        parser.error("--seconds applies only to sound_chip4 excerpts")
    try:
        frames = build_rom(args.sid, args.rom, title=args.title, credit=args.credit,
                           seconds=30 if args.seconds is None else args.seconds,
                           song=args.song, delay=args.delay, native=args.native)
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"SID ROM build failed. {error}\n")
    content = "native SID split ROM" if frames is None else f"{frames} frames"
    print(f"Created {args.rom} ({ROM_SIZE} bytes, {content})")


if __name__ == "__main__":
    main()
