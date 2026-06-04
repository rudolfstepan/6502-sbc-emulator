# Feature 2: VIC Text Mode Display Implementation

## Status
Implementing Feature 2 of Tier 1 Plan (VIC Text Mode Display)
- Feature 1 (Fix T65 Indirect Addressing): ✓ COMPLETE
- Feature 2 (VIC Text Mode Display): **IN PROGRESS**
- Feature 3 (Complete UART): ✓ COMPLETE

## Overview

Implement a 40×25 character text display with:
- Text RAM (0x8000-0x87FF): 2KB for character codes
- Color RAM (0x8800-0x88FF): Optional color per character
- Control registers (0x9000-0x900F): Display config
- Character ROM: 8×8 pixel patterns for ASCII characters
- Pixel generator: Converts text to pixel stream
- Raster interrupt: CPU interrupt at specific screen lines

## Architecture

```
CPU (writes to text RAM)
    │
    ├─> Text RAM (0x8000-0x87FF)     [2048 bytes, 40×25 grid]
    ├─> Color RAM (0x8800-0x88FF)    [Optional]
    └─> VIC Registers (0x9000-0x900F) [Control]
         │
         ├─> Character ROM (1KB) ─────┐
         │                             │
         ├─> Pixel Generator ◄────────┘
         │   (reads text, generates pixels)
         │
         └─> Raster Counter
             (triggers interrupts)
```

## Memory Layout

### Text RAM: 0x8000-0x87FF (2KB)
- 40 columns × 25 rows = 1000 bytes
- Each byte = ASCII character code (0x20-0x7F)
- Row-major order: bytes 0-39 = row 0, bytes 40-79 = row 1, etc.
- Wraps automatically during writes

### Color RAM: 0x8800-0x88FF (256 bytes, optional)
- 1 byte per character (parallel to text RAM)
- Format: bits[7:4]=foreground color, bits[3:0]=background color
- Default: black on white (0x00 = white FG, 0x00 = black BG)

### Control Registers: 0x9000-0x900F (16 bytes)
```
0x9000: SCRL_X  - Horizontal scroll (0-7 pixels)
0x9001: SCRL_Y  - Vertical scroll (0-7 pixels)
0x9002: RASTER  - Raster line for interrupt (0-199)
0x9003: MODE    - Display mode and flags
  Bit 7: Enable display (1=on, 0=off)
  Bit 6: Enable bitmap (0=text mode, 1=bitmap)
  Bit 5: Raster IRQ enable
  Bit 4: Sprite enable (future)
  Bits 3-0: Reserved
0x9004: COLORS  - Border/background colors
  Bits 7-4: Foreground color
  Bits 3-0: Background color
0x9005-0x900F: Reserved for expansion
```

## Implementation Phases

### Phase 1: VIC Core Module ✅ IN PROGRESS
Create `rtl/peripherals/vic_core.vhd` with:
- Text RAM: 2048 × 8-bit memory
- Color RAM: 256 × 8-bit memory (optional)
- Control registers: 16 × 8-bit
- CPU read/write interface
- Address decoding for different regions
- Synchronous read/write

**Timeline**: 2-3 days

### Phase 2: Character ROM
Create `rtl/mem/char_rom.vhd` with:
- 128 ASCII characters (0x00-0x7F)
- 8 rows × 8 pixels per character = 8×8 bitmap
- Address scheme: char_code & pixel_y
- Output: 8-bit pixel data (one horizontal line of character)
- Storage: 128 × 8 × 1 byte = 1KB ROM

**Timeline**: 1-2 days

### Phase 3: Pixel Generator
Create `rtl/peripherals/vic_pixel_gen.vhd` with:
- Timing generator (horizontal/vertical counters)
- VGA timing: 640×480 @ 60Hz
- Character grid mapping
- Text/color RAM lookups
- Character ROM lookups
- Pixel output stream
- Raster counter for interrupts

**Timeline**: 3-4 days

### Phase 4: Raster Interrupt
Add to VIC core:
- Raster line comparison
- Interrupt flag generation
- CPU interrupt output
- Interrupt acknowledge via register read

**Timeline**: 1-2 days

### Phase 5: Integration Tests
Create testbenches:
- `sim/tb_vic_core.vhd`: Text/color RAM, registers
- `sim/tb_vic_pixel_gen.vhd`: Pixel generation
- `sim/tb_sbc_vic_display.vhd`: Full system test

**Timeline**: 2-3 days

## Success Criteria

- ✅ Text can be written to RAM via CPU bus
- ✅ Text appears at correct screen position
- ✅ Character ROM displays correct patterns
- ✅ Raster interrupt fires at configured line
- ✅ Full kernel boot completes (CLRSCR works)
- ✅ All existing system tests still pass
- ⏳ Pixel output is legible

## Current Phase: Phase 1 - VIC Core Module

Starting with the VIC Core Module to replace the `reg_stub` with a real implementation.

Key components:
1. Text RAM with proper storage
2. Color RAM (optional, stub for now)
3. Control registers
4. Address decoding logic
5. CPU bus interface

This module will serve as the data store for the pixel generator created in Phase 3.

---

*Created: 2026-06-04*
*Phase 1 Status: Starting implementation*
