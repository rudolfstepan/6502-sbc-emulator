# Tang Primer 20K — 6502 SBC

Target: Sipeed Tang Primer 20K (Gowin GW2A-LV18PG256C8/I7)

## Board Specs

| Resource       | Value                        |
|----------------|------------------------------|
| FPGA           | Gowin GW2A-18 (LUT4 x 20736)|
| SDRAM          | 64 MB (onboard)              |
| Clock          | 27 MHz oscillator            |
| UART           | CH340 USB-UART / pins `M11/T13` |
| Video          | HDMI out                     |
| Storage        | External SPI microSD module  |
| GPIO           | 2× 40-pin headers            |

## Toolchain

- **Synthesis/P&R**: GowinEDA (GOWIN FPGA Designer) ≥ 1.9.9
- **Constraints**: CST format (`constraints/*.cst`)
- **Programming**: `openFPGALoader` or GowinEDA Programmer

## Differences from PIX16 (Xilinx)

| Aspect         | PIX16 (Spartan-6)       | Tang Primer 20K (GW2A-18) |
|----------------|-------------------------|---------------------------|
| BRAM primitive | `RAMB16BWER`            | `BSRAM` / `pROM`          |
| PLL            | `DCM_SP` / `PLL_BASE`   | `rPLL`                    |
| I/O standard   | `SSTL2_I`               | `LVCMOS33`                |
| Constraint fmt | UCF                     | CST                       |
| Project file   | `.xise` (ISE)           | `.gprj` (GowinEDA)        |

## Status

HDMI bring-up is implemented with a Tang-specific top-level wrapper and DVI-style
TMDS output. On reset the FPGA shows the boot/status diagnostic screen while it
initializes an external SPI microSD module and loads the 16 KB ROM image into
shadow ROM. After a successful load the CPU is released and HDMI switches to the
SBC VIC output.

Current bring-up status:

- HDMI boot/status screen works on a monitor.
- CH340 UART works from the PC as a normal serial port, tested as `COM12`.
- The UART monitor is reachable through the same CH340 path.
- KEY1 enters the FPGA monitor and holds the 6502 CPU.
- Without an external SD module attached, the boot debug output correctly reports
  that the SD card cannot be initialized/read.

The Tang boot core currently uses internal BSRAM for main RAM instead of the
on-board SDRAM. Pressing KEY1 enters the FPGA UART monitor, holds the 6502 CPU,
and switches HDMI back to the diagnostic screen while monitor operations run.

The CH340 UART is connected to the SBC UART at 115200 8N1 on FPGA pins `M11`
(`uart_tx`) and `T13` (`uart_rx`). On Windows this appears as a COM port such as
`COM12` and is used for normal SBC input and output. The USB-OTG connector for
peripherals is separate from this UART path.

UART ownership priority is:

1. FPGA monitor while KEY1 monitor mode is active.
2. Boot debug/status output while SD boot is still running or failed.
3. Normal 6502 UART 6551 after the ROM has booted.

External microSD module wiring. Use a 3.3 V module or level shifting; these
FPGA pins are not 5 V tolerant.

| Signal | FPGA pin | SD module pin |
|--------|----------|---------------|
| `sd_dclk` | `R16` | SCK |
| `sd_ncs`  | `P15` | CS |
| `sd_mosi` | `P16` | MOSI / DI |
| `sd_miso` | `N15` | MISO / DO |

## Build

```bash
# From this directory
make project   # create GowinEDA project
make build     # synthesise + place & route
make bitstream # generate .fs programming file
make program   # flash via openFPGALoader
```

If GowinEDA reports that a newly added VHDL unit is not compiled in `work`, run a
clean build so the generated `project/impl` synthesis file list is recreated.

If P&R reports stale objects from `project/impl/gwsynthesis/tang_sbc.vg`, remove
old generated implementation artifacts or force a full resynthesis. That file is
a generated netlist from the previous build, not the source of truth.
