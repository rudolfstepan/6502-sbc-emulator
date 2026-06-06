#!/usr/bin/env python3
"""Create a raw SD boot image for the FPGA SD ROM loader.

The image layout is intentionally simple:
  sector 0     : boot header
  sectors 1-32 : 16 KiB ROM payload for $C000-$FFFF
"""

from __future__ import annotations

import argparse
from pathlib import Path
import struct
import sys
import zlib


SECTOR_SIZE = 512
ROM_SIZE = 0x4000
MAGIC = b"SBCROM01"


def parse_offset_spec(spec: str) -> tuple[Path, int]:
    if "@" not in spec:
        return Path(spec), 0

    path_text, offset_text = spec.rsplit("@", 1)
    return Path(path_text), int(offset_text, 0)


def read_rom_file(path: Path) -> bytes:
    if path.suffix.lower() != ".hex":
        return path.read_bytes()

    values: dict[int, int] = {}
    max_offset = -1
    for line_no, line in enumerate(path.read_text().splitlines(), start=1):
        stripped = line.strip()
        if not stripped:
            continue
        parts = stripped.split()
        if len(parts) != 2:
            raise ValueError(f"{path}:{line_no}: expected '<offset> <byte>'")
        offset = int(parts[0], 16)
        value = int(parts[1], 16)
        if not 0 <= value <= 0xFF:
            raise ValueError(f"{path}:{line_no}: byte out of range")
        values[offset] = value
        max_offset = max(max_offset, offset)

    data = bytearray([0xEA] * (max_offset + 1))
    for offset, value in values.items():
        data[offset] = value
    return bytes(data)


def build_payload(inputs: list[str]) -> bytes:
    payload = bytearray([0xEA] * ROM_SIZE)

    for spec in inputs:
        path, offset = parse_offset_spec(spec)
        data = read_rom_file(path)
        if offset < 0 or offset + len(data) > ROM_SIZE:
            raise ValueError(
                f"{path} at offset 0x{offset:x} does not fit in {ROM_SIZE} bytes"
            )
        payload[offset : offset + len(data)] = data

    return bytes(payload)


def build_header(payload: bytes) -> bytes:
    header = bytearray(SECTOR_SIZE)
    checksum = zlib.crc32(payload) & 0xFFFFFFFF

    header[0:8] = MAGIC
    struct.pack_into("<H", header, 0x08, 0xC000)
    struct.pack_into("<H", header, 0x0A, len(payload))
    struct.pack_into("<I", header, 0x0C, checksum)
    return bytes(header)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Create raw SD boot image with 16 KiB SBC ROM payload"
    )
    parser.add_argument(
        "--output",
        "-o",
        required=True,
        type=Path,
        help="Output image path",
    )
    parser.add_argument(
        "rom",
        nargs="+",
        help="ROM file, optionally with @offset, e.g. roms/kernel.rom@0x0000",
    )
    args = parser.parse_args(argv)

    payload = build_payload(args.rom)
    image = build_header(payload) + payload
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(image)

    print(f"Wrote {args.output} ({len(image)} bytes)")
    print(f"Payload CRC32: {zlib.crc32(payload) & 0xFFFFFFFF:08x}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
