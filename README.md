# 6502 SBC Emulator

[![CI](https://github.com/rudolfstepan/6502-sbc-emulator/actions/workflows/ci.yml/badge.svg)](https://github.com/rudolfstepan/6502-sbc-emulator/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

A C99 MOS 6502 single-board-computer emulator with SDL video/audio output, an interactive monitor, and bundled ROM workflows (MS BASIC and standalone chess).

## Highlights

- MOS 6502 CPU core (all 151 official opcodes)
- Integrated Klaus Dormann 6502 functional CPU test in the default test pipeline
- Memory-mapped VIA 6522, UART 6551, DISK MVP, VIC text/bitmap display, and a simple SOUND device
- SDL2 display backend for VIC text/bitmap rendering
- Interactive machine monitor (registers, memory dump, disassembly, stepping, breakpoints)
- Ready-to-run configs for MS BASIC (`sbc.ini`) and chess (`chess.ini`)
- ROM build scripts for kernel, MS BASIC, chess, and test ROMs

## Quick Start

Build:

```sh
make
```

After build, a runnable bundle is staged in `bin/` (binary + config files + ROM files + runtime DLLs on Windows).

Run MS BASIC setup:

```sh
cd bin
./sbc6502 sbc.ini
```

Run standalone chess ROM:

```sh
cd bin
./sbc6502 chess.ini
```

Run tests:

```sh
make check
```

`make check` includes the Klaus Dormann 6502 functional test (`test-klaus-6502`) and downloads the upstream binary automatically on first run.

## Binary Downloads

If you do not want to build from source, download prebuilt bundles from GitHub Releases.

- Tags (for example `v1.2.0`) still point to source commits.
- Release assets contain ready-to-run bundles for Linux and Windows.
- Download the archive for your platform, extract it, then run from the extracted `bin/` directory.

Expected release assets:

- `sbc6502-linux-x86_64.tar.gz`
- `sbc6502-windows-x86_64.zip`

## Runtime Options

```text
./bin/sbc6502 [options] [config.ini]

Options:
  -r <rom>      load ROM file (overrides first ROM entry in config)
  -s <speed>    CPU speed in Hz (0 = unlimited, default 1 MHz)
  -d            start in monitor mode
  -m            print memory map and exit
  -h            show help
```

## Current Memory Map

The emulator has a mixed map of configurable and fixed devices.

```text
$0000-$7FFF   SRAM (configurable)
$8000-$87FF   VIC text/color RAM (fixed)
$8800-$880F   VIA 6522 (configurable base)
$8810-$8813   UART 6551 (configurable base)
$8820-$882F   DISK MVP (configurable base)
$8830-$8835   SOUND registers (fixed)
$9000-$900F   VIC control registers (fixed)
$9010-$AF4F   VIC bitmap RAM (fixed)
$C000-$FFFF   ROM windows (configurable)
```

Notes:

- `sbc.ini` uses two ROM windows (`kernel.rom` + `msbasic.rom`).
- `chess.ini` uses one 16 KB ROM at `$C000-$FFFF`.

## Sound Device

SOUND is memory-mapped at `$8830-$8835`:

```text
$8830  FREQ_LO
$8831  FREQ_HI
$8832  DURATION_LO (ms)
$8833  DURATION_HI (ms)
$8834  VOLUME (0-255)
$8835  CONTROL (bit 0 = trigger)
```

A write with bit 0 set in CONTROL triggers a queued beep.

## Monitor

Press `CTRL+C` while emulation is running to enter monitor mode.

Commands:

```text
r          show registers
?          help
m addr [n] hex dump n bytes (default 64)
d [addr]   disassemble 16 instructions
b addr     set breakpoint
bl         list breakpoints
bc n       clear breakpoint n
s          step one instruction
c          continue
q          quit emulator
```

## Configuration

Example (`sbc.ini` style):

```ini
[cpu]
speed_hz = 1000000
debug = 0

[sram]
base = 0x0000
size = 0x8000

[rom]
base = 0xC000
size = 0x1000
file = roms/kernel.rom

[rom]
base = 0xD000
size = 0x3000
file = roms/msbasic.rom

[via]
base = 0x8800

[uart]
base = 0x8810
mode = stdio

[disk]
base = 0x8820
path = data/disk
```

## Build Dependencies

- C99 compiler (GCC/Clang)
- `make`
- SDL2 development package (`libsdl2-dev` on Debian/Ubuntu)
- Python 3 (for ROM helper scripts)

## Bundled Output

`make` stages a runnable bundle in `bin/`.

```text
bin/
  sbc6502(.exe)
  sbc.ini
  chess.ini
  roms/
  data/disk/
  # Windows only: SDL2.dll, libwinpthread-1.dll, libgcc_s_seh-1.dll
```

## ROM Build Helpers

```sh
bash tools/make_kernel_rom.sh
bash tools/make_msbasic_rom.sh
bash tools/make_chess_rom.sh
python3 tools/make_test_rom.py
```

## Documentation Index

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [docs/VIC.md](docs/VIC.md)
- [docs/KEYBOARD.md](docs/KEYBOARD.md)
- [docs/MSBASIC.md](docs/MSBASIC.md)
- [docs/BASIC_CONVERTER.md](docs/BASIC_CONVERTER.md)
- [docs/THIRD_PARTY.md](docs/THIRD_PARTY.md)
- [docs/archive/BUGFIXES_2026-05.md](docs/archive/BUGFIXES_2026-05.md)

## Project Layout

```text
src/        emulator core and devices
tools/      ROM builders and helper scripts
bin/        generated runtime bundle (created by make)
roms/       ROM binaries
docs/       documentation
examples/   sample code
data/disk/  host-backed BASIC disk files
```

## License

MIT. See [LICENSE](LICENSE).
