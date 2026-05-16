#!/usr/bin/env python3
"""
Simple 6502 echo monitor ROM.

Memory layout (addresses in 6502 space):
$C000: Initialize stack
$C002: Wait for UART input
$C005: Echo received char
$C008: Back to wait

No newlines after each character - just infinite echo loop.
"""
import os
import struct

ROM_SIZE = 0x4000  # 16KB
ROM_BASE = 0xC000

# Build ROM - start with NOP padding
rom = bytearray([0xEA] * ROM_SIZE)

# Code starts at offset 0 within ROM (= $C000 in 6502 space)
code_offset = 0

# Helper to insert bytes
def append_bytes(*b):
    global code_offset
    for byte in b:
        rom[code_offset] = byte
        code_offset += 1

# Entry: Initialize stack
append_bytes(0xA2, 0xFF)        # LDX #$FF
append_bytes(0x9A)              # TXS

# Infinite wait-and-echo loop at $C002 (offset 3)
loop_wait_offset = code_offset
append_bytes(0xAD, 0x11, 0x80)  # LDA $8011 (read UART status)
append_bytes(0x29, 0x08)        # AND #$08 (check RDRF bit 3)
append_bytes(0xF0, 0xF9)        # BEQ loop_wait (branch back 7 bytes: -7 = 0xF9)

# We have data - read and echo
append_bytes(0xAD, 0x10, 0x80)  # LDA $8010 (read UART data)
append_bytes(0x8D, 0x10, 0x80)  # STA $8010 (write back to echo)

# Back to wait loop (no CR/LF!)
target_address = ROM_BASE + loop_wait_offset
append_bytes(0x4C)              # JMP
append_bytes(target_address & 0xFF)              # Low byte
append_bytes((target_address >> 8) & 0xFF)      # High byte

# Add 0x00 boundary for clarity
append_bytes(0xEA)

# Set interrupt vectors at $FFFA (offset 0x3FFA)
rom[0x3FFA] = 0x00      # NMI vector low
rom[0x3FFB] = 0xC0      # NMI vector high
rom[0x3FFC] = 0x00      # RESET vector low
rom[0x3FFD] = 0xC0      # RESET vector high
rom[0x3FFE] = 0x00      # IRQ vector low
rom[0x3FFF] = 0xC0      # IRQ vector high

# Write ROM
outdir = os.path.dirname(__file__)
outfile = os.path.join(outdir, "..", "roms", "monitor.rom")
os.makedirs(os.path.dirname(outfile), exist_ok=True)

with open(outfile, "wb") as f:
    f.write(rom)

print(f"✓ Echo monitor ROM: {outfile}")
print(f"  Entry: $C000 (init stack)")
print(f"  Loop: $C003 (wait for UART, echo, repeat)")
print(f"  - Read status: AD 11 80 (LDA $8011)")
print(f"  - Check RDRF:  29 08    (AND #$08)")
print(f"  - Wait if empty: F0 F9 (BEQ -7, back to $C003)")
print(f"  - Read data: AD 10 80  (LDA $8010)")
print(f"  - Echo back: 8D 10 80  (STA $8010)")
print(f"  - Loop: 4C 03 C0       (JMP $C003)")
print()
print(f"Usage: ./sbc6502 -r roms/monitor.rom")
print(f"Type text - characters are echoed IMMEDIATELY without extra newlines")
print(f"Press CTRL+C to enter emulator monitor")
