---
name: feature2_vic_implementation
description: Feature 2 (VIC Text Mode Display) implementation progress and status
metadata:
  type: project
---

## Feature 2: VIC Text Mode Display - Implementation Status

**Current Date**: 2026-06-04  
**Status**: IN PROGRESS - Phase 1 Complete

### Completed Work

**Phase 1: VIC Core Module** ✅ COMPLETE
- Created `rtl/peripherals/vic_core.vhd` replacing generic register stub
- Implemented text RAM (0x8000-0x87FF): 2KB for 40×25 character grid
- Implemented color RAM (0x8800-0x88FF): 256B for optional colors
- Implemented control registers (0x9000-0x900F):
  - SCROLL_X/Y: Horizontal and vertical scroll
  - RASTER_CMP: Raster line for interrupt
  - MODE_REG: Display enable, interrupt control
  - COLOR_REG: Border/background colors
- Created comprehensive testbench `tb_vic_core.vhd` with 5 test suites
- All VIC core tests pass (text RAM, color RAM, control registers)
- Integrated into `sbc_t65_top.vhd` (replaced reg_stub)
- Updated Makefile to compile vic_core and run tb_vic_core
- System boot test passes with new VIC core

### Pending Work

**Phase 2: Character ROM** (1-2 days)
- Create `rtl/mem/char_rom.vhd` with ASCII character patterns
- 128 characters × 8 rows × 1 byte = 1KB ROM
- Addressing: char_code & pixel_y
- Use standard 8×8 ASCII font patterns

**Phase 3: Pixel Generator** (3-4 days)
- Create `rtl/peripherals/vic_pixel_gen.vhd`
- Timing generation (H/V counters for VGA 640×480@60Hz)
- Character grid mapping (calculate row, col, char_line, char_pixel)
- Read text RAM → look up char code
- Read color RAM → get colors
- Read char ROM → get pixel pattern
- Output pixel stream with VGA sync signals

**Phase 4: Raster Interrupt** (1-2 days)
- Enhance vic_core with proper raster line comparison
- Generate interrupt at configured raster line
- Clear flag when CPU reads status register

**Phase 5: Integration Tests** (2-3 days)
- Create `tb_vic_pixel_gen.vhd`: Pixel generation tests
- Create `tb_sbc_vic_display.vhd`: Full system test with kernel
- Verify text appears at correct positions
- Verify character rendering is legible

### Architecture Notes

The VIC implementation follows this data flow:
1. CPU writes character code to text RAM (0x8000-0x87FF)
2. CPU writes colors to color RAM (0x8800-0x88FF)
3. Pixel generator reads text/color RAM based on current pixel position
4. Character ROM provides 8×8 pixel patterns
5. Pixel generator combines them into video output

### Test Coverage

- Text RAM: Write/read at multiple addresses, including boundaries
- Color RAM: Write/read functionality
- Control registers: All 5 registers verified
- System integration: Boot test passes, no regressions

### Key Files

- Implementation: `fpga/rtl/peripherals/vic_core.vhd`
- Testbench: `fpga/sim/tb_vic_core.vhd`
- Integration: `fpga/rtl/sbc_t65_top.vhd` (line 202-213)
- Build: `fpga/Makefile` (lines 9-11, 14-18, 41-43)
- Plan: `fpga/docs/FEATURE2_VIC_TEXT_DISPLAY.md`

### Next Steps

1. Create character ROM (Phase 2) - 1-2 days
2. Create pixel generator (Phase 3) - 3-4 days
3. Implement raster interrupt (Phase 4) - 1-2 days
4. Integration and testing (Phase 5) - 2-3 days

**Estimated timeline**: 1-2 weeks for remaining phases
