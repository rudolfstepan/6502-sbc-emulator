# Simple test ROM generator to test tracing
import sys

code = [
    0xA9, 0x42,  # LDA #$42  (2 bytes)
    0x69, 0x01,  # ADC #$01  (2 bytes)
    0xEA,        # NOP       (1 byte)
    0xEA,        # NOP       (1 byte)
]

rom = [0] * 16384
for i, byte in enumerate(code):
    rom[0xC000 - 0xC000 + i] = byte

# Reset vector at $FFFC pointing to $C000
rom[0xFFFC - 0xC000] = 0x00
rom[0xFFFD - 0xC000] = 0xC0

with open('roms/test_trace.rom', 'wb') as f:
    f.write(bytes(rom))
print("Created roms/test_trace.rom")
