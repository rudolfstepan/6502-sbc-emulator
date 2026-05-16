#!/usr/bin/env python3
"""
Generate a minimal 6502 test ROM for the SBC emulator.
Outputs 16KB (0x4000 bytes) placed at $C000–$FFFF.

Program: print "Hello, 6502 SBC!\r\n" via UART at $8010, then halt.

Layout ($C000 base):
 $C000  A2 00        LDX #0
 $C002  BD 11 C0     LDA $C011,X      ; msg at $C011
 $C005  F0 07        BEQ $C00E        ; null-terminator -> halt
 $C007  8D 10 80     STA $8010        ; UART TX
 $C00A  E8           INX
 $C00B  4C 02 C0     JMP $C002        ; loop
 $C00E  4C 0E C0     JMP $C00E        ; halt
 $C011  "Hello, 6502 SBC!\r\n" 00

Vectors ($FFFA-$FFFF):
 $FFFA/$FFFB  NMI  -> $C00E
 $FFFC/$FFFD  RST  -> $C000
 $FFFE/$FFFF  IRQ  -> $C00E
"""
import struct, sys, os

ROM_SIZE   = 0x4000        # 16 KB
ROM_BASE   = 0xC000

code = bytes([
    0xA2, 0x00,             # LDX #0
    0xBD, 0x11, 0xC0,       # LDA $C011,X
    0xF0, 0x07,             # BEQ +7  -> $C00E
    0x8D, 0x10, 0x80,       # STA $8010  (UART data)
    0xE8,                   # INX
    0x4C, 0x02, 0xC0,       # JMP $C002
    0x4C, 0x0E, 0xC0,       # JMP $C00E  (halt)
])
# Should be 17 bytes; msg starts at $C011
assert len(code) == 0x11, f"code len={len(code):#04x}, expected 0x11"

msg = b"Hello, 6502 SBC!\r\n\x00"

data = bytearray([0xEA] * ROM_SIZE)   # fill with NOP

# Place code + message at offset 0 (= $C000)
data[0:len(code)]               = code
data[len(code):len(code)+len(msg)] = msg

# Vectors
HALT = 0xC00E
RST  = 0xC000

def set_vec(buf, addr, target):
    off = addr - ROM_BASE
    buf[off]   = target & 0xFF
    buf[off+1] = (target >> 8) & 0xFF

set_vec(data, 0xFFFA, HALT)   # NMI
set_vec(data, 0xFFFC, RST)    # RESET
set_vec(data, 0xFFFE, HALT)   # IRQ

out = os.path.join(os.path.dirname(__file__), "roms", "rom.bin")
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "wb") as f:
    f.write(data)
print(f"Written {len(data)} bytes -> {out}")
print(f"Reset vector: ${RST:04X}")
print(f"Message at:   $C011")
