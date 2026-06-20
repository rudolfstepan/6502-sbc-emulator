# Tang Primer 20K — 6502 SBC

Target: Sipeed Tang Primer 20K (Gowin GW2A-LV18PG256C8/I7)

## Board Specs

| Resource       | Value                        |
|----------------|------------------------------|
| FPGA           | Gowin GW2A-18C / `GW2A-LV18PG256C8/I7` |
| SDRAM          | 64 MB (onboard)              |
| Clock          | 27 MHz oscillator; PLL derives 54 MHz SBC / 27 MHz pixel / 135 MHz TMDS |
| UART           | CH340 USB-UART / pins `M11/T13` |
| Video          | HDMI out                     |
| Storage        | On-board microSD/SDIO slot in SPI mode |
| Audio          | Dock PT8211 audio DAC        |
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

The SBC logic runs at 54 MHz. Its two-phase T65 bus advances the CPU every
second system clock, giving a 27 MHz maximum 6502 bus rate before VIC stalls.
The VIC uses `CLK_DIV=2`, so video timing remains at exactly 27 MHz.
Continuous VIC prefetch steals 82 of 1716 system clocks per scan line (about
4.8%), leaving an average CPU throughput of roughly 25.7 MHz.

Clock derivation uses a single 270 MHz PLL root. TMDS FCLK is `270/2 = 135 MHz`,
the SBC is `270/5 = 54 MHz`, and OSER10 PCLK is derived directly from its FCLK as
`135/5 = 27 MHz`. The direct FCLK/PCLK relationship is required for stable HDMI.

On reset the FPGA shows the boot/status diagnostic screen while it initializes
the on-board microSD/SDIO slot in SPI mode and loads the 16 KB ROM image into
shadow ROM. After a successful load the CPU is released and HDMI switches to the
SBC VIC output.

Current bring-up status:

- HDMI boot/status screen works on a monitor.
- CH340 UART works from the PC as a normal serial port, tested as `COM12`.
- The UART monitor is reachable through the same CH340 path.
- KEY0 (dock S0) is the reset button: a short press soft-resets the 6502, a long
  press (>1 s) is a full board reset.
- KEY1 enters the FPGA monitor and holds the 6502 CPU.
- Without a card in the on-board microSD slot, the boot debug output correctly
  reports that the SD card cannot be initialized/read.
- PS/2 keyboard input works via PMOD 0 — keystrokes are injected into the
  UART receive path so EhBASIC and the monitor see them without software changes.

The Tang boot core currently uses internal BSRAM for main RAM instead of the
on-board SDRAM. Pressing KEY1 enters the FPGA UART monitor, holds the 6502 CPU,
and switches HDMI back to the diagnostic screen while monitor operations run.

### Buttons (reset / monitor)

The two on-board push buttons are active-low with internal pull-ups:

| Button                 | FPGA pin | Function                               |
|------------------------|----------|----------------------------------------|
| **KEY0** (dock **S0**) | `T10`    | Reset button (see below)               |
| **KEY1** (dock **S1**) | `T3`     | Enter UART monitor / hold the 6502 CPU |

KEY0 is a dual-action reset, debounced and synchronised in the 54 MHz `clk_sys`
domain:

- **Short press** → **CPU soft reset**. Only the 6502 is held in reset and then
  restarts via its reset vector. `boot_done`, the shadow ROM, and SRAM are kept,
  so a program uploaded over the UART monitor restarts in place — the SD boot
  loader is *not* re-run. This is the reset to use during normal operation.
- **Long press (>1 s)** → **full board reset**. Asserts the global `reset_n`,
  which also resets the SD ROM loader and reloads the ROM from the SD card. If
  there is no valid SD boot image, the CPU stays held afterwards (no `boot_done`),
  so use the short press for UART-uploaded ROMs.

The HDMI PLL is intentionally **not** gated by the reset button, so `clk_sys`
keeps running (the debounce/long-press timer needs it) and the picture stays up
through both reset types.

> **Pin note:** S0 is FPGA pin `T10` (matching Sipeed's own `Cam2HDMI` and HDMI
> `dk_video` examples, whose reset is `T10`). An earlier `T5` assignment was not
> the physical button and produced a dead reset key.

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

## Audio (PT8211 DAC)

The dock board's PT8211 (TM8211) audio DAC is driven by the single-voice sound
synthesizer at `$8830`–`$8839`. See [Sound Chip](../../docs/SOUND.md) for the
register map, BASIC/assembly usage, and the C-emulator-compatible programming
model.

| Signal | FPGA pin | Notes |
| --- | --- | --- |
| `dac_bck` (BCK) | N15 | bit clock |
| `dac_ws` (WS/LRCK) | P16 | word/channel select |
| `dac_din` (DIN) | P15 | serial data, MSB first |
| `pa_en` (PA_EN) | R16 | **amp enable — tied high; without it the amp only hisses** |

Pinout matches Sipeed's `TangPrimer-20K-example/PT8211`. These pins are in Bank 1
(VCCIO locked to 3.3 V by other ports), so they are constrained `LVCMOS33`.

> The sound sources (`sound_voice.vhd`, `pt8211_dac.vhd`) must be listed in
> `project/build.tcl` — the PowerShell build drives `gw_sh build.tcl`, not the
> `.gprj`. If they are missing, GowinEDA synthesizes them as black boxes and the
> DAC outputs float (hiss / silence).

Quick test from BASIC:

```basic
10 POKE 34864,184 : POKE 34865,1 : REM 440 Hz
20 POKE 34868,255 : REM volume
30 POKE 34869,17  : REM square + gate on
40 FOR I=1 TO 1000 : NEXT
50 POKE 34869,0   : REM gate off
```

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
