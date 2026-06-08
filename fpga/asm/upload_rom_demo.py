#!/usr/bin/env python3
"""
Upload rom_demo.bin to the PIX16 FPGA board via the UART debug monitor.

Workflow:
  1. Synthesize and load the FPGA bitstream (boot screen appears on VGA).
  2. Press the monitor button on the board (KEY0) to activate the monitor.
  3. Run this script:
       python upload_rom_demo.py --build --run --verbose

The script sends:
  L F800          -- enter hex-load mode at the ROM shadow base
  <hex bytes>     -- 2048 bytes of rom_demo.bin as two-digit hex pairs
  .               -- end load, monitor confirms OK
  G F800          -- jump to reset vector (only with --run)
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

HERE       = Path(__file__).resolve().parent
ROM_BIN    = HERE / "rom_demo.bin"
ROM_ADDR   = 0xF800

DEFAULT_PORT = "COM15"
DEFAULT_BAUD = 230400


def require_pyserial():
    try:
        import serial  # type: ignore
    except ImportError:
        print("ERROR: pyserial not installed.  Run: pip install pyserial", file=sys.stderr)
        raise SystemExit(2)
    return serial


def build() -> None:
    print("Building rom_demo …")
    subprocess.run(["make", "all"], cwd=HERE, check=True)
    print("Build OK")


def hex_lines(data: bytes, per_line: int) -> list[str]:
    lines = []
    for off in range(0, len(data), per_line):
        chunk = data[off : off + per_line]
        lines.append(" ".join(f"{b:02X}" for b in chunk))
    return lines


def read_some(port, seconds: float) -> bytes:
    deadline = time.monotonic() + seconds
    buf = bytearray()
    while time.monotonic() < deadline:
        n = getattr(port, "in_waiting", 0)
        if n:
            buf.extend(port.read(n))
        else:
            time.sleep(0.02)
    return bytes(buf)


def send(port, text: str, delay: float) -> None:
    port.write(text.encode("ascii") + b"\r")
    port.flush()
    if delay:
        time.sleep(delay)


def upload(args: argparse.Namespace) -> None:
    serial = require_pyserial()

    data = ROM_BIN.read_bytes()
    print(f"ROM:  {ROM_BIN.name}  ({len(data)} bytes)")

    print(f"Port: {args.port}  @  {args.baud} baud")
    with serial.Serial(args.port, args.baud, timeout=0.05, write_timeout=2) as port:
        time.sleep(args.settle)

        # Drain any pending monitor output (banner / prompt)
        banner = read_some(port, 0.25)
        if args.verbose and banner:
            print(banner.decode("ascii", errors="replace"), end="")

        # Enter hex-load mode
        print(f"L {ROM_ADDR:04X}  →  starting upload …")
        send(port, f"L {ROM_ADDR:04X}", args.cmd_delay)
        resp = read_some(port, args.wait_load)
        if args.verbose and resp:
            print(resp.decode("ascii", errors="replace"), end="")

        # Stream hex bytes
        lines = hex_lines(data, args.per_line)
        sent  = 0
        for line in lines:
            send(port, line, args.line_delay)
            sent += min(args.per_line, len(data) - sent)
            if args.progress and (sent == len(data) or sent % args.progress == 0):
                pct = 100 * sent // len(data)
                print(f"  {sent:5d}/{len(data)}  ({pct}%)")

        # End load
        send(port, ".", args.cmd_delay)
        resp = read_some(port, args.wait_done)
        if args.verbose and resp:
            print(resp.decode("ascii", errors="replace"), end="")

        # Jump to ROM entry point
        if args.run:
            print(f"G {ROM_ADDR:04X}  →  starting CPU …")
            send(port, f"G {ROM_ADDR:04X}", args.cmd_delay)
            resp = read_some(port, args.wait_done)
            if args.verbose and resp:
                print(resp.decode("ascii", errors="replace"), end="")

    print("Done.")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port",     default=DEFAULT_PORT,
                   help=f"serial port  (default: {DEFAULT_PORT})")
    p.add_argument("--baud",     type=int, default=DEFAULT_BAUD,
                   help=f"baud rate    (default: {DEFAULT_BAUD})")
    p.add_argument("--build",    action="store_true",
                   help="run 'make all' before uploading")
    p.add_argument("--run",      action="store_true",
                   help="send G F800 after upload to start the CPU")
    p.add_argument("--verbose",  action="store_true",
                   help="print monitor responses")
    p.add_argument("--per-line", type=int, default=32,
                   help="hex bytes per line sent to monitor (default: 32)")
    p.add_argument("--line-delay",  type=float, default=0.005,
                   help="seconds between data lines (default: 0.005)")
    p.add_argument("--cmd-delay",   type=float, default=0.05,
                   help="seconds after L / . / G commands (default: 0.05)")
    p.add_argument("--settle",      type=float, default=0.2,
                   help="seconds after opening port (default: 0.2)")
    p.add_argument("--wait-load",   type=float, default=0.4,
                   help="seconds to wait for LOAD HEX prompt (default: 0.4)")
    p.add_argument("--wait-done",   type=float, default=0.8,
                   help="seconds to wait after . or G (default: 0.8)")
    p.add_argument("--progress",    type=int, default=512,
                   help="print progress every N bytes, 0 disables (default: 512)")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    if args.build:
        build()
    if not ROM_BIN.exists():
        print(f"ERROR: {ROM_BIN} not found – run with --build first", file=sys.stderr)
        raise SystemExit(1)
    upload(args)


if __name__ == "__main__":
    main()
