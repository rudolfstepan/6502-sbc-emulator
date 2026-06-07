# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

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
