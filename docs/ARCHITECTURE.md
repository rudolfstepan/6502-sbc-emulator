# Architecture Overview

## Core Components

- `CPU6502`: instruction execution, interrupt handling, cycle accounting
- `Bus`: device registration and address dispatch
- `SRAM` / `ROM`: memory devices
- `VIA6522`: GPIO/timers plus keyboard input path
- `UART6551`: serial I/O (`stdio` or TCP mode)
- `DiskDev`: host-backed minimal disk interface for BASIC LOAD/SAVE
- `VIC`: text/bitmap display memory and control registers
- `Soundchip`: 4-voice synthesizer — ADSR envelopes, selectable waveforms (sine/square/sawtooth/triangle/noise), SDL audio mix
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
- `$8830-$8839`: SOUND Voice 0 (10 registers)
- `$883A`: SOUND free-running millisecond counter (low 8 bits)
- `$8840-$884F`: VIC blitter registers
- `$8850-$888F`: VIC sprite registers (8 × 8 bytes)
- `$8890-$8899`: SOUND Voice 1 (10 registers)
- `$889A-$88A3`: SOUND Voice 2 (10 registers)
- `$88A4-$88AD`: SOUND Voice 3 (10 registers)
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

The sound chip provides four independent voices, each with 10 memory-mapped registers:

```text
+0  FREQ_LO   frequency low byte
+1  FREQ_HI   frequency high byte (Hz, 20–12000)
+2  DUR_LO    note duration low byte (ms)
+3  DUR_HI    note duration high byte (ms)
+4  VOLUME    peak amplitude (0–255)
+5  CONTROL   bits [6:4] = waveform, bit 0 = trigger
+6  ATTACK    attack time  (0–255, units of 8 ms)
+7  DECAY     decay time   (0–255, units of 8 ms)
+8  SUSTAIN   sustain level (0–255, fraction of VOLUME)
+9  RELEASE   release time (0–255, units of 8 ms)
```

Writing CONTROL with bit 0 set captures all register values and starts playback with the full ADSR envelope applied. Voices run concurrently; the SDL audio callback sums them in real time with per-voice volume scaled to keep four simultaneous max-volume voices within 0 dB.

**Waveform encoding (CONTROL bits [6:4]):**

| Bits [6:4] | Waveform | Implementation                      |
|------------|----------|-------------------------------------|
| 0          | Sine     | `sinf(phase)`                       |
| 1          | Square   | `phase < π ? +1 : −1`               |
| 2          | Sawtooth | `1 − phase/π` (falls +1 → −1)       |
| 3          | Triangle | linear ramp −1 → +1 → −1 per cycle  |
| 4          | Noise    | xorshift32 LFSR, one value/sample   |

All four voices are mixed by `audio_callback()` in `soundchip.c`; a hard clip prevents overflow when multiple voices peak simultaneously.

**Soundtest ROM** (`soundtest.ini`) is a 16 KB standalone ROM that exercises all four voices and all waveforms in a ~60 s looping composition. Build with `make soundtest-rom`; run with `./sbc6502 soundtest.ini` from `bin/`.

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

| Config          | ROM(s)                       | Description                                |
|-----------------|------------------------------|--------------------------------------------|
| `sbc.ini`       | `kernel.rom` + `msbasic.rom` | MS BASIC with kernel shell                 |
| `ehbasic.ini`   | `kernel.rom` + `ehbasic.rom` | EhBASIC with the same kernel shell         |
| `chess.ini`     | `chess.rom`                  | Standalone 16 KB chess ROM                 |
| `soundtest.ini` | `soundtest.rom`              | 4-voice sound demo, pure 6502 machine code |

ROM helper scripts under [tools](../tools) generate project ROMs reproducibly. The soundtest ROM is rebuilt and staged with `make soundtest-rom`; all other ROMs with `make roms`.
