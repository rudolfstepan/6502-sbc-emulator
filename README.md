# 6502 SBC Emulator

[![CI](https://github.com/rudolfstepan/6502-sbc-emulator/actions/workflows/ci.yml/badge.svg)](https://github.com/rudolfstepan/6502-sbc-emulator/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

A C99 MOS 6502 single-board-computer emulator with SDL video/audio output, an interactive monitor, and bundled ROM workflows (MS BASIC, EhBASIC, standalone chess, and a 4-voice sound demo).

## Highlights

- MOS 6502 CPU core (all 151 official opcodes)
- Integrated Klaus Dormann 6502 functional CPU test in the default test pipeline
- Memory-mapped VIA 6522, UART 6551, DISK MVP, VIC text/bitmap/sprite display with blitter and interrupt system
- **4-voice sound chip** with ADSR envelopes and per-voice waveform selection (sine, square, sawtooth, triangle, noise)
- SDL2 display and audio backend
- Interactive machine monitor (registers, memory dump, disassembly, stepping, breakpoints)
- Ready-to-run configs for MS BASIC (`sbc.ini`), EhBASIC (`ehbasic.ini`), chess (`chess.ini`), and the 4-voice sound demo (`soundtest.ini`)
- ROM build scripts for kernel, MS BASIC, EhBASIC, chess, and the soundtest ROM
- **MultiCalc**, an 80-column Multiplan/Lotus-class spreadsheet built as a cc65 PRG for the FPGA target (`make spreadsheet`; see [docs/MULTICALC.md](docs/MULTICALC.md))

## Quick Start

Clone with the FPGA submodule (the `fpga/` tree lives in its own repository,
[rudolfstepan/6502-sbc-fpga](https://github.com/rudolfstepan/6502-sbc-fpga)):

```sh
git clone --recurse-submodules https://github.com/rudolfstepan/6502-sbc-emulator.git
```

If you already cloned without `--recurse-submodules`, fetch it afterwards:

```sh
git submodule update --init
```

The emulator itself builds without the submodule; you only need it for the FPGA
RTL, simulation, and board flows.

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

Run EhBASIC setup:

```sh
cd bin
./sbc6502 ehbasic.ini
```

Run standalone chess ROM:

```sh
cd bin
./sbc6502 chess.ini
```

Run the 4-voice sound demo (~60 second looping ambient/arp song):

```sh
cd bin
./sbc6502 soundtest.ini
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
  -s <speed>    CPU speed in Hz (0 = unlimited, default 27 MHz FPGA)
  -d            start in monitor mode
  -m            print memory map and exit
  -h            show help
```

You can also drag and drop files onto the SDL display window:

- `.prg`: loads at the two-byte PRG load address and starts execution there.
- `.rom` / `.bin`: reloads the configured ROM window(s) and resets the CPU.
- With `fpga.ini`, a 16 KB FPGA shadow ROM is split into `$A000-$CFFF` and `$F000-$FFFF`.

## Current Memory Map

The emulator has a mixed map of configurable and fixed devices.

```text
$0000-$7FFF   SRAM (configurable)
$8000-$87FF   VIC text/color RAM (fixed)
$8800-$880F   VIA 6522 (configurable base)
$8810-$8813   UART 6551 (configurable base)
$8820-$8823   PS/2 keyboard registers, or legacy BASIC disk when overlapped
$8824-$882F   FPGA D64 GoDrive / SD-card disk window (`fpga.ini`)
$8830-$8839   SOUND Voice 0 — freq / dur / vol / control / ADSR (fixed)
$8840-$884F   VIC blitter registers (fixed)
$8850-$888F   VIC sprite registers (fixed)
$8890-$8899   SOUND Voice 1 (fixed)
$889A-$88A3   SOUND Voice 2 (fixed)
$88A4-$88AD   SOUND Voice 3 (fixed)
$8900-$89FF   VIC sprite pixel data (fixed)
$9000-$900F   VIC control registers + interrupt system (fixed)
$9010-$AF4F   VIC bitmap RAM (fixed)
$C000-$FFFF   ROM windows (configurable)
```

Notes:

- `sbc.ini` uses two ROM windows (`kernel.rom` + `msbasic.rom`).
- `ehbasic.ini` uses two ROM windows (`kernel.rom` + `ehbasic.rom`) for the same SBC kernel shell with EhBASIC at `$D000`.
- `chess.ini` uses one 16 KB ROM at `$C000-$FFFF`.
- `soundtest.ini` uses one 16 KB ROM at `$C000-$FFFF` that drives all four sound voices directly.

## Sound Device

The sound chip provides **4 independent voices**, each with a 10-register block:

| Offset | Name    | Description                                |
|--------|---------|--------------------------------------------|
| +0     | FREQ_LO | Frequency, low byte                        |
| +1     | FREQ_HI | Frequency, high byte (Hz, range 20–12000)  |
| +2     | DUR_LO  | Note duration, low byte (ms)               |
| +3     | DUR_HI  | Note duration, high byte (ms)              |
| +4     | VOLUME  | Peak amplitude (0–255)                     |
| +5     | CONTROL | Bits 6–4 = waveform; bit 0 = trigger       |
| +6     | ATTACK  | Attack time (0–255 × 8 ms)                 |
| +7     | DECAY   | Decay time (0–255 × 8 ms)                  |
| +8     | SUSTAIN | Sustain level (0–255, fraction of VOLUME)  |
| +9     | RELEASE | Release time (0–255 × 8 ms)                |

**Voice base addresses:**

| Voice | Base    |
|-------|---------|
| 0     | `$8830` |
| 1     | `$8890` |
| 2     | `$889A` |
| 3     | `$88A4` |

**CONTROL register waveform bits [6:4]:**

| Value | Waveform              |
|-------|-----------------------|
| 0     | Sine                  |
| 1     | Square                |
| 2     | Sawtooth              |
| 3     | Triangle              |
| 4     | Noise (xorshift LFSR) |

Writing CONTROL with bit 0 set captures all current register values and triggers the note. All four voices mix in real time through SDL audio; the per-voice volume is scaled so four simultaneous max-volume voices stay within 0 dB.

**Example:** trigger Voice 0 with a triangle wave, slow attack, at 440 Hz for 1 s:

```asm
LDA #<440
STA $8830       ; FREQ_LO
LDA #>440
STA $8831       ; FREQ_HI
LDA #<1000
STA $8832       ; DUR_LO
LDA #>1000
STA $8833       ; DUR_HI
LDA #200
STA $8834       ; VOLUME
LDA #12
STA $8836       ; ATTACK  = 12 × 8 ms = 96 ms
LDA #6
STA $8837       ; DECAY   = 6  × 8 ms = 48 ms
LDA #128
STA $8838       ; SUSTAIN = 50 % of peak
LDA #10
STA $8839       ; RELEASE = 10 × 8 ms = 80 ms
LDA #$31        ; waveform = 3 (triangle) | trigger
STA $8835
```

The **soundtest ROM** (`soundtest.ini`) is a standalone 16 KB ROM that demonstrates the full sound chip. It plays a ~60-second looping composition built entirely from 6502 machine code:

1. Laser sweep intro (Voice 3, sawtooth)
2. 28-chord ambient section — Voice 0 triangle lead, Voice 1 sine pad (slow attack), Voice 2 triangle harmony, Voice 3 sawtooth bass (~29 s)
3. SID-style square-wave arpeggio × 2 — Am / C / G / F, 12 notes per chord (~10 s)
4. 16-chord bridge section in Dm / Bb / Am space (~17 s)
5. Final arpeggio pass, then seamless loop

```sh
cd bin && ./sbc6502 soundtest.ini
```

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
speed_hz = 27000000
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
  ehbasic.ini
  chess.ini
  soundtest.ini
  roms/
    kernel.rom
    msbasic.rom
    ehbasic.rom
    chess.rom
    soundtest.rom
  data/disk/
  data/sdcard/
  # Windows only: SDL2.dll, libwinpthread-1.dll, libgcc_s_seh-1.dll
```

## ROM Build Helpers

```sh
bash tools/make_kernel_rom.sh
bash tools/make_msbasic_rom.sh
bash tools/make_ehbasic_rom.sh
bash tools/make_chess_rom.sh
make soundtest-rom          # assemble soundtest.s and stage to bin/roms/
```

## Documentation Index

- **FPGA** lives in its own repo, [rudolfstepan/6502-sbc-fpga](https://github.com/rudolfstepan/6502-sbc-fpga) (linked here as the `fpga/` submodule) — full docs in its **[Wiki](https://github.com/rudolfstepan/6502-sbc-fpga/wiki)**
- [docs/FPGA_COMPATIBILITY_STATUS.md](docs/FPGA_COMPATIBILITY_STATUS.md) — emulator-side FPGA compatibility changes, rationale, timing, and test flow
- [docs/software-test.md](docs/software-test.md) — generated FPGA software screenshot report
- [fpga/docs/INDEX.md](fpga/docs/INDEX.md) — FPGA documentation index for architecture, builds, board support, and real hardware HDMI captures
- [fpga/docs/images/README.md](fpga/docs/images/README.md) — Tang Primer 20K HDMI screenshots captured from FPGA hardware through a video grabber
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — system design, device map, audio model
- [docs/VIC.md](docs/VIC.md) — video chip registers and rendering modes (incl. the 80-column underline text attribute)
- [docs/KEYBOARD.md](docs/KEYBOARD.md) — keyboard mapping
- [docs/MULTICALC.md](docs/MULTICALC.md) — MultiCalc spreadsheet user manual
- [docs/MSBASIC.md](docs/MSBASIC.md) — MS BASIC usage notes
- [docs/BASIC_CONVERTER.md](docs/BASIC_CONVERTER.md) — BASIC tokenizer tool
- [docs/THIRD_PARTY.md](docs/THIRD_PARTY.md) — third-party components and licenses
- [docs/archive/BUGFIXES_2026-05.md](docs/archive/BUGFIXES_2026-05.md)

## Project Layout

```text
src/        emulator core and devices
tools/      ROM builders and helper scripts
bin/        generated runtime bundle (created by make)
roms/       ROM binaries
docs/       documentation
examples/   sample code
data/disk/  host-backed fallback BASIC disk files
data/sdcard/ virtual SD-card folder for mountable D64 images
fpga/       FPGA implementation (git submodule → 6502-sbc-fpga)
```

With `fpga.ini`, the FPGA ROM uses its own D64 GoDrive commands:

```basic
LOAD "!"     : REM open the on-screen D64 mount menu
LOAD "$"     : REM print the mounted D64 directory
LOAD "NAME"  : REM load a PRG
```

For machine-code PRGs, use the `CALL` address printed by the ROM. Sheet64 is a
hybrid PRG: the ROM-printed `CALL 766`, `RUN`, and direct PRG execution all
enter its loader.

The `fpga/` directory is a **git submodule** pointing at
[rudolfstepan/6502-sbc-fpga](https://github.com/rudolfstepan/6502-sbc-fpga). Its
build reuses ROMs and kernel sources from this repository (via `../roms/` and
`../../tools/kernel/`), so run the FPGA flows with the submodule checked out
inside this repo. To update the pinned submodule revision after pulling FPGA
changes:

```sh
git -C fpga pull origin main
git add fpga && git commit -m "fpga: bump submodule"
```

## License

MIT. See [LICENSE](LICENSE).
