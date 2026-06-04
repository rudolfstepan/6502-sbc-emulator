# PIX16 Hardware Build Instructions

This document describes how to build and deploy the 6502 SBC VIC display to the PIX16 Spartan-6 FPGA development board.

## Prerequisites

### Hardware
- PIX16 Spartan-6 FPGA Development Board (XC6SLX9-2FTG256C)
- USB cable for programming
- VGA monitor for display output

### Software
Choose ONE of the following toolchains:

#### Option A: Xilinx ISE (Recommended for Spartan-6)
- Xilinx ISE Design Suite 14.7 (last version supporting Spartan-6)
- Download from: https://www.xilinx.com/support/download/index.html/content/xilinx/en/downloadNav/design-tools/ise.html

#### Option B: Open Source (SymbiFlow/nextpnr)
- nextpnr-xilinx and Project Trellis (experimental, requires FASM backend)
- Vivado (newer, may have compatibility issues with Spartan-6)

## Build with ISE 14.7

### Step 1: Create ISE Project
```bash
cd fpga
ise_new_project.tcl pix16_display \
  -device XC6SLX9 \
  -family Spartan6 \
  -top_module pix16_top \
  -constraint_file constraints/pix16.ucf
```

### Step 2: Add Source Files
The project should automatically include:
- `rtl/pix16_top.vhd` (top-level)
- `rtl/boards/pix16_board.vhd` (board integration)
- `rtl/peripherals/vic_core.vhd` (VIC controller)
- `rtl/peripherals/vic_pixel_gen.vhd` (pixel generator)
- `rtl/mem/char_rom.vhd` (character ROM)

### Step 3: Configure Synthesis
- Language: VHDL
- Synthesis Tool: XST (Xilinx Synthesis Tool)
- Implementation Tool: Place & Route

### Step 4: Run Synthesis & Implementation
```
ISE Design Suite 14.7
→ File > Open Project > pix16_display.ise
→ Process > Run All (or use GUI)
```

Expected output: `pix16_top.bit` (bitstream file)

### Step 5: Program FPGA
#### Using ISE iMPACT
```
→ Tools > iMPACT
→ Create New Project
→ Select pix16_top.bit
→ Configure FPGA
```

#### Using Command Line
```bash
# Using impact in batch mode
impact -batch impact_commands.txt

# Or using Xilinx programming tools directly
```

### Step 6: Verify
- Apply power to board
- Board LEDs should illuminate
- RESET button should reset the design
- VGA output should display a test pattern or character display

## Build with Open Source Tools (Experimental)

### Using nextpnr-xilinx
```bash
# Convert VHDL to Verilog (if not already available)
ghdl -a --std=08 rtl/pix16_top.vhd
# (nextpnr doesn't yet support VHDL directly)

# Run nextpnr
nextpnr-xilinx --device xc6slx9_flg256 \
  --freq 50 \
  --json design.json \
  --constraint constraints/pix16.pdc \
  --textcfg design.config
```

## Troubleshooting

### FPGA Not Programming
- Check USB cable connection
- Verify USB drivers installed for FPGA board
- Check JP3 jumper for JTAG mode

### Synthesis Errors
- Verify all VHDL files are in correct paths
- Check constraint file pins match device package
- Ensure no duplicate signal names

### VGA No Signal
- Check resistor ladder DAC soldering
- Verify sync signal connections (HS, VS)
- Check RGB resistor values (should be ~620Ω per schematic)

## Pin Assignment Reference

See `constraints/pix16.ucf` for complete pinout:

| Signal | FPGA Pin | Function |
|--------|----------|----------|
| CLK    | T8       | 50MHz system clock |
| RST_N  | L3       | Active-low reset |
| VGA_HS | M14      | Horizontal sync |
| VGA_VS | L13      | Vertical sync |
| VGA_R[4:0] | M13,N14,L12,M12,M11 | Red channel (5-bit) |
| VGA_G[5:0] | P11,M10,L10,P9,N9,M9 | Green channel (6-bit) |
| VGA_B[4:0] | L7,N8,P8,M7,P7 | Blue channel (5-bit) |

## Next Steps

After successful programming:
1. Implement SDRAM controller for extended memory
2. Add camera interface (OV5640)
3. Integrate 6502 CPU with display subsystem
4. Load boot ROM with test programs
