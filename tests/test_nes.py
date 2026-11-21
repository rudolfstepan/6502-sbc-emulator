"""Smoke-test the NES profile with a generated NROM cartridge and FCEUmm."""

import argparse
import os
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
from zipfile import ZIP_DEFLATED, ZipFile


def make_cartridge():
    # Wait for the PPU, then set a blue backdrop and enable the background.
    program = bytearray.fromhex(
        "78 D8 A2 FF 9A A9 00 8D 00 20 8D 01 20"
        " 2C 02 20 10 FB 2C 02 20 10 FB"
        " A9 3F 8D 06 20 A9 00 8D 06 20 A9 21 8D 07 20"
        " A9 00 8D 06 20 8D 06 20 A9 08 8D 01 20"
    )
    program += b"\x4c" + (0x8000 + len(program)).to_bytes(2, "little")
    prg = program.ljust(16384 - 6, b"\xea") + b"\x00\x80" * 3
    header = b"NES\x1a\x01\x01" + bytes(10)
    return header + prg + bytes(8192)


def make_ppu_read_cartridge():
    # Store the index for LAX, wait for the PPU, then enable NMI.
    startup = bytearray.fromhex(
        "78 D8 A2 FF 9A A9 00 8D 00 20 8D 01 20 A9 03 85 00"
        " 2C 02 20 10 FB 2C 02 20 10 FB A9 80 8D 00 20"
    )
    startup += b"\x4c" + (0x8000 + len(startup)).to_bytes(2, "little")

    # LAX sets X=3. LDA $20FF,X must clear vblank via the intermediate read
    # at $2002 before reading $2102. Show red if vblank was still set.
    nmi = bytes.fromhex(
        "A7 00 BD FF 20 30 04 A9 21 D0 02 A9 16"
        " A2 3F 8E 06 20 A2 00 8E 06 20 8D 07 20"
        " 8E 06 20 8E 06 20 A2 08 8E 01 20 40"
    )
    vectors = b"\x40\x80\x00\x80\x00\x80"
    prg = (startup.ljust(64, b"\xea") + nmi).ljust(16384 - len(vectors), b"\xea") + vectors
    return b"NES\x1a\x01\x01" + bytes(10) + prg + bytes(8192)


def check_blue_backdrop(bmp):
    assert bmp.startswith(b"BM")
    pixels = int.from_bytes(bmp[10:14], "little")
    bytes_per_pixel = int.from_bytes(bmp[28:30], "little") // 8
    assert bytes_per_pixel in (3, 4)
    assert any(
        bmp[i] > max(bmp[i + 1], bmp[i + 2])
        for i in range(pixels, len(bmp) - 2, bytes_per_pixel)
    ), "The NES framebuffer is missing the blue backdrop"


def main(executable, sbc_cpu):
    executable = Path(executable).resolve()
    env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
    with TemporaryDirectory(prefix="test-nes-", dir=executable.parent) as temp:
        directory = Path(temp)
        launch_directory = directory / "bin"
        launch_directory.mkdir()
        cartridge = make_cartridge()
        rom = directory / "Color Test.nes"
        rom.write_bytes(cartridge)
        with ZipFile(directory / "Color Test.zip", "w", ZIP_DEFLATED) as archive:
            archive.writestr("nested/Color Test.nes", cartridge)
        with ZipFile(directory / "ambiguous.zip", "w", ZIP_DEFLATED) as archive:
            archive.writestr("first.nes", cartridge)
            archive.writestr("second.nes", cartridge)
        (directory / "broken.zip").write_bytes(b"invalid archive")
        config = directory / "nes.ini"
        cpu = "sbc" if sbc_cpu else "fceumm"
        config.write_text(
            f"[machine]\ntype = nes\n[nes]\ncpu = {cpu}\nrom_dir = {directory.as_posix()}\n"
            "rom = Color Test.zip\n[video]\nwindow_scale = 1\n",
            encoding="utf-8",
        )

        def run(*arguments):
            return subprocess.run(
                [str(executable), str(config), *map(str, arguments)],
                cwd=launch_directory, env=env, capture_output=True, text=True, timeout=20,
            )

        zipped_bmp = directory / "zip.bmp"
        raw_bmp = directory / "raw.bmp"
        raw_arguments = ["--load", Path("..") / rom.name]
        for screenshot, options in ((zipped_bmp, []), (raw_bmp, raw_arguments)):
            result = run(*options, "--screenshot", screenshot, "--screenshot-frames", 10)
            assert result.returncode == 0, result.stderr
            assert ("FCEUmm (SBC CPU)" in result.stdout) == sbc_cpu, result.stdout
        assert zipped_bmp.read_bytes() == raw_bmp.read_bytes()
        check_blue_backdrop(zipped_bmp.read_bytes())

        ppu_rom = directory / "ppu-read.nes"
        ppu_rom.write_bytes(make_ppu_read_cartridge())
        ppu_bmp = directory / "ppu-read.bmp"
        result = run("--load", ppu_rom, "--screenshot", ppu_bmp, "--screenshot-frames", 10)
        assert result.returncode == 0, result.stderr
        check_blue_backdrop(ppu_bmp.read_bytes())

        for filename, diagnostic in (
            ("ambiguous.zip", "exactly one"),
            ("broken.zip", "cannot read ZIP"),
            ("missing.zip", "cannot open"),
        ):
            result = run("--load", filename)
            assert result.returncode != 0 and diagnostic in result.stderr, result.stderr
    print(f"test_nes ({cpu}): NROM, indexed PPU read, ZIP and error paths passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable")
    parser.add_argument("--sbc-cpu", action="store_true")
    args = parser.parse_args()
    main(args.executable, args.sbc_cpu)
