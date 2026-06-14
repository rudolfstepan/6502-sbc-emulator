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

#### 1. Top-Level Module (SD Boot — Active)
- **File**: `rtl/boards/pix16_sbc_sd_boot_top.vhd`
- **Purpose**: PIX16 board wrapper for the full SD boot design
- **Ports**: All board I/O (VGA, SDRAM, SD card, buttons, LEDs, UART)
- **ISE target**: `fpga/fpga/fpga.xise`, top `pix16_sbc_sd_boot_top`, device `xc6slx16-ftg256-2`

#### 2. SBC Core
- **File**: `rtl/sbc_t65_sdram_boot_top.vhd`
- **Purpose**: Integrates the T65 CPU, SDRAM RAM, 16 KB shadow ROM, bus decoder, VIA 6522, UART 6551, and VIC display
- **Memory map**: ZP/stack → internal RAM; $0200–$7FFF → SDRAM; $8000–$87FF → VRAM; $8800 → VIA; $8810 → UART; $C000–$FFFF → shadow ROM

#### 3. Boot Subsystem
- **boot_vga_debug.vhd**: VGA status screen displayed during SD load and RAM self-test.
  Shows load progress, RAM test results, and a PETSCII block-graphics character set demo on row 22.
- **boot_sdram_test.vhd**: Marching-pattern SDRAM self-test; passes/fails result shown on VGA.
- **sd_rom_loader.v**: Reads 16 KB ROM image from raw SD sectors into the shadow ROM.
- **uart_debug_monitor.vhd**: Machine-level UART monitor activated by KEY0.
  Stops the CPU; supports hex load (`L`), memory dump (`M`), single-byte write (`E`/`W`), and `G` to resume.

#### 4. VIC Display
- **vic_vga.vhd**: Combined bus-stealing VIC and VGA signal generator. 40×25 chars, 640×480 @ 60 Hz.
- **char_rom.vhd**: 128-character 8×8 pixel ROM.
  - `$00–$1F`: PETSCII screen-code letters
  - `$20–$5F`: ASCII punctuation, digits, uppercase
  - `$60–$7F`: PETSCII block/line graphics (horizontal/vertical bars, corners, T-pieces, diagonals, quadrants, diamond, arrows, full block)
  - Bit 7 of the character code selects reverse-video rendering.
  - Regenerated from `fpga/tools/gen_petscii_char_rom.py`.

### ISE Project

The ISE project (`fpga/fpga/fpga.xise`) contains only the files required by the
`pix16_sbc_sd_boot_top` hierarchy. Legacy top-level designs (`pix16_top`,
`pix16_board`, `vic_core`, `vic_pixel_gen`) are excluded from the project to
keep the hierarchy view unambiguous.

### Package
- **File**: `rtl/sbc_pkg.vhd`
- **Purpose**: Shared types (`addr_t`, `data_t`, `device_sel_t`), memory-map constants, `in_range` helper

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
4. Verify top module: pix16_sbc_sd_boot_top
5. Implement > Run All (or Process > Run All)
6. Generate bitstream: fpga/fpga/pix16_sbc_sd_boot_top.bit
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
4. Select bitstream: `fpga/fpga/pix16_sbc_sd_boot_top.bit`
5. Right-click device > Program
6. Wait for "Programming succeeded"

### Using Open-Source Tools
```bash
# With openFPGALoader (if JTAG cable supported)
openFPGALoader -b pix16 pix16_sbc_sd_boot_top.bit

# Or with xc3sprog
xc3sprog -c ftdi pix16_sbc_sd_boot_top.bit
```

## Verification

### Expected Behavior After Programming
1. Board powers on, LED0 illuminates (power indicator)
2. VGA monitor locks to 640×480 @ 60 Hz
3. Boot status screen appears: SD load progress and SDRAM self-test results
4. Row 22 of the boot screen shows all 32 PETSCII block/line graphics glyphs (`$60–$7F`)
5. After successful SD load and RAM test: T65 CPU starts from the loaded ROM; `vic_vga` takes over VGA output
6. Pressing KEY0 at any time enters the UART machine monitor (CPU halted, VGA stays active)

### Uploading the Demo ROM via UART Monitor
```bash
# 1. Program the FPGA bitstream via iMPACT
# 2. Press KEY0 on the board to enter monitor mode
# 3. From fpga/asm/:
cd fpga/asm
make all                       # build rom_demo.bin
python upload_rom_demo.py --run --verbose   # upload and start
```

### Troubleshooting
- **No VGA signal**: Check resistor-ladder DAC soldering on board
- **Garbled display**: Verify sync polarity in VGA cable
- **Boot stuck at SD**: Verify SD card is FAT32 with the boot image at sector 0
- **UART monitor not responding**: Check baud rate (230400) and that KEY0 was pressed after FPGA config
- **FPGA won't program**: Check USB cable, driver installation, JTAG mode jumper

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
| 2026-06-08 | 1.3 | Reflect SD boot design as active top; ISE project cleanup (single-top); PETSCII char ROM ($60–$7F); upload_rom_demo.py; remove completed Future Enhancements |
| 2026-06-04 | 1.2 | Updated for checked-in ISE project, XC6SLX16 target, working VGA timing |
| 2026-06-04 | 1.0 | Initial hardware support infrastructure created |

## Related Documentation
- [BUILD_PIX16.md](BUILD_PIX16.md) - Detailed build and programming guide
- [README.md](README.md) - General project overview
- [fpga/docs/](docs/) - Additional design documentation
