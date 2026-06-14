# Tang Primer 20K — 6502 SBC

Target: Sipeed Tang Primer 20K (Gowin GW2A-LV18PG256C8/I7)

## Board Specs

| Resource       | Value                        |
|----------------|------------------------------|
| FPGA           | Gowin GW2A-18 (LUT4 x 20736)|
| SDRAM          | 64 MB (onboard)              |
| Clock          | 27 MHz oscillator            |
| UART           | USB-C (via CH340)            |
| Video          | HDMI out                     |
| Storage        | microSD slot                 |
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
TMDS output. The default Gowin project currently shows the boot/status diagnostic
screen on HDMI (`BOOT_DIAG_ONLY=true`) with SD signals tied inactive, so a missing
or unported SD-card path is visible as a timeout instead of a blank screen.

The full SD/SDRAM boot computer is still not ported to the Tang board. The active
Tang SBC core is the internal-BSRAM `sbc_minimal_top`; set `BOOT_DIAG_ONLY=false`
when you want HDMI to show that core's VIC output instead of the diagnostic
screen.

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
