#!/usr/bin/env python3
"""
Send an EhBASIC .bas program line-by-line over UART.

Usage:
  python tools/upload_basic_uart.py mandelbrot.bas --port COM15

Assumption:
  EhBASIC is already running on the FPGA and waiting at its prompt.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path


DEFAULT_PORT = "COM15"
DEFAULT_BAUD = 230400


def require_pyserial():
    try:
        import serial  # type: ignore
    except ImportError:
        print("ERROR: pyserial is not installed.", file=sys.stderr)
        print("Install it with: python -m pip install pyserial", file=sys.stderr)
        raise SystemExit(2)
    return serial


def read_some(port, seconds: float) -> bytes:
    deadline = time.monotonic() + seconds
    out = bytearray()

    while time.monotonic() < deadline:
        waiting = getattr(port, "in_waiting", 0)
        if waiting:
            out.extend(port.read(waiting))
        else:
            time.sleep(0.02)

    return bytes(out)


def normalize_basic_lines(text: str) -> list[str]:
    lines: list[str] = []

    for raw in text.splitlines():
        line = raw.rstrip()

        # skip empty lines and pure comments outside BASIC
        if not line:
            continue

        lines.append(line)

    return lines


def write_line(port, text: str, delay: float) -> None:
    port.write(text.encode("ascii", errors="replace") + b"\r")
    port.flush()

    if delay:
        time.sleep(delay)


def upload(args: argparse.Namespace) -> None:
    serial = require_pyserial()

    source = Path(args.file)
    text = source.read_text(encoding=args.encoding)
    lines = normalize_basic_lines(text)

    if not lines:
        raise SystemExit(f"ERROR: no BASIC lines found in {source}")

    print(f"Opening {args.port} @ {args.baud} baud")

    with serial.Serial(args.port, args.baud, timeout=0.05, write_timeout=2) as port:
        time.sleep(args.settle)

        banner = read_some(port, 0.3)
        if args.verbose and banner:
            print(banner.decode("ascii", errors="replace"), end="")

        if args.new:
            print("Sending NEW")
            write_line(port, "NEW", args.command_delay)
            response = read_some(port, args.wait)
            if args.verbose and response:
                print(response.decode("ascii", errors="replace"), end="")

        print(f"Uploading {len(lines)} BASIC lines from {source}")

        for index, line in enumerate(lines, start=1):
            write_line(port, line, args.line_delay)

            response = read_some(port, args.echo_wait)
            if args.verbose and response:
                print(response.decode("ascii", errors="replace"), end="")

            if args.progress and (index == len(lines) or index % args.progress == 0):
                print(f"  {index:5d}/{len(lines)} lines")

        if args.run:
            print("Sending RUN")
            write_line(port, "RUN", args.command_delay)

            response = read_some(port, args.wait)
            if args.verbose and response:
                print(response.decode("ascii", errors="replace"), end="")

    print("BASIC upload complete")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)

    parser.add_argument("file", help=".bas file to send")
    parser.add_argument("--port", default=DEFAULT_PORT, help="serial port, default COM15")
    parser.add_argument("--baud", type=int, default=DEFAULT_BAUD, help="baud rate, default 230400")
    parser.add_argument("--encoding", default="ascii", help="source file encoding, default ascii")

    parser.add_argument("--line-delay", type=float, default=0.08, help="delay after each BASIC line")
    parser.add_argument("--command-delay", type=float, default=0.2, help="delay after NEW/RUN")
    parser.add_argument("--settle", type=float, default=0.2, help="delay after opening the port")
    parser.add_argument("--wait", type=float, default=0.5, help="read time after commands")
    parser.add_argument("--echo-wait", type=float, default=0.02, help="read time after each line")

    parser.add_argument("--progress", type=int, default=10, help="progress interval in lines, 0 disables")
    parser.add_argument("--new", action="store_true", help="send NEW before upload")
    parser.add_argument("--run", action="store_true", help="send RUN after upload")
    parser.add_argument("--verbose", action="store_true", help="print BASIC responses")

    return parser.parse_args()


def main() -> None:
    args = parse_args()
    upload(args)


if __name__ == "__main__":
    main()
