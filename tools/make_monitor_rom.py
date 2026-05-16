#!/usr/bin/env python3
"""
Ultra-simple Echo Monitor ROM for 6502 SBC

Just: read char -> echo -> repeat
Similar to Apple I monitor but even simpler
"""
import os

ROM_SIZE = 0x4000
ROM_BASE = 0xC000

# Build simple ROM:
# $C000: Init, then loop: wait for char, echo, repeat
code = bytearray()

# Entry at $C000
code += bytes([0xA2, 0xFF])    # LDX #$FF  (init SP)
code += bytes([0x9A])          # TXS

# Main loop at $C002 - print prompt
code += bytes([0xA9, 0x0D])    # LDA #13 (CR)
code += bytes([0x8D, 0x10, 0x80])  # STA $8010
code += bytes([0xA9, 0x0A])    # LDA #10 (LF)
code += bytes([0x8D, 0x10, 0x80])  # STA $8010
code += bytes([0xA9, 0x3E])    # LDA #'>'
code += bytes([0x8D, 0x10, 0x80])  # STA $8010
code += bytes([0xA9, 0x20])    # LDA #' '
code += bytes([0x8D, 0x10, 0x80])  # STA $8010

# Wait for input: loop until RDRF bit set
code += bytes([0xAD, 0x11, 0x80])  # LDA $8011 (status)
code += bytes([0x29, 0x08])    # AND #$08
code += bytes([0xF0, 0xFB])    # BEQ -5 (wait)

# Read and echo (at $C017)
code += bytes([0xAD, 0x10, 0x80])  # LDA $8010
code += bytes([0x8D, 0x10, 0x80])  # STA $8010 (echo back)

# Jump back to wait loop (NOT to prompt) - this avoids CR/LF after each char
code += bytes([0x4C, 0x0E, 0xC0])  # JMP $C00E (to wait loop)

# Pad to ROM size
data = bytearray([0xEA] * ROM_SIZE)
data[0:len(code)] = code

# Vectors
def set_vec(addr, target):
    off = addr - ROM_BASE
    data[off] = target & 0xFF
    data[off + 1] = (target >> 8) & 0xFF

set_vec(0xFFFA, 0xC000)  # NMI
set_vec(0xFFFC, 0xC000)  # RESET
set_vec(0xFFFE, 0xC000)  # IRQ

# Write
out = os.path.join(os.path.dirname(__file__), "..", "roms", "monitor.rom")
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "wb") as f:
    f.write(data)

print(f"✓ Monitor ROM: {out}")
print(f"  Simple echo loop: prints '> ', reads char, echoes, repeats")
print(f"  Type CTRL+C to enter emulator monitor")
print()
print(f"Usage: ./sbc6502 -r roms/monitor.rom")
print(f"  - Type 'q' or 'Q': exits to emulator monitor (then use 'c' to continue)")
print(f"  - CTRL+C:          enters emulator monitor directly")
