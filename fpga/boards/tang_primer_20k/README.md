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

**Not yet implemented.** The top-level wrapper and board-specific primitives
(rPLL, BSRAM wrappers for SDRAM, HDMI encoder) still need to be written.

## Build

```bash
# From this directory
make project   # create GowinEDA project
make build     # synthesise + place & route
make bitstream # generate .fs programming file
make program   # flash via openFPGALoader
```
