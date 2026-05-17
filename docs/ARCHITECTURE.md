# Architecture Overview

## Core Components

- `CPU6502`: instruction execution, interrupt handling, cycle accounting
- `Bus`: device registration and address dispatch
- `SRAM` / `ROM`: memory devices
- `VIA6522`: GPIO/timers plus keyboard input path
- `UART6551`: serial I/O (`stdio` or TCP mode)
- `DiskDev`: host-backed minimal disk interface for BASIC LOAD/SAVE
- `VIC`: text/bitmap display memory and control registers
- `Soundchip`: simple beep generator with memory-mapped registers
- `Monitor`: debugger shell (`CTRL+C`)

## Boot and Runtime Flow

1. Parse configuration (`sbc.ini` or user-provided INI).
2. Create bus and register fixed devices (VIC + SOUND).
3. Create configurable devices from INI (`SRAM`, `ROM`, `VIA`, `UART`, `DISK`).
4. Reset CPU from ROM reset vector.
5. Main loop executes one instruction, then ticks peripherals.
6. IRQ lines from VIA/UART are folded back into CPU IRQ state.
7. Optional monitor takes over on breakpoint, step-mode, or `SIGINT`.

## Device Map Strategy

The emulator uses both fixed and configurable regions.

### Fixed regions

- `$8000-$87FF`: VIC text/color RAM
- `$8830-$8835`: SOUND
- `$9000-$900F`: VIC registers
- `$9010-$AF4F`: VIC bitmap RAM

### Configurable regions

Configured in INI sections:

- `[sram]`
- `[rom]` (multiple windows supported)
- `[via]`
- `[uart]`
- `[disk]`

## Video Model

VIC provides two rendering paths:

- Text mode (40x25, color attributes in video RAM)
- Bitmap mode (320x200 using dedicated bitmap RAM window)

`vic_sdl.c` translates VIC state into an SDL window and handles keyboard events.

## Audio Model

The sound device exposes six registers (`freq`, `duration`, `volume`, `control`).
Setting `control bit0` queues a generated sine beep into SDL audio output.

## Debugging and Observability

The monitor supports:

- register dump (`r`)
- memory dump (`m`)
- disassembly (`d`)
- breakpoints (`b`, `bl`, `bc`)
- stepping (`s`) and continue (`c`)

## ROM Workflows

- `sbc.ini`: split ROM setup (`kernel.rom` + `msbasic.rom`)
- `chess.ini`: standalone 16 KB chess ROM

ROM helper scripts under [tools](../tools) generate project ROMs reproducibly.
