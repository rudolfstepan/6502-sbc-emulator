#!/usr/bin/env python3
"""
Upload a binary image through the FPGA UART monitor hex loader.

Default workflow:
  1. Press the hardware monitor button on the board.
  2. Run: python tools/upload_monitor_hex.py --build-demo --run

The monitor command used is:
  L <address>
  <hex bytes...>
  .
  G <address>   (only with --run)
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_PORT = "COM15"
DEFAULT_BAUD = 230400
DEFAULT_ADDR = 0xC000
DEFAULT_IMAGE = Path(__file__).resolve().parent / "roms" / "upload_demo.rom"


def require_pyserial():
    try:
        import serial  # type: ignore
    except ImportError:
        print("ERROR: pyserial is not installed.", file=sys.stderr)
        print("Install it with: python -m pip install pyserial", file=sys.stderr)
        raise SystemExit(2)
    return serial


def build_demo() -> None:
    script = Path(__file__).resolve().parent / "make_upload_demo_rom.py"
    subprocess.run([sys.executable, str(script)], check=True)


def hex_lines(data: bytes, bytes_per_line: int) -> list[str]:
    # The FPGA monitor accepts plain two-digit hex bytes. Keeping lines modest
    # gives the UART receiver and command parser slack while keeping uploads quick.
    lines = []
    for offset in range(0, len(data), bytes_per_line):
        chunk = data[offset : offset + bytes_per_line]
        lines.append(" ".join(f"{byte:02X}" for byte in chunk))
    return lines


def read_some(port, seconds: float) -> bytes:
    # The monitor is intentionally simple and does not use an ACK per data line.
    # We sample the serial input around command boundaries to show prompts/errors
    # without blocking the streaming upload path.
    deadline = time.monotonic() + seconds
    out = bytearray()
    while time.monotonic() < deadline:
        waiting = getattr(port, "in_waiting", 0)
        if waiting:
            out.extend(port.read(waiting))
        else:
            time.sleep(0.02)
    return bytes(out)


def write_line(port, text: str, delay: float) -> None:
    port.write(text.encode("ascii") + b"\r")
    port.flush()
    if delay:
        time.sleep(delay)


def upload(args: argparse.Namespace) -> None:
    serial = require_pyserial()
    image = Path(args.image)
    data = image.read_bytes()
    if args.length is not None:
        data = data[: args.length]

    if not data:
        raise SystemExit(f"ERROR: image is empty: {image}")

    print(f"Opening {args.port} @ {args.baud} baud")
    with serial.Serial(args.port, args.baud, timeout=0.05, write_timeout=2) as port:
        time.sleep(args.settle)
        banner = read_some(port, 0.25)
        if banner and args.verbose:
            print(banner.decode("ascii", errors="replace"), end="")

        print(f"Starting monitor upload: ${args.address:04X}, {len(data)} bytes")
        write_line(port, f"L {args.address:04X}", args.command_delay)
        if args.wait_load:
            response = read_some(port, args.wait_load)
            if args.verbose and response:
                print(response.decode("ascii", errors="replace"), end="")

        sent = 0
        for line in hex_lines(data, args.bytes_per_line):
            # Data lines are fire-and-forget; the final "." is where the monitor
            # reports OK/ERR after the last byte has been committed.
            write_line(port, line, args.line_delay)
            sent += min(args.bytes_per_line, len(data) - sent)
            if args.progress and (sent == len(data) or sent % args.progress == 0):
                print(f"  {sent:5d}/{len(data)} bytes")

        write_line(port, ".", args.command_delay)
        response = read_some(port, args.wait_done)
        if args.verbose and response:
            print(response.decode("ascii", errors="replace"), end="")

        if args.run:
            print(f"Starting CPU at ${args.address:04X}")
            write_line(port, f"G {args.address:04X}", args.command_delay)
            response = read_some(port, args.wait_done)
            if args.verbose and response:
                print(response.decode("ascii", errors="replace"), end="")

    print("Upload complete")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", nargs="?", default=DEFAULT_IMAGE, help="binary image to upload")
    parser.add_argument("--port", default=DEFAULT_PORT, help="serial port, default COM15")
    parser.add_argument("--baud", type=int, default=DEFAULT_BAUD, help="baud rate, default 230400")
    parser.add_argument("--address", type=lambda s: int(s, 0), default=DEFAULT_ADDR, help="load address")
    parser.add_argument("--length", type=lambda s: int(s, 0), help="limit upload length")
    parser.add_argument("--bytes-per-line", type=int, default=32, help="hex bytes per monitor line")
    parser.add_argument("--line-delay", type=float, default=0.005, help="delay after each data line")
    parser.add_argument("--command-delay", type=float, default=0.05, help="delay after monitor commands")
    parser.add_argument("--settle", type=float, default=0.2, help="delay after opening the port")
    parser.add_argument("--wait-load", type=float, default=0.4, help="seconds to read after L command")
    parser.add_argument("--wait-done", type=float, default=0.8, help="seconds to read after . or G")
    parser.add_argument("--progress", type=int, default=1024, help="progress interval in bytes, 0 disables")
    parser.add_argument("--run", action="store_true", help="send G <address> after upload")
    parser.add_argument("--build-demo", action="store_true", help="generate the default demo ROM first")
    parser.add_argument("--verbose", action="store_true", help="print monitor responses")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.build_demo:
        build_demo()
    upload(args)


if __name__ == "__main__":
    main()
