#!/usr/bin/env python3
"""
Create a small 16 KiB ROM image for live upload through the FPGA monitor.

The image is mapped at $C000-$FFFF. It clears text VRAM, writes a few lines to
the VGA text screen, prints a UART banner, then blinks VIA Port B.
"""
from __future__ import annotations

from pathlib import Path

ROM_BASE = 0xC000
ROM_SIZE = 0x4000
OUT = Path(__file__).resolve().parent / "roms" / "upload_demo.rom"

VIC_BASE = 0x8000
VIA_ORB = 0x8800
VIA_DDRB = 0x8802
UART_DATA = 0x8810
UART_STATUS = 0x8811
UART_TDRE = 0x10


class Builder:
    """Tiny label-aware 6502 emitter for the upload smoke-test ROM.

    Keeping this ROM generator self-contained avoids a cc65 dependency for the
    live-upload workflow. Only the addressing modes used by the demo are emitted.
    """

    def __init__(self) -> None:
        self.buf = bytearray()
        self.labels: dict[str, int] = {}
        self.rel_fixups: list[tuple[int, str]] = []
        self.abs_fixups: list[tuple[int, str]] = []

    @property
    def pc(self) -> int:
        return ROM_BASE + len(self.buf)

    def label(self, name: str) -> None:
        self.labels[name] = self.pc

    def b(self, *values: int) -> None:
        self.buf.extend(v & 0xFF for v in values)

    def word(self, value: int) -> None:
        self.b(value, value >> 8)

    def word_label(self, target: str) -> None:
        self.b(0x00, 0x00)
        self.abs_fixups.append((len(self.buf) - 2, target))

    def jmp(self, target: str) -> None:
        self.b(0x4C)
        self.word_label(target)

    def jsr(self, target: str) -> None:
        self.b(0x20)
        self.word_label(target)

    def branch(self, opcode: int, target: str) -> None:
        self.b(opcode, 0x00)
        self.rel_fixups.append((len(self.buf) - 1, target))

    def resolve(self) -> None:
        # Resolve branches and absolute JSR/JMP targets after all labels are
        # known. This prevents address-estimate bugs when the demo grows.
        for at, target_name in self.rel_fixups:
            target = self.labels[target_name]
            branch_pc_after_operand = ROM_BASE + at + 1
            rel = target - branch_pc_after_operand
            if not -128 <= rel <= 127:
                raise ValueError(f"branch to {target_name} out of range: {rel}")
            self.buf[at] = rel & 0xFF
        for at, target_name in self.abs_fixups:
            target = self.labels[target_name]
            self.buf[at] = target & 0xFF
            self.buf[at + 1] = (target >> 8) & 0xFF


def row(n: int) -> int:
    return VIC_BASE + n * 40


def put_string(rom: bytearray, addr: int, text: bytes) -> None:
    off = addr - ROM_BASE
    rom[off : off + len(text) + 1] = text + b"\x00"


def emit_print_vram(b: Builder, msg_addr: int, dst_addr: int, name: str) -> None:
    # Copy a zero-terminated string into text VRAM. The VGA path reads the same
    # RAM, so successful writes are visible immediately on the monitor.
    loop = f"{name}_loop"
    done = f"{name}_done"
    b.b(0xA2, 0x00)  # LDX #0
    b.label(loop)
    b.b(0xBD)
    b.word(msg_addr)  # LDA msg,X
    b.branch(0xF0, done)  # BEQ done
    b.b(0x9D)
    b.word(dst_addr)  # STA dst,X
    b.b(0xE8)  # INX
    b.jmp(loop)
    b.label(done)


def emit_print_uart(b: Builder, msg_addr: int) -> None:
    # Poll TDRE before every transmitted byte; the board UART serializer is much
    # slower than the 6502 bus and would drop bytes without this wait.
    b.b(0xA2, 0x00)  # LDX #0
    b.label("uart_loop")
    b.b(0xBD)
    b.word(msg_addr)  # LDA msg,X
    b.branch(0xF0, "uart_done")  # BEQ done
    b.label("uart_wait")
    b.b(0xAD)
    b.word(UART_STATUS)  # LDA UART_STATUS
    b.b(0x29, UART_TDRE)  # AND #TDRE
    b.branch(0xF0, "uart_wait")  # BEQ wait
    b.b(0xBD)
    b.word(msg_addr)  # LDA msg,X
    b.b(0x8D)
    b.word(UART_DATA)  # STA UART_DATA
    b.b(0xE8)  # INX
    b.jmp("uart_loop")
    b.label("uart_done")


def build_rom() -> bytearray:
    data = bytearray([0xEA] * ROM_SIZE)
    asm = Builder()

    msg_base = 0xC300
    messages = {
        "title": b"      UART LOAD DEMO ROM",
        "line1": b"  UPLOADED OVER FPGA MONITOR",
        "line2": b"  RUNNING FROM SHADOW ROM AT $C000",
        "line3": b"  VIA PB0 -> BOARD LED1 SLOW BLINK",
        "line4": b"  BUTTON -> MONITOR,  M C000 C080",
        "uart": b"\r\n[UPLOAD DEMO] ROM ACTIVE AT $C000\r\n",
    }

    msg_addr: dict[str, int] = {}
    cursor = msg_base
    for name, text in messages.items():
        msg_addr[name] = cursor
        cursor += len(text) + 1

    asm.label("reset")
    asm.b(0x78)  # SEI
    asm.b(0xD8)  # CLD
    asm.b(0xA2, 0xFF)  # LDX #$FF
    asm.b(0x9A)  # TXS
    asm.b(0xA9, 0x00)  # LDA #$00
    asm.b(0x85, 0x00)  # STA $00

    # VIA Port B as output, so the LEDs show life immediately.
    asm.b(0xA9, 0xFF)  # LDA #$FF
    asm.b(0x8D)
    asm.word(VIA_DDRB)  # STA VIA_DDRB
    asm.b(0xA9, 0x00)  # LDA #$00
    asm.b(0x8D)
    asm.word(VIA_ORB)  # STA VIA_ORB

    # Clear the 2 KiB text RAM. This mirrors the style of fpga/asm/rom_demo.s.
    asm.b(0xA9, 0x20)  # LDA #' '
    asm.b(0xA2, 0x00)  # LDX #0
    asm.label("clear_loop")
    for page in range(8):
        asm.b(0x9D)
        asm.word(VIC_BASE + page * 0x100)  # STA $80xx,X ... $87xx,X
    asm.b(0xE8)  # INX
    asm.branch(0xD0, "clear_loop")  # BNE clear_loop

    emit_print_vram(asm, msg_addr["title"], row(2), "p_title")
    emit_print_vram(asm, msg_addr["line1"], row(4), "p_line1")
    emit_print_vram(asm, msg_addr["line2"], row(6), "p_line2")
    emit_print_vram(asm, msg_addr["line3"], row(8), "p_line3")
    emit_print_vram(asm, msg_addr["line4"], row(10), "p_line4")
    emit_print_uart(asm, msg_addr["uart"])

    asm.label("main")
    # Toggle only bit 0 because the board top maps via_portb(0) to LED 1 after
    # boot. LED 0 is a separate boot-status LED and may stay on.
    asm.b(0xA5, 0x00)  # LDA $00
    asm.b(0x49, 0x01)  # EOR #$01
    asm.b(0x85, 0x00)  # STA $00
    asm.b(0x8D)
    asm.word(VIA_ORB)  # STA VIA_ORB
    asm.jsr("delay")
    asm.jmp("main")

    asm.label("delay")
    asm.b(0xA9, 0x20)  # LDA #$20
    asm.label("delay_block")
    asm.b(0x48)  # PHA
    asm.b(0xA0, 0x00)  # LDY #0
    asm.label("delay_outer")
    asm.b(0xA2, 0x00)  # LDX #0
    asm.label("delay_inner")
    asm.b(0xCA)  # DEX
    asm.branch(0xD0, "delay_inner")  # BNE delay_inner
    asm.b(0x88)  # DEY
    asm.branch(0xD0, "delay_outer")  # BNE delay_outer
    asm.b(0x68)  # PLA
    asm.b(0x38)  # SEC
    asm.b(0xE9, 0x01)  # SBC #$01
    asm.branch(0xD0, "delay_block")  # BNE delay_block
    asm.b(0x60)  # RTS

    asm.resolve()
    data[0 : len(asm.buf)] = asm.buf

    for name, text in messages.items():
        put_string(data, msg_addr[name], text)

    def set_vec(vector_addr: int, target: int) -> None:
        off = vector_addr - ROM_BASE
        data[off] = target & 0xFF
        data[off + 1] = (target >> 8) & 0xFF

    set_vec(0xFFFA, asm.labels["reset"])
    set_vec(0xFFFC, asm.labels["reset"])
    set_vec(0xFFFE, asm.labels["reset"])
    return data


def main() -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    rom = build_rom()
    OUT.write_bytes(rom)
    print(f"wrote {len(rom)} bytes -> {OUT}")
    print("entry/reset: $C000")
    print("upload with: python tools/upload_monitor_hex.py --run")


if __name__ == "__main__":
    main()
