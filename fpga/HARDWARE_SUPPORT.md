# Hardware Support: PIX16 Spartan-6 FPGA Development Board

## Overview

This document describes the hardware support infrastructure created for deploying the 6502 SBC VIC text display to the **PIX16 Spartan-6 FPGA Development Board**. The checked-in ISE project targets an XC6SLX16-2FTG256 device with 256Mbit SDRAM on the board.

## Architecture

### Board Components
- **FPGA**: XC6SLX16-2FTG256 (Spartan-6, FTG256 package)
- **System Clock**: 50MHz crystal oscillator
- **Memory**: 256Mbit SDRAM (HY57V256SGT)
- **Video Output**: VGA via 6553-color resistor-ladder DAC (5R + 6G + 5B)
- **User Interface**: 4 push buttons, 2 LEDs
- **Expansion**: 40-pin header for camera/additional I/O

### Pin Assignments

#### Clock & Reset
| Signal | Pin | Purpose |
|--------|-----|---------|
| CLK | T8 | 50MHz system clock input |
| RST_N | L3 | Active-low reset button |

#### VGA Output (18-bit RGB)
| Channel | Pins | Bits |
|---------|------|------|
| Red | M13, N14, L12, M12, M11 | 5 bits |
| Green | P11, M10, L10, P9, N9, M9 | 6 bits |
| Blue | L7, N8, P8, M7, P7 | 5 bits |
| H_SYNC | M14 | Horizontal sync |
| V_SYNC | L13 | Vertical sync |

#### SDRAM Interface (256Mbit)
- **Address Bus**: A[12:0] on pins J3, J4, K3, K5, P1, N1, M2, M1, L1, K2, K6, K1, J1
- **Data Bus**: DQ[15:0] on pins A3, B3, A2, B2, B1, C2, C1, D1, H5, G5, H3, F6, G3, F5, F3, F4
- **Bank Address**: BA[1:0] on pins G6, J6
- **Control Signals**: CLK, CKE, CS_N, RAS_N, CAS_N, WE_N, DQM[1:0]

#### User Interface
| Signal | Pin | Type |
|--------|-----|------|
| KEY0-KEY3 | C12, P13, T14, R14 | Push buttons (active-low) |
| LED0-LED1 | P4, N5 | Status LEDs |

## Design Files

### Constraint File
- **Location**: `fpga/constraints/pix16.ucf`
- **Purpose**: Maps VHDL signals to FPGA pins and specifies timing constraints
- **Format**: ISE User Constraint File (compatible with ISE 13.x, 14.x)

### RTL Modules

#### 1. Top-Level Module
- **File**: `rtl/pix16_top.vhd`
- **Purpose**: Top-level design hierarchy for ISE implementation
- **Ports**: All board I/O (VGA, SDRAM, buttons, LEDs)
- **ISE target**: `fpga/fpga/fpga.xise`, top `pix16_top`, device `xc6slx16-ftg256-2`

#### 2. Board Integration Layer
- **File**: `rtl/boards/pix16_board.vhd`
- **Purpose**: Integrates VIC core with hardware interfaces
- **Features**:
  - VIC core instantiation
  - Character ROM integration
  - Pixel generator with VGA sync signal generation
  - ROM-scripted welcome text written into VIC text RAM
  - Clock management placeholder
  - SDRAM interface stub (for future controller)

#### 3. Existing VIC Components (Reused)
- **vic_core.vhd**: 40×25 character display controller with raster interrupt and synchronous pixel read port. The text RAM uses XST RAM inference hints to avoid synthesizing the display RAM as thousands of registers.
- **vic_pixel_gen.vhd**: VGA 640×480@60Hz timing and pixel generation. It divides the 50MHz board clock by using a 25MHz pixel clock-enable.
- **char_rom.vhd**: 128-character ASCII ROM (8×8 pixels per char)
- **mem/pix16_welcome_test.hex**: ROM script used by `cpu6502_slot.vhd` to write the welcome text to VIC text RAM.

### Package Updates
- **File**: `rtl/sbc_pkg.vhd`
- **Changes**: Added `text_ram_t` and `color_ram_t` type definitions for hardware integration

## Build Instructions

### Prerequisites
1. **Xilinx ISE Design Suite 14.7** (last version supporting Spartan-6)
   - Download: https://www.xilinx.com/support/download
   - License: Free with Spartan-6 device

2. **USB Programming Cable**
   - JTAG cable (Xilinx Platform Cable or clone)
   - CP2102/FT2232H USB-UART adapter (optional, for serial communication)

### Building with ISE GUI
```
1. ISE Design Suite > File > Open Project
2. Open fpga/fpga/fpga.xise
3. Verify device: xc6slx16-ftg256-2
4. Verify top module: pix16_top
5. Implement > Run All (or Process > Run All)
6. Generate bitstream: fpga/fpga/pix16_top.bit
```

### Building with Command-Line ISE
```bash
cd fpga/fpga
ise fpga.xise -batch -run "Project -> Run All"
```

### Verification with GHDL
```bash
make hardware_analyze  # Verify VHDL compilation
```

## Programming the FPGA

### Using ISE iMPACT
1. Connect USB programming cable to board
2. Tools > iMPACT
3. Create New Project > Parallel Cable IV (or appropriate cable)
4. Select bitstream: `fpga/fpga/pix16_top.bit`
5. Right-click device > Program
6. Wait for "Programming succeeded"

### Using Open-Source Tools
```bash
# With openFPGALoader (if JTAG cable supported)
openFPGALoader -b pix16 pix16_top.bit

# Or with xc3sprog
xc3sprog -c ftdi pix16_top.bit
```

## Verification

### Expected Behavior After Programming
1. Board powers on, LEDs illuminate
2. Pushing RESET button cycles the design
3. VGA monitor locks to 640x480 @ 60Hz
4. VGA output shows the welcome text written by the test ROM
5. H_SYNC and V_SYNC outputs generate proper VGA timing

### Troubleshooting
- **No VGA signal**: Check resistor ladder DAC soldering on board
- **Garbled display**: Verify sync polarity in VGA cable
- **Monitor reports out of range**: Verify the current `vic_pixel_gen.vhd` uses a 25MHz pixel clock-enable from the 50MHz board clock
- **Blank display with valid sync**: Verify `pix16_welcome_test.hex` is present and included through `TEST_ROM_INIT_FILE`
- **Very slow synthesis**: Check that XST infers the VIC text RAM as RAM; repeated `text_ram<N>` register messages indicate broken RAM inference
- **FPGA won't program**: Check USB cable, driver installation, JTAG mode jumper
- **GHDL compile errors**: Ensure all RTL files use consistent VHDL-08 syntax

## Future Enhancements

### Phase 2: Real CPU Display Content
- Replace the ROM-scripted `cpu6502_slot` test path with the real T65 CPU path
- Load character data from a real 6502 boot ROM into VIC text RAM at startup
- Keep the current welcome text path as the board-level VGA smoke test

### Phase 3: SDRAM Controller
- Implement 256Mbit SDRAM interface
- Add graphics framebuffer support
- Enable bitmap mode for higher resolution graphics

### Phase 4: Camera Integration
- OV5640 camera module via expansion header
- Real-time video capture to SDRAM
- Live video display on VGA output

### Phase 5: Full 6502 System Integration
- CPU + RAM + ROM + I/O + Display
- PS/2 keyboard input via USB adapter
- Serial console (UART) via USB
- Complete retro computer system

## Pin Assignment Verification

All pin assignments derived from:
- **Schematic**: `D:\Development\Hardware\pix16\SCH.pdf`
- **Reference designs**: `D:\Development\Hardware\pix16\demo\`
  - 16_sdram_test - SDRAM pin mapping
  - 15_1_vga_test - VGA output configuration
  - 19_1_vga_char - Character display example

## Clock Timing

### Current Implementation
- System clock: 50MHz (from crystal oscillator)
- Pixel timing: 25MHz pixel clock-enable derived from the 50MHz system clock
- VGA mode: 640x480 @ 60Hz timing with standard active-low sync

### Recommended PLL Configuration
- Input: 50MHz crystal
- Output 1: 25MHz (pixel clock for VGA)
- Output 2: 100MHz (system clock for logic)
- Output 3: 100MHz (SDRAM clock)

Use Xilinx CoreGen to create PLL in ISE project if needed.

## Document History

| Date | Version | Changes |
|------|---------|---------|
| 2026-06-04 | 1.1 | Updated for checked-in ISE project, XC6SLX16 target, working VGA timing, and ROM-scripted welcome text |
| 2026-06-04 | 1.0 | Initial hardware support infrastructure created |

## Related Documentation
- [BUILD_PIX16.md](BUILD_PIX16.md) - Detailed build and programming guide
- [README.md](README.md) - General project overview
- [fpga/docs/](docs/) - Additional design documentation
