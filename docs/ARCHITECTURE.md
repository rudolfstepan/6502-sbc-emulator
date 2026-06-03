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
6. IRQ lines from VIA, UART, and VIC are OR-ed and folded back into the CPU IRQ state.
7. Optional monitor takes over on breakpoint, step-mode, or `SIGINT`.

## Device Map Strategy

The emulator uses both fixed and configurable regions.

### Fixed regions

- `$8000-$87FF`: VIC text/color RAM
- `$8840-$884F`: VIC blitter registers
- `$8850-$888F`: VIC sprite registers (8 × 8 bytes)
- `$8830-$8835`: SOUND
- `$8900-$89FF`: VIC sprite pixel data (8 × 32 bytes)
- `$9000-$900F`: VIC control registers (including interrupt system)
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

- Text mode (40×25, color attributes in video RAM)
- Bitmap mode (320×200 using dedicated bitmap RAM window)

Hardware sprites (up to 8, 8×8 or 16×16 pixels) and a blitter (fill, copy, line, circle, scroll, invert) operate on the bitmap RAM.

`vic_sdl.c` translates VIC state into an SDL window and handles keyboard events.

## Interrupt Model

The VIC raises the CPU IRQ line through the same OR-bus as VIA and UART. Interrupt sources:

- **Raster compare**: fires when the internal raster line counter reaches the programmed compare value (`$9008`).
- **Frame**: fires when the raster counter wraps to line 0 (start of new frame).

The ISR (`$9006`) holds pending flags; writing a `1` to a bit acknowledges (clears) it. The IER (`$9007`) enables individual sources. `vic_irq()` returns the combined pending state.

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

## CPU Correctness Validation

The project includes Klaus Dormann's 6502 functional test as an integrated regression check.

- Make target: `test-klaus-6502`
- Included in: `make check`
- Test binary source: downloaded from the upstream Klaus2m5 repository into the local build directory

This provides broad opcode/flag behavior validation in addition to emulator integration tests.

## ROM Workflows

- `sbc.ini`: split ROM setup (`kernel.rom` + `msbasic.rom`)
- `chess.ini`: standalone 16 KB chess ROM

ROM helper scripts under [tools](../tools) generate project ROMs reproducibly.
