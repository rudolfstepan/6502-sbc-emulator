# PIX16 Build Instructions

Build and program the 6502 SBC minimal system onto the PIX16 Spartan-6 FPGA board.

The current firmware-development target is the SD boot build
`pix16_sbc_sd_boot_top`. The older `pix16_sbc_minimal_top` build remains a small
VGA smoke test and is still documented below because it is useful when isolating
video or T65 basics.

## Hardware

- PIX16 development board — Xilinx XC6SLX16-2FTG256
- USB cable (JTAG programming)
- VGA monitor
- USB-UART console connection via the board CH340C

## Software

Xilinx ISE Design Suite 14.7 (last version supporting Spartan-6).

---

## Build with ISE 14.7

## Current SD Boot Build

Use this path for the board setup that supports SD-card ROM loading, SDRAM main
RAM, the boot VGA screen, RAM self-test, and the UART hardware monitor.

### Step 0 — Create or refresh the project

```bash
cd fpga/boards/pix16
xtclsh scripts/create_sd_boot_ise_project.tcl
```

If `xtclsh` is not in the normal shell PATH, run the command from the Xilinx ISE
Command Prompt.

Expected active settings:

| Setting | Value |
| --- | --- |
| Top module | `pix16_sbc_sd_boot_top` |
| Constraint file | `../constraints/pix16_sd_boot.ucf` |
| Board top | `rtl/pix16_sbc_sd_boot_top.vhd` |
| Core top | `../../rtl/core/sbc_t65_sdram_boot_top.vhd` |
| Shadow ROM | `../../rtl/core/mem/boot_shadow_rom.vhd`, 16 KB at `$C000-$FFFF` |

### Step 1 — Build the SD image

```bash
cd fpga
make sd-boot-image
```

Write `sim/generated/sbc_ehbasic_sd.img` as a raw image to the SD card. The FPGA
loads this image into shadow ROM after reset.

### Step 2 — Build and program the bitstream

Open `fpga/boards/pix16/project/fpga.xise` in ISE, select `pix16_sbc_sd_boot_top` as top if it
is not already selected, then run implementation and bitgen. Program the
generated `pix16_sbc_sd_boot_top.bit` with iMPACT.

### Step 3 — Verify SD boot and monitor

- VGA first shows the boot status screen.
- The screen switches to the SBC VGA output after SD load and SDRAM test pass.
- LED 0 indicates SD/boot-done status.
- LED 1 is driven by VIA Port B bit 0 after boot.
- Press `KEY0` to enter the UART monitor.

Live ROM upload over the monitor:

```bash
python tools/upload_monitor_hex.py --build-demo --port COM15 --baud 230400 --run --verbose
```

See [UART Monitor](../../docs/UART_MONITOR.md) for commands such as memory dump,
byte edit, disassembly, `L` hex load, and `G` execute.

---

## Minimal VGA Smoke-Test Build

### Step 0 — Build the ROM (optional, pre-built hex is checked in)

```bash
cd fpga/sw
make          # requires cc65 toolchain at C:/tools/cc65/bin
```

This assembles `rom_demo.s`, links it, and installs `fpga/sim/hex/rom_welcome.hex`.
The hex file is already committed; only re-run this step when changing the kernel.

### Step 1 — Open the project

```text
ISE Design Suite 14.7
→ File > Open Project
→ fpga/boards/pix16/project/fpga.xise
```

The project is pre-configured:

| Setting | Value |
| --- | --- |
| Family | Spartan-6 |
| Device | xc6slx16 |
| Package | ftg256 |
| Speed grade | -2 |
| Top module | `pix16_sbc_minimal_top` |
| Constraint file | `../constraints/pix16.ucf` |
| ROM init file | `../../../sim/hex/rom_welcome.hex` |

### Step 2 — Source files

The project includes all required files automatically. Active synthesis files:

- `../../rtl/core/sbc_pkg.vhd`
- `../../../third_party/t65/rtl/T65_Pack.vhd`, `T65_MCode.vhd`, `T65_ALU.vhd`, `T65.vhd`
- `../../rtl/core/mem/rom.vhd`, `sync_ram.vhd`, `char_rom.vhd`
- `../../rtl/core/cpu/t65_adapter.vhd`
- `../../rtl/core/bus_decode.vhd`
- `../../rtl/core/peripherals/vic_vga.vhd`
- `../../rtl/core/sbc_minimal_top.vhd`
- `rtl/pix16_sbc_minimal_top.vhd`
- `constraints/pix16.ucf`

### Step 3 — Run synthesis and implementation

```text
ISE Process panel
→ Implement Design (or Run All)
```

Expected output: `fpga/boards/pix16/project/pix16_sbc_minimal_top.bit`

### Step 4 — Program the FPGA

```text
ISE → Tools > iMPACT
→ Boundary Scan
→ Right-click XC6SLX16 → Program
→ Select fpga/boards/pix16/project/pix16_sbc_minimal_top.bit
```

Or via command line:

```bash
impact -batch impact_commands.txt
```

### Step 5 — Verify

- LED 0 lit (power indicator)
- LED 1 follows KEY 0
- VGA monitor locks to 640×480 @ 60 Hz
- UART console prints reset diagnostics and the system check:

```text
[RESET] 6502 SBC DEBUG
...
SYS CHECK
  ZP   OK
  STK  OK
  RAM  OK
  VRAM OK
  VIA  OK
  UART OK
CHECK DONE, CLI NEXT
```

- Screen shows:

```text
  **** 6502 SINGLE BOARD COMPUTER ****

 4096 BYTES RAM     2048 BYTES ROM

BEREIT.
```

---

## Architecture Summary

The minimal SBC uses **C64-style bus stealing**: the VIC and CPU share a single-port
video RAM. During each horizontal blanking interval the VIC takes the bus for 41 clock
cycles: one setup cycle for synchronous VRAM read latency, then 40 cycles to prefetch
the character row into an internal line buffer. The CPU is halted during this window
via the T65 `RDY` pin.

Zero page and stack (`$0000-$01FF`) are implemented as internal FPGA RAM. This
keeps IRQ entry/return, `JSR/RTS`, stack pushes/pulls, and zero-page
read-modify-write instructions off the external/main RAM path. Main RAM begins
at `$0200` from the firmware's point of view.

```text
H-blank (320 system clocks per line)
├── VIC steals 41 clocks -> loads line buffer from synchronous VRAM
└── CPU free for remaining 279 clocks

H-visible (1280 system clocks per line)
└── CPU runs freely; VIC renders from line buffer (no bus access)
```

CPU overhead: about 2.6 % of total system clocks.

---

## ROM Hex Format

`sim/hex/rom_welcome.hex` — one entry per line, **no comments**:

```text
XXXX YY
```

`XXXX` = 4-digit hex ROM offset (0000–07FF for 2 KB ROM), `YY` = 1-byte hex value.  
Comments (`;`) cause synthesis errors because `rom.vhd` uses raw `hread` parsing.  
Default fill: `0xEA` (NOP). Reset vector is at offsets `07FC`–`07FD`.

---

## Pin Reference

| Signal | Pin | Function |
| --- | --- | --- |
| `clk` | T8 | 50 MHz crystal |
| `reset_n` | L3 | Active-low reset button |
| `vga_out_hs` | M14 | Horizontal sync |
| `vga_out_vs` | L13 | Vertical sync |
| `vga_out_r[4:0]` | M13, N14, L12, M12, M11 | Red (5-bit DAC) |
| `vga_out_g[5:0]` | P11, M10, L10, P9, N9, M9 | Green (6-bit DAC) |
| `vga_out_b[4:0]` | L7, N8, P8, M7, P7 | Blue (5-bit DAC) |
| `key[3:0]` | C3, D3, E4, E3 | Push buttons (active-low) |
| `led[1:0]` | P4, N5 | Status LEDs |

---

## Troubleshooting

### No signal on monitor

- Confirm top module is `pix16_sbc_minimal_top` (not `sbc_minimal_top` — it has no board ports).
- Confirm `pix16.ucf` is the active constraint file.
- Check VGA cable and resistor-ladder DAC soldering.
- Pixel clock is 25 MHz derived inside `vic_vga` — no external PLL required.

### Synthesis error: invalid character in hex file

- `rom.vhd` does not support comments. Remove all `;` lines from the hex file.
- Each line must be exactly `XXXX YY` with a single space separator.

### Blank screen (signal present but no text)

- Confirm `ROM_INIT_FILE` resolves correctly relative to the ISE project directory (`fpga/boards/pix16/project/`).
- The generic defaults to `"../../../sim/hex/rom_welcome.hex"` which resolves to `fpga/sim/hex/rom_welcome.hex`.
- If the ROM file is not found, `rom.vhd` fills with NOP (`0xEA`) and the CPU loops forever without writing to VRAM.

### Synthesis very slow

- XST may expand `linebuf` in `vic_vga` as flip-flops instead of distributed RAM.
- Check XST report for `Found 8-bit register for signal <linebuf<N>>` messages.
- Adding `attribute ram_style : string; attribute ram_style of linebuf : signal is "distributed";` forces RAM inference.

---

**See Also:**

- [Architecture Overview](../../docs/01_ARCHITECTURE.md)
- [Modules Reference](../../docs/02_MODULES.md)
