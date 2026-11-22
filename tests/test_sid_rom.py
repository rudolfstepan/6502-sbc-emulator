"""Build SID ROMs and verify title and sound-register writes in the emulator."""

import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
TOOL_DIR = ROOT / "tools" / "sid_convert"
sys.path.insert(0, str(TOOL_DIR))

from build_sid_rom import find_tool
from title_fpga_roms import rom_title


def make_sid(path):
    header = bytearray(0x7C)
    header[:4] = b"PSID"
    struct.pack_into(">HHHHHHH", header, 4, 2, len(header), 0x1000, 0x1000, 0x1007, 2, 1)
    header[22:31] = b"Test Game"
    header[54:58] = b"Demo"
    # Init sets frequency from A (the 0-based subtune), play gates voice 0.
    player = bytes.fromhex("69 0A 8D 01 D4 EA 60 A9 11 8D 04 D4 60")
    path.write_bytes(header + player)


def boot(emulator, config, breakpoint, sound_register, *options):
    env = {**os.environ, "SDL_VIDEODRIVER": "dummy", "SDL_AUDIODRIVER": "dummy"}
    result = subprocess.run(
        [str(emulator), config.name, "-d", *options],
        input=f"b {breakpoint:04X}\nc\nm 8000 1000\nm {sound_register:04X} 6\nq\n",
        cwd=config.parent, capture_output=True, text=True, timeout=10, env=env,
    )
    assert result.returncode == 0 and f"hit at ${breakpoint:04X}" in result.stdout, result
    screen = "".join(re.findall(r"^  8[0-3][0-9A-F]{2}: .*?\|(.+?)\|$", result.stdout, re.M))
    assert "TEST GAME" in screen and "#" in screen, screen
    assert "MUSIC: DEMO" in screen and "ROM: RUDOLF STEPAN" in screen, screen
    assert "CONVERTED WITH SID ROM CONVERTER" in screen, screen
    match = re.search(
        rf"^\[monitor\]   {sound_register:04X}: ((?:[0-9A-F]{{2}} ){{6}})",
        result.stdout,
        re.M,
    )
    assert match, result.stdout
    return bytes.fromhex(match[1])


def config_file(directory, rom, banks):
    config = directory / "test.ini"
    sections = ["[sram]\nbase=0x0000\nsize=0x8000\n"]
    for base, size, offset in banks:
        sections.append(
            f"[rom]\nbase={base:#x}\nsize={size:#x}\nfile={rom.name}\noffset={offset:#x}\n"
        )
    config.write_text("\n".join(sections), encoding="ascii")
    return config


def test_converted_rom(emulator, directory, sid):
    rom = directory / "converted.rom"
    command = [sys.executable, str(TOOL_DIR / "build_sid_rom.py"), str(sid), str(rom)]
    subprocess.run(command + ["--seconds", "1", "--song", "2"], check=True, timeout=30)
    data = rom.read_bytes()
    assert len(data) == 16384 and data[-6:] == b"\x00\xC0" * 3
    # Stop after the first frame has populated the voice, at the timer wait.
    delay = data.index(bytes.fromhex("AD 3A 88 85 1C AD 3A 88"))
    config = config_file(directory, rom, ((0xC000, 0x4000, 0),))
    voice = boot(emulator, config, 0xC000 + delay, 0x8830)
    assert voice == bytes.fromhex("A5 00 E8 03 C8 31"), voice

    result = subprocess.run(command + ["--song", "3"], capture_output=True, text=True, timeout=10)
    assert result.returncode != 0 and "subtunes" in result.stderr, result
    assert rom.read_bytes() == data


def test_native_rom(emulator, directory, sid):
    ca65, ld65 = find_tool("CA65", "ca65"), find_tool("LD65", "ld65")
    source = directory / "native.rom"
    output = directory / "titled.rom"
    for reset, offset in ((0xA000, 0), (0xF000, 0x3000)):
        original = bytearray(b"\xEA" * 16384)
        # Original startup writes the native SID gate, then stops at a breakpoint.
        startup = bytes.fromhex("78 D8 A2 FF 9A A9 11 8D 04 D4")
        original[offset:offset + len(startup)] = startup
        struct.pack_into("<HHH", original, 0x3FFA, reset, reset, reset)
        source.write_bytes(original)
        updated = rom_title(source, sid, "Rudolf Stepan", directory, ca65, ld65)
        assert updated[-6:] == original[-6:] and updated[offset + 3:0x3800] == original[offset + 3:0x3800]
        output.write_bytes(updated)
        config = config_file(directory, output, ((0xA000, 0x3000, 0), (0xF000, 0x1000, 0x3000)))
        assert boot(emulator, config, reset + len(startup), 0xD400)[4] == 0x11


def test_original_psid_rom(emulator, directory, sid):
    rom = directory / "original-sid.rom"
    subprocess.run([sys.executable, str(TOOL_DIR / "build_sid_rom.py"), str(sid), str(rom),
                    "--native", "--song", "2"], check=True, timeout=20)
    data = rom.read_bytes()
    assert len(data) == 16384 and data[-4:-2] == b"\x00\xA0"
    assert sid.read_bytes()[0x7C:] in data[:0x3000]

    missing = directory / "both-banks-must-be-overridden.rom"
    config = config_file(directory, missing, ((0xA000, 0x3000, 0), (0xF000, 0x1000, 0x3000)))
    registers = boot(emulator, config, 0x100C, 0xD400, "-r", rom.name)
    assert registers[1] == 0x0B and registers[4] == 0x11, registers


def main():
    emulator = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        sid = directory / "test.sid"
        make_sid(sid)
        test_converted_rom(emulator, directory, sid)
        test_native_rom(emulator, directory, sid)
        test_original_psid_rom(emulator, directory, sid)
    print("test_sid_rom: ok")


if __name__ == "__main__":
    main()
