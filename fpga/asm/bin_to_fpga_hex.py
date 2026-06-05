#!/usr/bin/env python3
"""
bin_to_fpga_hex.py  -  Convert a raw binary ROM to FPGA sim hex format.

The FPGA rom.vhd loader reads lines of the form:
    XXXX YY
where XXXX is the 4-digit hex ROM offset (0-based from ROM start)
and YY is the byte value.  Bytes equal to the default fill (0xEA = NOP)
are omitted since rom.vhd pre-fills with 0xEA.

Usage:
    python bin_to_fpga_hex.py <input.bin> <rom_base> <rom_size> <output.hex>

    rom_base  hex address where the ROM starts in CPU address space (e.g. 0xF800)
    rom_size  hex size of the ROM in bytes (e.g. 0x0800 for 2 KB)

Example:
    python bin_to_fpga_hex.py rom_demo.bin 0xF800 0x0800 ../sim/rom_welcome.hex
"""
import sys

FILL = 0xEA  # rom.vhd default fill (NOP)


def main():
    if len(sys.argv) != 5:
        print(__doc__)
        sys.exit(1)

    infile   = sys.argv[1]
    rom_base = int(sys.argv[2], 16)
    rom_size = int(sys.argv[3], 16)
    outfile  = sys.argv[4]

    with open(infile, 'rb') as f:
        data = f.read()

    # Pad or trim to the declared ROM size
    data = (data + bytes([FILL] * rom_size))[:rom_size]

    lines = []
    for offset, byte in enumerate(data):
        if byte != FILL:
            lines.append(f"{offset:04X} {byte:02X}\n")

    with open(outfile, 'w', newline='\n') as f:
        f.writelines(lines)

    non_fill = sum(1 for b in data if b != FILL)
    print(f"Written {outfile}  "
          f"({rom_size} bytes, base ${rom_base:04X}, "
          f"{non_fill} non-fill entries)")


if __name__ == '__main__':
    main()
