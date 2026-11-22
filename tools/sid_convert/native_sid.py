"""Wrap an original PSID player for the SBC's native SID registers."""

from pathlib import Path
import struct

from rom_screen import SCREEN_CODE, bytes_directive


NATIVE_RAM_END = 0x6000


def write_native_assembly(data: bytes, output: Path, *, song: int,
                          frame_ms: int, screen: bytes) -> None:
    version, offset, load, init, play, songs, _, speed = struct.unpack_from(">7HI", data, 4)
    if data[:4] != b"PSID" or not 1 <= version <= 4 or not 1 <= song <= songs:
        raise ValueError("unsupported PSID header or subtune")
    header_size = 0x76 if version == 1 else 0x7C
    if not header_size <= offset < len(data):
        raise ValueError("invalid PSID data offset")
    if version > 1:
        flags = int.from_bytes(data[0x76:0x78], "big")
        if ((flags & 3) or ((flags >> 2) & 3) == 2 or
                (version >= 3 and data[0x7A]) or (version >= 4 and data[0x7B])):
            raise ValueError("the native player supports standard PAL tunes for one SID")
    if not play or speed & (1 << min(song - 1, 31)):
        raise ValueError("the subtune must use PAL VBI timing and specify a play address")

    payload = data[offset:]
    if load == 0:
        if len(payload) < 3:
            raise ValueError("missing PSID load address or payload")
        load = int.from_bytes(payload[:2], "little")
        payload = payload[2:]
    init = init or load
    pages = (len(payload) + 255) // 256
    if load < 0x0200 or load + pages * 256 > NATIVE_RAM_END:
        raise ValueError("the native player needs its payload in SBC RAM ($0200–$5FFF)")
    if not all(load <= entry < load + len(payload) for entry in (init, play)):
        raise ValueError("the PSID init and play entry points must be inside the payload")
    payload = payload.ljust(pages * 256, b"\0")
    assembly = PLAYER.format(
        load=load, init=init, play=play, pages=pages, song=song - 1, frame_ms=frame_ms,
    )
    with output.open("w", encoding="ascii", newline="\n") as source:
        source.write(assembly)
        source.write(SCREEN_CODE)
        source.write('\n.segment "RODATA"\n')
        source.write(bytes_directive("sid_payload", payload))
        source.write(bytes_directive("screen_text", screen))
        source.write('\n.segment "VECTORS"\n    .word ignore_irq, reset, ignore_irq\n')


PLAYER = """
TIME_MS = $883A
COPY_SRC = $F0
COPY_DST = $F2

.segment "CODE"

reset:
    sei
    cld
    ldx #$FF
    txs
    jsr draw_title

    lda #<sid_payload
    sta COPY_SRC
    lda #>sid_payload
    sta COPY_SRC+1
    lda #<${load:04X}
    sta COPY_DST
    lda #>${load:04X}
    sta COPY_DST+1
    ldx #{pages}
    ldy #0
@copy:
    lda (COPY_SRC), y
    sta (COPY_DST), y
    iny
    bne @copy
    inc COPY_SRC+1
    inc COPY_DST+1
    dex
    bne @copy

    lda #{song}
    ldx #0
    ldy #0
    clc
    jsr ${init:04X}
    sei
    cld
    lda TIME_MS
    pha

play_loop:
    ; Keep timing state on the stack, outside the tune's RAM and zero-page variables.
    tsx
    lda TIME_MS
    sec
    sbc $0101, x
    cmp #{frame_ms}
    bcc play_loop
    lda $0101, x
    clc
    adc #{frame_ms}
    sta $0101, x
    jsr ${play:04X}
    cld
    jmp play_loop

ignore_irq:
    rti
"""
