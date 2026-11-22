"""Boot the Apple II Plus profile with synthetic firmware and disk images."""

import struct
import subprocess
import sys
import tempfile
from pathlib import Path


def make_firmware(directory: Path) -> None:
    # Copy the test into main RAM so it keeps running during ROM bank switches.
    program = bytes.fromhex(
        "AD 00 D0 8D 00 08 "  # Copy a byte from the system ROM into screen RAM.
        "2C 81 C0 2C 81 C0 "  # Enable writes to Language Card bank two.
        "A9 C2 8D 00 D0 "
        "2C 89 C0 2C 89 C0 "  # Enable writes to bank one.
        "A9 C3 8D 00 D0 "
        "2C 8B C0 AD 00 D0 8D 02 08 "
        "2C 83 C0 AD 00 D0 8D 01 08 "
        "AD 00 C6 8D 03 08 "  # The expansion ROM is visible with a disk.
        "2C ED C0 AD EE C0 8D 04 08 "  # Read write protection.
        "2C E9 C0 2C EC C0 "  # Start the motor and select the data latch.
        "2C 55 C0 "  # Select text page two.
        "AD 00 C6 C9 FF F0 08 "  # Skip polling when the drive has no disk.
        "AD EC C0 10 FB 8D 05 08"
    )
    # End with a JMP to itself.
    program += struct.pack("<BH", 0x4C, 0x0300 + len(program))
    boot = bytes.fromhex("A2 00 BD 10 E0 9D 00 03 E8 E0")
    boot += bytes([len(program)]) + bytes.fromhex("D0 F5 4C 00 03")
    system = bytearray(0x3000)
    system[0] = 0xC1
    system[0x1000:0x1010] = boot
    system[0x1010:0x1010 + len(program)] = program
    struct.pack_into("<H", system, 0x2FFC, 0xE000)

    charset = bytearray(0x800)
    for code, glyph in ((0xC1, 0x40), (0xC2, 0x20), (0xC3, 0x10),
                        (0xC4, 0x08), (0x80, 0x04), (0xC5, 0x02), (0xFF, 0x01)):
        charset[code * 8:code * 8 + 8] = bytes([glyph]) * 8
    (directory / "system.rom").write_bytes(system)
    (directory / "video.rom").write_bytes(charset)
    (directory / "drive.rom").write_bytes(bytes([0xC4]) + bytes(255))
    (directory / "apple2.ini").write_text(
        "[machine]\ntype = apple2\n[apple2]\n"
        "system_rom = system.rom\nvideo_rom = video.rom\ndisk_rom = drive.rom\n",
        encoding="ascii",
    )


def first_cells(path: Path) -> tuple[int, ...]:
    bmp = path.read_bytes()
    offset, = struct.unpack_from("<I", bmp, 10)
    width, height = struct.unpack_from("<ii", bmp, 18)
    depth, = struct.unpack_from("<H", bmp, 28)
    assert (width, height) == (280, 192) and depth in (24, 32)
    size = depth // 8
    stride = (width * size + 3) & ~3
    top = offset + stride * (height - 1)
    return tuple(
        sum((bmp[top + (cell * 7 + x) * size] > 127) << (6 - x) for x in range(7))
        for cell in range(6)
    )


def main() -> None:
    emulator = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        make_firmware(directory)
        for extension in ("dsk", "do", "po"):
            (directory / f"disk.{extension}").write_bytes(bytes(35 * 16 * 256))
        (directory / "disk.nib").write_bytes(bytes([0xC5]) * (35 * 6656))
        (directory / "bad.dsk").write_bytes(b"short disk")

        command = [
            str(emulator), "apple2.ini", "--screenshot", "output.bmp",
            "--screenshot-frames", "1",
        ]
        common = (0x40, 0x20, 0x10)
        for disk, expected in (
            (None, common + (0x01, 0x04, 0x7F)),
            ("disk.dsk", common + (0x08, 0x04, 0x01)),
            ("disk.do", common + (0x08, 0x04, 0x01)),
            ("disk.po", common + (0x08, 0x04, 0x01)),
            ("disk.nib", common + (0x08, 0x04, 0x02)),
        ):
            args = command + (["--load", disk] if disk else [])
            result = subprocess.run(args, cwd=directory, capture_output=True, text=True, timeout=5)
            assert result.returncode == 0, result.stderr
            cells = first_cells(directory / "output.bmp")
            assert cells == expected, (disk, cells, expected)

        bad_disk = subprocess.run(command + ["--load", "bad.dsk"], cwd=directory,
                                  capture_output=True, text=True, timeout=5)
        assert bad_disk.returncode != 0 and "35-track disk" in bad_disk.stderr

        (directory / "video.rom").write_bytes(b"short ROM")
        bad_rom = subprocess.run(command, cwd=directory, capture_output=True, text=True, timeout=5)
        assert bad_rom.returncode != 0 and "2048-byte ROM" in bad_rom.stderr

    print("test_apple2: ok")


if __name__ == "__main__":
    main()
