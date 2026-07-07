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

- The default map now matches the FPGA-oriented split-ROM layout:
  `$A000-$CFFF` for BASIC/application ROM and `$F000-$FFFF` for kernel/vectors.
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

- ROM config entries can load a segment from a larger file via `offset`.
- `fpga.ini` loads one 16 KB FPGA shadow ROM into the two CPU-visible windows.
- Drag and drop now accepts `.prg`, `.rom`, and `.bin` files.
- Test/automation options were added:
  `--load`, `--load-data`, `--screenshot`, and `--screenshot-frames`.

Why: the FPGA workflow produces both split ROM images and PRG/data artifacts.
The emulator needs to load them the same way a developer thinks about using
VICE-style drop loading or the FPGA monitor upload flow.

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
