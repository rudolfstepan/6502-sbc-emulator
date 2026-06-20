# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### Tang Primer 20K — reset button (KEY0 / dock S0)

- Fixed the `key[0]` pin: the dock's **S0** reset button is FPGA pin `T10`, not
  `T5`. The original `T5` (and an interim `T2` attempt) were not the physical
  button, so no reset button worked at all. Confirmed against Sipeed's own
  examples — `Cam2HDMI` and the HDMI `dk_video` example both map reset to `T10`.
- KEY0/S0 is now a debounced, clock-synchronised dual-action reset (in the 54 MHz
  `clk_sys` domain):
  - **short press** → CPU-only soft reset. The 6502 restarts via its reset vector
    while `boot_done`, the shadow ROM, and SRAM are preserved — restarts a
    UART-uploaded program without re-running the SD boot loader.
  - **long press (>1 s)** → full board reset (re-runs the SD ROM loader).
- Added a `soft_reset` input to `sbc_t65_boot_monitor_top`; `cpu_reset_base_n`
  now also gates on `not soft_reset`, holding only the CPU in reset.
- Decoupled the HDMI PLL reset from the button (`reset_n => '1'`) so `clk_sys`
  keeps running during a soft reset and the picture stays up during a full reset.
- KEY1/S1 (`T3`) is unchanged: enters the UART monitor and holds the CPU.

### Chess ROM — FPGA PS/2 keyboard support

- Rewrote `read_key` in `tools/chess/chess.s` to read the FPGA PS/2 keyboard
  register file (`$8820` STATUS bit 0 = key ready, `$8823` ASCII) instead of the
  C-emulator's VIA6522 Port A (`$8801`/`$880D`, CA1). The move parser is
  unchanged — the PS/2 core already returns lowercase letters, digits, Enter
  (`$0D`), and Backspace (`$08`).
- Removed the now-unused VIA keyboard init from the reset routine; rebuilt
  `roms/chess.rom`.

### siddemo.bas — FPGA 4-voice sound chip

- Rewrote `examples/siddemo.bas` for the FPGA 4-voice sound chip, which has no
  note queue: each `POKE CONTROL,1` retriggers the voice immediately. The old
  demo poked a 36-note theme into one voice with no delays, so only the last note
  sounded. The new version plays notes sequentially with per-note duration and
  software-delay pacing (the proven `soundtest.bas` pattern), demonstrating the
  four ADSR presets, a 3-voice chord, and the Korobeiniki theme.

### Tang Primer 20K — 54 MHz SBC clock

- Reworked the HDMI/SBC clock tree around one 270 MHz PLL root: `/2` generates
  the 135 MHz TMDS serializer clock, `/5` generates the 54 MHz SBC clock, and a
  second `/5` from the TMDS branch restores the serializer's required 27 MHz
  pixel clock.
- Doubled the T65's maximum effective bus rate from 13.5 MHz to 27 MHz while
  retaining its proven two-phase synchronous-memory bus protocol.
- Added a registered 54 MHz renderer output stage and a falling-edge handoff
  into the HDMI path, keeping RGB, sync, and data-enable aligned across the
  related 54/27 MHz clock boundary.
- Updated all clock-derived parameters: VIC and boot VGA pixel enables, sound
  phase/envelope timing, PT8211 BCK, UART baud generators, SD low/high-speed SPI,
  PS/2 timeouts, cursor blink, and boot diagnostics.
- Added T65-only multicycle timing constraints. Final Gowin place-and-route
  reports zero setup and hold violations at 54 MHz (54.4 MHz post-route Fmax).
- Corrected `key[1]` from the incompatible `LVCMOS15` declaration to
  `LVCMOS33`, matching the bank voltage and removing the `CT1136` P&R failure.

### FPGA VIC/PETSCII graphics

- Added PETSCII block/line glyph coverage for the C/SDL VIC font at `$60-$7F`,
  matching the FPGA character ROM and making `$7F` a full block.
- Kept kernel `CHROUT` text-safe by converting lowercase ASCII to uppercase
  before VRAM writes; raw PETSCII graphics are produced by writing `$60-$7F`
  directly to text VRAM.
- Reworked `examples/petscii_gfx.bas` into a pure `$8000` VRAM `POKE` demo with
  short upload-friendly BASIC lines and no `PRINT`, `CHR$`, `READ`, `DATA`, or
  string functions.
- Fixed active FPGA boot cores so CPU writes to text VRAM are no longer lost when
  they overlap VIC bus stealing. A one-byte pending write buffer defers the write
  until the first non-steal clock and holds `RDY` low through the commit cycle.

### EhBASIC FPGA port — SCROLL infinite-loop fix

- Fixed a SCROLL infinite-loop bug that caused all three observed symptoms (VGA stop updating after ~18 rows, UART missing linefeed, FOR loop printing corrupted values). Root cause: `roms/kernel.rom` was a stale pre-built binary predating the SCROLL and STRPTR fixes in `tools/kernel/kernel.s`.
- `SCROLL` now saves and restores A/X/Y. The old code exited with X=COLS=40; CHROUT then stored 40 into CURSOR_X, so every subsequent character immediately re-triggered a scroll.
- Moved kernel `STRPTR_LO` from $EE→$EB and `STRPTR_HI` from $EF→$EE to avoid the collision with EhBASIC's `Decss` buffer ($EF–$F4), written on every `PRINT` of a number.
- Rebuilt `roms/kernel.rom` from source.
- Added `kernel` make target to `fpga/asm/Makefile`; `fpga-ehbasic` and `upload-ehbasic` now depend on `$(KERNEL_ROM)` so the kernel is auto-rebuilt when `kernel.s` changes.
- Updated `fpga/docs/EHBASIC_SYNTAX_ERROR_ANALYSIS.md` with final root-cause analysis (Section 12).

### Sound chip — waveform selection

- Extended the CONTROL register (offset +5 in each voice block): bits [6:4] now select the waveform played when bit 0 triggers the note. Encoding: 0 = sine (default, fully backward-compatible), 1 = square, 2 = sawtooth, 3 = triangle, 4 = noise (xorshift32 LFSR).
- Added `PI_F` / `INV_PI` constants and a `switch` in `audio_callback()` for branchless per-sample waveform generation. Noise uses a per-voice LFSR seeded at first trigger.
- Updated `soundchip.h` to document the new CONTROL register layout.

### Soundtest ROM — 60-second polyphonic composition

- Rewrote `tools/soundtest/soundtest.s` as a standalone ~60-second looping song in pure 6502 machine code:
  - **Section A** (~29 s): 28-chord ambient progression (Am / F / C / G), four voices with distinct waveforms — Voice 0 triangle lead, Voice 1 sine pad (slow 160 ms attack for wash), Voice 2 triangle inner harmony, Voice 3 sawtooth bass.
  - **SID-style arpeggio** (~5 s × 3 passes): square-wave arpeggios over Am / C / G / F, 12 notes per chord at 100 ms intervals.
  - **Bridge section B** (~17 s): 16-chord progression in Dm / Bb / Am space with Gm and E7 colour chords.
- Refactored loop engine into a shared `ambient_play_engine` subroutine (tail-called from section drivers) to avoid code duplication.
- Added `play_ambient_bridge` driver proc for the bridge data table.
- Fixed `intro_sweep` infinite-loop bug: `delay_25ms_units` clobbers X (it counts down from 25 internally); the sweep loop used X as its iteration counter, causing it to run forever after the first delay call. Fixed by introducing a dedicated zero-page variable `sweep_cnt` ($05) and replacing `DEX / BNE` with `DEC sweep_cnt / BNE`.

### Build

- `make soundtest-rom` now runs `tools/stage_runtime.sh` after assembling the ROM, so `bin/roms/soundtest.rom` is always kept in sync without requiring a full emulator relink.

### Documentation

- Added and documented integration of Klaus Dormann's 6502 functional test in the default `make check` pipeline.
- Updated README and `docs/ARCHITECTURE.md` to cover the 4-voice sound chip, per-voice waveform selection, full register map for all four voices, the soundtest ROM, and the updated `bin/` bundle layout.

## 1.1.0 - 2026-05-17

- Refreshed project documentation for current architecture and runtime behavior.
- Updated memory-map docs to include fixed VIC register/bitmap regions and SOUND device registers.
- Added explicit chess workflow coverage (`chess.ini`, standalone ROM flow) in documentation.
- Cleaned obsolete or inconsistent statements across README and docs.

## 1.0.0 - 2026-05-16

- Initial public release of the 6502 SBC emulator.
- Added a cycle-aware MOS 6502 core with all 151 official opcodes.
- Added configurable SRAM and top-aligned ROM mapping.
- Added MOS 6522 VIA and MOS 6551 ACIA peripheral emulation.
- Added stdio and TCP UART backends.
- Added an interactive monitor/debugger with registers, disassembly, memory dump, stepping, and breakpoints.
- Added ROM helper scripts for hello-world and echo-monitor binaries.
- Added GitHub CI workflow, issue templates, contribution guidelines, security policy, and MIT licensing.
