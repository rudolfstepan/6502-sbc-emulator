# 6502 SBC Emulator

[![CI](https://github.com/rudolfstepan/6502-sbc-emulator/actions/workflows/ci.yml/badge.svg)](https://github.com/rudolfstepan/6502-sbc-emulator/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

A cycle-accurate MOS 6502 Single Board Computer emulator written in C99.

This project emulates a small 6502-based single board computer with a cycle-aware CPU core, memory-mapped peripherals, configurable address decoding, and an interactive machine monitor for debugging ROMs and firmware.

## Highlights

- Full MOS 6502 core with all 151 official opcodes
- Memory-mapped MOS 6522 VIA and MOS 6551 ACIA peripherals
- Interactive monitor with register view, disassembly, memory dump, stepping, and breakpoints
- Configurable board layout through `sbc.ini`
- Runs against stdio or a TCP-backed serial console

## Project Status

- Stable emulator core for MOS 6502, MOS 6522 VIA, and MOS 6551 ACIA
- Interactive monitor/debugger with register, disassembly, memory dump, single-step, and breakpoints
- Suitable for hobbyist firmware experiments, ROM bring-up, and educational use

## Quick Start

```sh
make
python3 tools/make_test_rom.py
./sbc6502 sbc.ini
```

Press `CTRL+C` during emulation to enter the built-in monitor/debugger.

Example monitor session:

```text
[SIGINT - entering monitor]

[monitor] r
  PC:C008  A:00  X:FF  Y:00  SP:FF  P:nv-bdIZc  cycles:3490965

[monitor] m c000 16
  C000: A2 FF 9A AD 11 80 29 08 F0 F9 AD 10 80 8D 10 80  |......).........|
```

## Features

- **Full MOS 6502 CPU** – all 151 official opcodes, correct cycle counts, page-crossing penalties, BCD mode, hardware vectors (RESET/NMI/IRQ)
- **MOS 6522 VIA** – Port A/B with DDR, Timer 1 (free-run & one-shot), Timer 2, interrupt flag/enable registers, IRQ generation
- **MOS 6551 ACIA** – UART with receive FIFO, status register, stdio (raw terminal) or TCP server mode
- **SRAM** – configurable base address and size
- **ROM** – loaded from binary file, top-aligned in the address window
- **Freely configurable address map** – all device base addresses set via `sbc.ini`
- **Built-in monitor/debugger** – enter with CTRL+C; step, disassemble, hex dump, breakpoints
- **Speed throttle** – configurable CPU speed in Hz (or unlimited)

## Default Memory Map

```
$0000–$7FFF   SRAM     (32 KB)
$8000–$800F   VIA 6522 (16 registers)
$8010–$8013   UART 6551/ACIA (4 registers)
$C000–$FFFF   ROM      (16 KB, vectors at $FFFA–$FFFF)
```

All addresses are freely configurable in `sbc.ini`.

## Build

```sh
make
```

Requires GCC (or any C99-compatible compiler), `make`, Python 3 for helper scripts, and standard POSIX headers.

## Development

```sh
# Rebuild from scratch
make clean && make

# Generate the bundled test ROM
python3 tools/make_test_rom.py

# Run the emulator with the default config
./sbc6502 sbc.ini
```

## Included ROM Helpers

```sh
# Generate a simple UART hello-world ROM
python3 tools/make_test_rom.py

# Generate a minimal echo monitor ROM
python3 tools/gen_echo_rom.py
```

## Usage

```sh
./sbc6502 [options] [config.ini]

Options:
  -r <rom>      load ROM file (overrides config)
  -s <speed>    CPU speed in Hz (0 = unlimited, default 1 MHz)
  -d            start in monitor mode
  -m            print memory map and exit
  -h            help
```

**Examples:**

```sh
# Run with default sbc.ini
./sbc6502

# Run with a specific ROM at unlimited speed
./sbc6502 -r roms/basic.rom -s 0

# Custom address map
./sbc6502 my_board.ini
```

## Configuration File (sbc.ini)

```ini
[cpu]
speed_hz = 1000000   # 1 MHz

[sram]
base = 0x0000
size = 0x8000        # 32 KB

[rom]
base = 0xC000
size = 0x4000        # 16 KB
file = roms/rom.bin

[via]
base = 0x8000        # VIA 6522

[uart]
base = 0x8010        # ACIA 6551
mode = stdio         # or: tcp
# port = 2551        # TCP port (when mode=tcp)
```

Multiple `[sram]`, `[rom]`, `[via]`, `[uart]` sections are supported (up to 8 total devices).

## Monitor / Debugger

Press **CTRL+C** during emulation to enter the monitor:

```
  r          - show registers
  d [addr]   - disassemble 16 instructions
  m addr [n] - hex dump n bytes (default 64)
  b addr     - set breakpoint
  bl         - list breakpoints
  bc n       - clear breakpoint n
  s          - step one instruction
  c          - continue
  q          - quit
```

## UART Modes

| Mode    | Description |
|---------|-------------|
| `stdio` | UART TX → stdout, UART RX ← stdin (raw terminal mode) |
| `tcp`   | UART TX/RX over TCP; connect with `nc 127.0.0.1 <port>` |

## ROM Format

Plain binary. The file is **top-aligned** in the ROM window:
- A 16 KB file fills exactly `$C000–$FFFF`
- A 4 KB file fills `$F000–$FFFF`

Reset/NMI/IRQ vectors must be at the standard 6502 locations:

| Vector | Address |
|--------|---------|
| NMI    | `$FFFA/$FFFB` |
| RESET  | `$FFFC/$FFFD` |
| IRQ    | `$FFFE/$FFFF` |

## Test ROM

A minimal "Hello World" ROM is generated with:

```sh
python3 tools/make_test_rom.py
```

This creates `roms/rom.bin` that prints `Hello, 6502 SBC!` via the UART.

## Roadmap

- Add more bundled test programs and firmware samples
- Extend the monitor with memory write and patch commands
- Add automated CPU regression tests
- Document board variants and example configurations

## Open Source Project Layout

- `src/` core emulator implementation
- `tools/` ROM generation and helper scripts
- `roms/` sample and generated ROM binaries
- `docs/` project documentation
- `.github/` issue templates, PR template, and CI workflow

See `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, and `LICENSE` for project policies.

## Project Structure

```
src/
  cpu6502.c/h    MOS 6502 CPU core
  bus.c/h        Address bus with device registry
  sram.c/h       Static RAM
  rom.c/h        Read-only memory (file-loadable)
  via6522.c/h    MOS 6522 VIA
  uart6551.c/h   MOS 6551 ACIA (UART)
  disasm.c/h     6502 disassembler
  monitor.c/h    Interactive debugger
  config.c/h     INI config file parser
  main.c         Entry point / emulator loop
tools/
  make_test_rom.py  Generate a test ROM binary
roms/            Place your ROM files here
docs/            Additional project documentation
.github/         GitHub community health files and CI
sbc.ini          Default configuration
Makefile
```

## Contributing

Contributions are welcome. Please read `CONTRIBUTING.md` before opening a pull request.

## Security

If you find a security issue, follow the reporting guidance in `SECURITY.md`.

## Third-Party ROM Notes

Some optional ROM workflows use third-party upstream sources. See `docs/THIRD_PARTY.md` before redistributing generated ROM artifacts.

## License

This project is licensed under the MIT License. See `LICENSE` for details.
