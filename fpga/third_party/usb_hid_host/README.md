# usb_hid_host — nand2mario / hi631

A compact USB HID host core for FPGAs.  
Supports keyboard, mouse, and gamepad over **low-speed USB (1.5 Mbps)** using
direct GPIO bit-bang on D+ and D−.  Two 15 kΩ pull-down resistors (D± to GND)
and a 12 MHz clock are required; no PHY chip needed.

**Source:** https://github.com/nand2mario/usb_hid_host  
**Authors:** nand2mario (2023), based on original work by hi631  
**License:** Apache License 2.0 (see LICENSE)

## Files in this directory

| File | Origin | Notes |
|------|--------|-------|
| `usb_hid_host_nm.v` | nand2mario `src/usb_hid_host.v` | Top module renamed `usb_hid_host` → `usb_hid_host_nm` to avoid conflict with our VHDL wrapper |
| `usb_hid_host_rom.v` | nand2mario `src/usb_hid_host_rom.v` | Unchanged |
| `usb_hid_host_rom.hex` | nand2mario `src/usb_hid_host_rom.hex` | UKP microprocessor ROM; must stay in same directory as usb_hid_host_rom.v (`$readmemh` relative path) |
| `LICENSE` | nand2mario repo root | Apache 2.0 |

## Usage in this project

The VHDL wrapper at `fpga/rtl/core/usb/usb_hid_host.vhd` instantiates
`usb_hid_host_nm` and provides the system-bus register interface (4 registers:
STATUS, KEY, MODIF, ASCII) and clock-domain crossing (12 MHz USB → 27 MHz
system clock).

## Attribution notice (Apache 2.0 §4d)

This project incorporates software developed by nand2mario and hi631,
licensed under the Apache License, Version 2.0.
