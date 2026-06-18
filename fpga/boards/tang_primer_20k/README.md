# Tang Primer 20K — 6502 SBC

Target: Sipeed Tang Primer 20K (Gowin GW2A-LV18PG256C8/I7)

## Board Specs

| Resource       | Value                        |
|----------------|------------------------------|
| FPGA           | Gowin GW2A-18C / `GW2A-LV18PG256C8/I7` |
| SDRAM          | 64 MB (onboard)              |
| Clock          | 27 MHz oscillator            |
| UART           | CH340 USB-UART / pins `M11/T13` |
| Video          | HDMI out                     |
| Storage        | On-board microSD/SDIO slot in SPI mode |
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
TMDS output at 27 MHz pixel clock with CEA-861 480p total timing (858×525),
giving standard 640×480 @ 59.94 Hz (31.47 kHz H-sync).  An earlier version used
800×525 totals which produced non-standard 33.75 kHz / 64.3 Hz timing that some
monitors could not sync to.

On reset the FPGA shows the boot/status diagnostic screen while it initializes
the on-board microSD/SDIO slot in SPI mode and loads the 16 KB ROM image into
shadow ROM. After a successful load the CPU is released and HDMI switches to the
SBC VIC output.

Current bring-up status:

- HDMI boot/status screen works on a monitor.
- CH340 UART works from the PC as a normal serial port, tested as `COM12`.
- The UART monitor is reachable through the same CH340 path.
- KEY1 enters the FPGA monitor and holds the 6502 CPU.
- Without a card in the on-board microSD slot, the boot debug output correctly
  reports that the SD card cannot be initialized/read.
- PS/2 keyboard input works via PMOD 0 — keystrokes are injected into the
  UART receive path so EhBASIC and the monitor see them without software changes.

The Tang boot core currently uses internal BSRAM for main RAM instead of the
on-board SDRAM. Pressing KEY1 enters the FPGA UART monitor, holds the 6502 CPU,
and switches HDMI back to the diagnostic screen while monitor operations run.

The CH340 UART is connected to the SBC UART at 230400 8N1 on FPGA pins `M11`
(`uart_tx`) and `T13` (`uart_rx`). On Windows this appears as a COM port such as
`COM12` and is used for normal SBC input and output. The USB-OTG connector for
peripherals is separate from this UART path.

UART ownership priority is:

1. FPGA monitor while KEY1 monitor mode is active.
2. Boot debug/status output while SD boot is still running or failed.
3. Normal 6502 UART 6551 after the ROM has booted.

On-board microSD slot wiring in SPI mode:

| SBC signal | FPGA pin | SDIO signal | SPI role |
|------------|----------|-------------|----------|
| `sd_dclk` | `N10` | CLK  | SCK |
| `sd_ncs`  | `N11` | DAT3 | CS, active low |
| `sd_mosi` | `R14` | CMD  | MOSI / DI |
| `sd_miso` | `M8`  | DAT0 | MISO / DO |

The slot also exposes `DAT1=M7`, `DAT2=M10`, and card-detect `DET_A=D15`; those
are not used by the current SPI-mode boot path.

### PS/2 keyboard on PMOD 0

The SBC accepts keyboard input via a PS/2 keyboard connected to the Dock board's
PMOD 0 connector (top-left, near the MIC ARRAY silkscreen).  Keystrokes are
automatically injected into the UART 6551 receive path so EhBASIC and the UART
monitor see them without any software changes.

Supported editing keys in BASIC:

- Arrow keys move the VIC hardware cursor across the 40x25 text screen.
- Enter after cursor movement reads the full screen line (C64-style), trims
  trailing spaces, and replays it to BASIC with echo suppressed.
- Home moves the cursor to the top-left cell.
- Shift+Home or Ctrl+L clears the text screen and homes the cursor.
- Ctrl+C sends BASIC STOP/RUN-STOP (`$03`).

| PS/2 signal | FPGA pin | PMOD 0 pin | Notes                    |
|-------------|----------|------------|--------------------------|
| `ps2_clk`   | `T7`     | signal     | Internal pull-up enabled |
| `ps2_data`  | `T8`     | signal     | Internal pull-up enabled |
| VCC         | —        | 5 V        | From board 5 V rail      |
| GND         | —        | GND        |                          |

No external pull-up resistors are needed; the FPGA internal pull-ups are
sufficient for the PS/2 open-collector bus.

The boot diagnostic screen (HDMI rows 17–18) shows real-time keyboard status:

```text
USB HID: CON=1  KEY=$xx  MOD=$xx
USB HID: PH=4 DATA=$xx POLL=1 EV=x
```

`CON=1` indicates the keyboard is detected (PS/2 clock activity), `PH=4` means
connected and active, and `KEY`/`DATA` update live as keys are pressed.

#### Why PS/2 instead of USB HID

An earlier version used the nand2mario `usb_hid_host` core for direct USB
low-speed bit-bang on D+/D−.  While the core detected connected keyboards
(boot screen showed `PH` cycling between `3` and `F`), USB enumeration never
completed successfully.  The root cause was not identified — possible
contributors include keyboard compatibility (hub-based or USB 2.0-only
keyboards), signal integrity on the PMOD wiring, or timing sensitivity in
the bit-bang protocol.  The nand2mario third-party source is still present
under `third_party/usb_hid_host/` for future investigation.  PS/2 works
reliably and was adopted as the primary keyboard interface.

The on-board SDIO slot uses pins M8 (sd_miso / DAT0) and M10 (unused) which are
dual-purpose SSPI pins on the GW2A-18C. The build uses a Tcl script
(`project/build.tcl`) instead of the `.gprj` project file so that
`set_option -use_sspi_as_gpio 1` is passed to P&R before placement runs.
This permanently embeds the setting and avoids the `PR2017`/`PR2028` errors that
occur when GowinEDA regenerates `device.cfg` from `.gprj` defaults.

## Build

### Prerequisites

| Tool              | Purpose                     | Notes                                    |
|-------------------|-----------------------------|------------------------------------------|
| GowinEDA >= 1.9.8 | Synthesis + P&R + bitstream | `gw_sh` must be on `PATH`               |
| openFPGALoader    | Flash bitstream to board    | Optional; GowinEDA Programmer also works |

On Windows, add `C:\Gowin\Gowin_V1.9.8.08\IDE\bin` to your `PATH` or set
`GOWIN=C:/Gowin/Gowin_V1.9.8.08/IDE/bin/gw_sh.exe` when invoking make.

### Building the bitstream

All steps run from this directory (`fpga/boards/tang_primer_20k/`).

```bash
make build
```

This executes `gw_sh project/build.tcl` from inside `project/` and runs the full
flow — synthesis, place & route, and bitstream generation — in one shot.

The output bitstream is:

```
project/impl/pnr/tang_sbc.fs
```

### Why `build.tcl` instead of the `.gprj` project file

The on-board microSD DAT0 line (`sd_miso`, pin M8) is a dual-purpose SSPI pin on
the GW2A-18C. GowinEDA regenerates `impl/pnr/device.cfg` from the `.gprj`
defaults at the start of every P&R run and defaults SSPI to `false`, which causes
errors `PR2017` / `PR2028`.

`project/build.tcl` calls `set_option -use_sspi_as_gpio 1` before `run all` so
gw_sh writes `set SSPI regular_io = true` into `device.cfg` on the first pass.
No post-build patching is needed.

### Programming the board

With openFPGALoader (USB cable connected to the Tang Primer 20K JTAG port):

```bash
make program
```

Or manually:

```bash
openFPGALoader -b tang_primer_20k project/impl/pnr/tang_sbc.fs
```

GowinEDA Programmer can also be used: open `tang_sbc.fs` and select the
`GW2A-18C` device with the `SRAM Program` operation.

### Clean rebuild

```bash
make clean   # removes project/impl/ and project/tmp/
make build
```

### Troubleshooting

| Symptom | Fix |
|---------|-----|
| `gw_sh: command not found` | Add GowinEDA `bin/` to `PATH`, or set `GOWIN=<full path>` |
| `PR2017` / `PR2028` on `sd_miso` | Build is using the old `.gprj` flow; switch to `make build` which uses `build.tcl` |
| Newly added VHDL unit not compiled in `work` | Run `make clean && make build` to force full resynthesis |
| Stale objects from `tang_sbc.vg` | Run `make clean` — that file is a generated netlist, not source |
