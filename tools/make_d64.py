#!/usr/bin/env python3
import argparse
from pathlib import Path

SECTORS_PER_TRACK = [0] + [21] * 17 + [19] * 7 + [18] * 6 + [17] * 5
D64_SIZE = sum(SECTORS_PER_TRACK) * 256
DIR_TRACK = 18
FT_PRG = 0x82


def sector_offset(track, sector):
    if track < 1 or track > 35 or sector < 0 or sector >= SECTORS_PER_TRACK[track]:
        raise ValueError(f"bad D64 sector {track}/{sector}")
    return (sum(SECTORS_PER_TRACK[:track]) + sector) * 256


def petscii_name(name):
    stem = Path(name).stem.upper()[:16]
    return stem.encode("ascii", "replace").ljust(16, b"\xA0")


def track_sector_order(track, interleave=11):
    """Return a C1541-ish sector order for a track.

    Sequential PRG chains make the FPGA SD backend read the lower and upper
    halves of the same 512-byte card sector back-to-back.  A real disk normally
    uses an interleave; doing the same here avoids that hot path and keeps the
    image closer to physical 1541 layout.
    """
    total = SECTORS_PER_TRACK[track]
    seen = set()
    sector = 0
    order = []
    while len(order) < total:
        while sector in seen:
            sector = (sector + 1) % total
        order.append(sector)
        seen.add(sector)
        sector = (sector + interleave) % total
    return order


def allocate_chain(blocks_needed):
    blocks = []
    for track in list(range(1, DIR_TRACK)) + list(range(DIR_TRACK + 1, 36)):
        for sector in track_sector_order(track):
            blocks.append((track, sector))
            if len(blocks) == blocks_needed:
                return blocks
    raise RuntimeError("D64 full")


def write_bam(image, disk_name, used):
    bam = sector_offset(DIR_TRACK, 0)
    image[bam + 0] = DIR_TRACK
    image[bam + 1] = 1
    image[bam + 2] = 0x41
    image[bam + 3] = 0x00

    for track in range(1, 36):
        total = SECTORS_PER_TRACK[track]
        free = 0
        bits = 0
        for sector in range(total):
            if (track, sector) not in used:
                free += 1
                bits |= 1 << sector
        base = bam + 4 + (track - 1) * 4
        image[base + 0] = free & 0xFF
        image[base + 1] = bits & 0xFF
        image[base + 2] = (bits >> 8) & 0xFF
        image[base + 3] = (bits >> 16) & 0xFF

    image[bam + 0x90:bam + 0xA0] = disk_name.upper()[:16].encode("ascii", "replace").ljust(16, b"\xA0")
    image[bam + 0xA0:bam + 0xA8] = b"\xA0\xA00\x30\xA02A\xA0"


def main():
    ap = argparse.ArgumentParser(description="Create a minimal D64 with one PRG")
    ap.add_argument("input_prg")
    ap.add_argument("output_d64")
    ap.add_argument("--name", default=None)
    ap.add_argument("--load-addr", default="0x0300")
    ap.add_argument("--input-has-load-addr", action="store_true",
                    help="input PRG already begins with its two-byte load address")
    ap.add_argument("--disk-name", default="SBC6502")
    args = ap.parse_args()

    payload = Path(args.input_prg).read_bytes()
    load_addr = int(args.load_addr, 0)
    if args.input_has_load_addr:
        prg = payload
    else:
        prg = bytes([load_addr & 0xFF, (load_addr >> 8) & 0xFF]) + payload
    blocks_needed = (len(prg) + 253) // 254
    blocks = allocate_chain(blocks_needed)
    used = set(blocks)
    used.add((DIR_TRACK, 0))
    used.add((DIR_TRACK, 1))

    image = bytearray([0x00] * D64_SIZE)

    pos = 0
    for i, (track, sector) in enumerate(blocks):
        off = sector_offset(track, sector)
        chunk = prg[pos:pos + 254]
        pos += len(chunk)
        if i + 1 < len(blocks):
            nt, ns = blocks[i + 1]
            image[off] = nt
            image[off + 1] = ns
            image[off + 2:off + 2 + len(chunk)] = chunk
        else:
            image[off] = 0
            image[off + 1] = len(chunk) + 1
            image[off + 2:off + 2 + len(chunk)] = chunk

    directory = sector_offset(DIR_TRACK, 1)
    image[directory] = 0
    image[directory + 1] = 0xFF
    entry = directory + 2
    image[entry + 0] = FT_PRG
    image[entry + 1] = blocks[0][0]
    image[entry + 2] = blocks[0][1]
    image[entry + 3:entry + 19] = petscii_name(args.name or args.input_prg)
    image[entry + 30] = blocks_needed & 0xFF
    image[entry + 31] = (blocks_needed >> 8) & 0xFF
    write_bam(image, args.disk_name, used)

    out = Path(args.output_d64)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(image)
    print(f"Created {out} with {Path(args.input_prg).name} ({len(prg)} bytes, {blocks_needed} blocks)")


if __name__ == "__main__":
    main()
