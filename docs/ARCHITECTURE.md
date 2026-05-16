# Architecture Overview

## Components

- `CPU6502`: instruction execution, interrupts, and cycle accounting
- `Bus`: address decoding and device dispatch
- `SRAM` and `ROM`: memory devices
- `VIA6522`: general-purpose I/O and timers
- `UART6551`: serial console or TCP-backed serial interface
- `Monitor`: interactive debugger for registers, memory, disassembly, stepping, and breakpoints

## Runtime Flow

1. Load configuration from `sbc.ini`.
2. Create and register bus devices.
3. Reset the CPU using the ROM reset vector.
4. Execute one instruction at a time.
5. Tick peripherals using consumed cycles.
6. Enter the monitor on breakpoint, step mode, or `SIGINT`.

## Design Notes

- ROM images are top-aligned within the configured ROM window.
- The UART can run against stdio or a localhost TCP socket.
- The monitor temporarily restores normal terminal input so debugger commands work interactively.
