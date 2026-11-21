# FPGA Compatibility Status

This document summarizes the emulator changes made to run software built for
the Tang Primer 20K 6502 FPGA target and explains why each area was changed.

## Goal

The FPGA system is no longer the emulator's old 1 MHz, single-ROM SBC map.  It
uses a split ROM image, a denser I/O area, HDMI/VIC framebuffer modes, keyboard
registers, math coprocessor registers, CIA/SID compatibility registers, and an
effective 27 MHz T65/6502 execution rate.  The emulator was updated so the same
ROM and PRG files can be exercised directly on the PC before they are uploaded
to the FPGA.

## Memory Map And Devices

- `fpga.ini` selects the 65C02 and the FPGA split-ROM layout. `sbc.ini`
  boots the SBC kernel at `$C000` with MS BASIC at `$D000-$FFFF`.
- Configured ROM windows take precedence over the FPGA compatibility devices
  at `$D000`, `$D400`, and `$DC00`.
- The FPGA D64 GoDrive / SD-card loader is exposed at `$8824-$882F`, matching
  the FPGA kernel and BASIC LOAD routines. `LOAD "!"` invokes the ROM's D64
  mount menu.
- Fixed FPGA devices were added around the configurable map:
  bitmap framebuffer window at `$6000-$7FFF`, VIC registers, blitter, sprite
  registers/data, keyboard registers, math coprocessor, CIA1, and SID.
- `BUS_MAX_DEVICES` was increased because the FPGA-compatible configuration has
  more memory-mapped devices than the older emulator profile.

Why: FPGA ROMs and BASIC programs use these addresses directly.  Even one
device at the old base address can make otherwise correct software fail.

## ROM And PRG Loading

The **same 16,384-byte split ROM** can be loaded into the emulator or sent to
the Tang Primer 20K monitor. For both, use the binary built for the FPGA's
split address map as-is.

| File bytes | CPU addresses | Usual contents |
| --- | --- | --- |
| `$0000-$2FFF` | `$A000-$CFFF` | Application or BASIC |
| `$3000-$3FFF` | `$F000-$FFFF` | CPU vectors and optional kernel code |

With the two repositories side by side, run from the emulator checkout after
`make`:

```powershell
cd bin
$rom = '..\..\6502-sbc-fpga\roms\6502\mandelbrot_copro.bin'
.\sbc6502.exe fpga.ini --load $rom
```

The loader reports two ROM windows and resets the CPU. The reset vector at
`$FFFC/$FFFD` points to `$A000` in this demo. Dragging the same `.rom` or
`.bin` into the running FPGA profile also starts it. Relative paths in
`fpga.ini` resolve from the working directory. When available in the sibling
checkout, the build stages a copy at `bin/roms/mandelbrot_copro.bin`.

From the FPGA checkout, the matching serial-monitor command is the following.
Use the port for your adapter in place of `COM15`.

```powershell
$rom = 'roms\6502\mandelbrot_copro.bin'
python tools/upload_monitor_hex.py $rom --split-rom --port COM15 --run
```

The uploader sends both windows and starts at `$A000`. For other images,
use the appropriate entry address on the hardware. Split ROMs, SD-card
`.img` files, and PRGs are different formats. The emulator starts a
`.prg` passed to `--load` at its two-byte header address. Use
`--load-data` to load PRG bytes without changing the CPU entry point.

## Fixed-Point Math Coprocessor

The SBC math coprocessor multiplies two signed 32-bit operands and exposes
the 64-bit raw product and the lower 32 bits of the arithmetically shifted
product. Register bytes are little-endian.

| Address | Write | Read |
| --- | --- | --- |
| `$88B0-$88B3` | Operand A | Raw product bytes 0–3 |
| `$88B4-$88B7` | Operand B | Raw product bytes 4–7 |
| `$88B8-$88BB` | Ignored | Scaled result bytes 0–3 |
| `$88BC` | Shift, bits 0–5 | Shift, 0–63 |
| `$88BD-$88BF` | Ignored | Zero |

After reset, both operands are zero and the shift defaults to 24 for 8.24
fixed-point arithmetic. The original `mandelbrot_copro.bin` uses the scaled
result directly. The emulator register tests cover signed products, shift
changes, and reset. A full run of the unmodified ROM reached row 200 in the
emulator. The FPGA's REIST modulo benchmark uses its own core.

## Timing

- The emulator default CPU speed is now `27000000` Hz, matching the Tang board's
  effective T65/6502 rate from the 54 MHz system clock.
- `speed_hz = 0` once again means truly unlimited speed instead of being
  replaced by the default.
- VIC raster timing was adjusted from the old 1 MHz assumption to the FPGA
  frame cadence.
- CIA Timer A is scaled to the FPGA SID wrapper's expected 1 MHz timer domain.

Why: the FPGA is much faster than the historical emulator default, but some
peripherals intentionally expose older timing domains.  SID player ROMs, for
example, program CIA Timer A for about 50 Hz using a 1 MHz timer period.

## Video And Automated Screenshots

- The SDL renderer supports FPGA bitmap modes in addition to legacy text/bitmap
  rendering.
- In the 320×200 RGB332 mode, bit 4 of `$9000` selects the mode and bits 7–5
  select one of eight 8 KiB banks. The bank changes preserve the display mode
  and the next scanlines continue in the next bank.
- The screenshot test harness runs selected FPGA ROMs/PRGs through `fpga.ini`,
  captures BMP output, and writes `docs/software-test.md`.
- Mandelbrot cases use a separate long wait value via `--mandelbrot-frames`
  because they need much longer to render a meaningful image.

Why: visual regressions are hard to review from logs.  The generated Markdown
file gives a quick software gallery that can be compared between emulator
changes.

## Sound

- `$D400-$D41C` is now backed by a simple 3-voice SID-compatible mixer instead
  of a silent register stub.
- The mixer supports gate, ADSR, triangle, sawtooth, pulse, noise, OSC3/ENV3,
  and master volume `$D418`.
- This is intentionally a compatibility playback core, not a full reSID clone.

Why: the FPGA `sound_*.rom` files are native SID-player ROMs.  They write SID
registers and rely on CIA/play timing, so a silent stub made many tests appear
to run while producing no useful audio.

## Verification

The current verification set is:

```sh
make
make check
python tools/software_screenshot_test.py --frames 120 --mandelbrot-frames 6000
```

Shorter local screenshot refreshes can use a smaller Mandelbrot wait, for
example `--mandelbrot-frames 600`, when the goal is only to refresh the
documentation images quickly.
