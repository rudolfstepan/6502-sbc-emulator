#!/usr/bin/env python3
"""Convert binary ROM images to the VHDL hex format used by rtl/mem/rom.vhd."""

from __future__ import annotations

import argparse
from pathlib import Path


def parse_int(value: str) -> int:
    return int(value, 0)


def parse_image_spec(spec: str) -> tuple[Path, int]:
    if "@" not in spec:
        return Path(spec), 0

    path, offset = spec.rsplit("@", 1)
    return Path(path), parse_int(offset)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Build an address/value hex file. Input specs are BIN[@OFFSET], "
            "where OFFSET is the destination offset inside the generated ROM."
        )
    )
    parser.add_argument("images", nargs="+", help="Input binary image specs: file[@offset]")
    parser.add_argument("-o", "--output", required=True, help="Output hex file")
    parser.add_argument(
        "--size",
        type=parse_int,
        default=0x4000,
        help="Output ROM size in bytes, default: 0x4000",
    )
    parser.add_argument(
        "--fill",
        type=parse_int,
        default=0xEA,
        help="Fill byte for unwritten locations, default: 0xEA",
    )
    args = parser.parse_args()

    if args.size <= 0:
        raise SystemExit("--size must be positive")
    if not 0 <= args.fill <= 0xFF:
        raise SystemExit("--fill must be a byte value")

    image = bytearray([args.fill] * args.size)

    for spec in args.images:
        path, offset = parse_image_spec(spec)
        data = path.read_bytes()

        if offset < 0:
            raise SystemExit(f"negative offset for {path}: {offset}")
        if offset + len(data) > args.size:
            raise SystemExit(
                f"{path} at offset 0x{offset:X} exceeds output size 0x{args.size:X}"
            )

        image[offset : offset + len(data)] = data

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)

    with output.open("w", encoding="ascii", newline="\n") as f:
        for offset, value in enumerate(image):
            f.write(f"{offset:04X} {value:02X}\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
