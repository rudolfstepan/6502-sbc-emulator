#!/usr/bin/env python3
"""Convert a siddump raw frame stream into a 6502 player ROM for sound_chip4.

  siddump.exe <file.sid> <seconds> --raw frames.raw
  convert_sid.py frames.raw soundsid.s [delay] [--no-vectors]

The player loops the excerpt forever. Each 50 Hz frame it applies any pending
frequency CHANGES (compressed: only stored when the SID frequency changes, so
held notes cost nothing) so vibrato/slides/arpeggios track, and it fires a note
trigger on each SID gate-on, with the note length set to the gate-high span.
SID filter / pulse-width / ring-mod are dropped. Targets the 16 KB shadow ROM
at $C000 (reliable "G C000" entry).
"""
import argparse
from pathlib import Path

from rom_screen import SCREEN_CODE, bytes_directive


PAL_CLK = 985248.0
FRAME_RATE = 50
FRAME_BYTES = 15
MAX_FRAMES = 0xFF00 - 1
ATK_MS = [2, 8, 16, 24, 38, 56, 68, 80, 100, 250, 500, 800, 1000, 3000, 5000, 8000]
DECREL_MS = [6, 24, 48, 72, 114, 168, 204, 240, 300, 750, 1500, 2400, 3000, 9000, 15000, 24000]


def hz_of(register: int) -> int:
    return round(register * PAL_CLK / 16777216.0)


def waveform(control: int) -> int:
    for bit, value in ((0x80, 4), (0x40, 1), (0x20, 2), (0x10, 3)):
        if control & bit:
            return value
    return 0


def player_streams(raw: bytes, frame_ms: int) -> dict[str, bytes | bytearray]:
    frame_count = len(raw) // FRAME_BYTES
    streams = {}
    events = []
    for voice in range(3):
        voice_frames = [
            raw[offset + voice * 5:offset + (voice + 1) * 5]
            for offset in range(0, len(raw), FRAME_BYTES)
        ]
        changes = bytearray()
        previous_hz = -1
        previous_gate = False
        for frame, (low, high, control, attack_decay, sustain_release) in enumerate(voice_frames):
            hz = hz_of(low | (high << 8))
            if hz != previous_hz:
                changes.extend((frame & 0xFF, frame >> 8, hz & 0xFF, hz >> 8))
                previous_hz = hz

            gate = bool(control & 1)
            if gate and not previous_gate:
                end = frame + 1
                while end < frame_count and voice_frames[end][2] & 1:
                    end += 1
                duration = min(65535, (end - frame) * frame_ms)
                events.append((
                    frame, voice, waveform(control),
                    min(255, ATK_MS[attack_decay >> 4] // 8),
                    min(255, DECREL_MS[attack_decay & 15] // 8),
                    (sustain_release >> 4) * 17,
                    min(255, DECREL_MS[sustain_release & 15] // 8),
                    duration & 0xFF, duration >> 8,
                ))
            previous_gate = gate

        changes.extend((0xFF, 0xFF, 0, 0))
        streams[f"chg{voice}"] = changes

    event_stream = bytearray()
    events.sort(key=lambda event: event[0])
    for frame, *data in events:
        event_stream.extend((frame & 0xFF, frame >> 8, *data))
    event_stream.extend((0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0))
    streams["events"] = event_stream
    return streams


def write_assembly(raw: bytes, output: Path, delay: int, *,
                   screen: bytes | None = None, vectors: bool = True) -> int:
    frame_count, remainder = divmod(len(raw), FRAME_BYTES)
    if remainder or not 1 <= frame_count <= MAX_FRAMES:
        raise ValueError("expected a complete, nonempty SID frame stream within the frame limit")
    standalone = screen is not None
    frame_ms = (delay + 5) // 10 if standalone else 20
    if standalone and not 1 <= frame_ms <= 200:
        raise ValueError("standalone frame delay must round to 1–200 ms")
    streams = player_streams(raw, frame_ms)
    if screen is not None:
        streams["screen_text"] = screen
        timing = f"TIME_MS = $883A\nFRAME_MS = {frame_ms}\ndelay_start = $1C"
    else:
        delay_high = max(1, min(255, round(delay / 200)))
        timing = f"DELAY_HI = {delay_high}\nDELAY_MID = 200"

    program = PLAYER.format(
        nframes=frame_count,
        timing=timing,
        startup="    jsr draw_title\n" if standalone else "",
        wait_on_last_frame="    jsr delay\n" if standalone else "",
        wait_before_next_frame="" if standalone else "    jsr delay\n",
        delay_code=TIMER_DELAY if standalone else LEGACY_DELAY,
    )
    with output.open("w", encoding="ascii", newline="\n") as assembly:
        assembly.write(program)
        if standalone:
            assembly.write(SCREEN_CODE)
        assembly.write('\n.segment "RODATA"\n\n')
        for label, data in streams.items():
            assembly.write(bytes_directive(label, data))
        if vectors:
            assembly.write('\n.segment "VECTORS"\n    .word reset, reset, reset\n')
    return frame_count


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("frames", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("delay", type=int, nargs="?", default=2400)
    parser.add_argument("--no-vectors", action="store_true")
    args = parser.parse_args()
    try:
        frames = write_assembly(args.frames.read_bytes(), args.output, args.delay,
                                vectors=not args.no_vectors)
    except (OSError, ValueError) as error:
        parser.exit(1, f"SID conversion failed: {error}\n")
    print(f"Converted {frames} frames ({frames / FRAME_RATE:.1f} s) to {args.output}")


PLAYER = r"""; soundsid.s - GENERATED by tools/sid_convert/convert_sid.py  (do not edit)
; Plays a converted SID excerpt on sound_chip4: compressed live-frequency
; changes + per-note triggers, looped forever.

V0 = $8830
V1 = $8890
V2 = $889A

cp0 = $10
cp1 = $12
cp2 = $14
ep  = $16
fr  = $18
vb  = $1A

NFRAMES = {nframes}
{timing}

.segment "CODE"

reset:
    sei
    cld
    ldx #$FF
    txs
{startup}restart:
    lda #<chg0
    sta cp0
    lda #>chg0
    sta cp0+1
    lda #<chg1
    sta cp1
    lda #>chg1
    sta cp1+1
    lda #<chg2
    sta cp2
    lda #>chg2
    sta cp2+1
    lda #<events
    sta ep
    lda #>events
    sta ep+1
    lda #0
    sta fr
    sta fr+1

frame_loop:
    ; voice 0 frequency changes due this frame
@f0:
    ldy #1
    lda (cp0),y
    cmp #$FF
    beq @f0d
    cmp fr+1
    bne @f0d
    dey
    lda (cp0),y
    cmp fr
    bne @f0d
    ldy #2
    lda (cp0),y
    sta V0+0
    ldy #3
    lda (cp0),y
    sta V0+1
    ldx #cp0
    jsr adv4
    jmp @f0
@f0d:
    ; voice 1
@f1:
    ldy #1
    lda (cp1),y
    cmp #$FF
    beq @f1d
    cmp fr+1
    bne @f1d
    dey
    lda (cp1),y
    cmp fr
    bne @f1d
    ldy #2
    lda (cp1),y
    sta V1+0
    ldy #3
    lda (cp1),y
    sta V1+1
    ldx #cp1
    jsr adv4
    jmp @f1
@f1d:
    ; voice 2
@f2:
    ldy #1
    lda (cp2),y
    cmp #$FF
    beq @f2d
    cmp fr+1
    bne @f2d
    dey
    lda (cp2),y
    cmp fr
    bne @f2d
    ldy #2
    lda (cp2),y
    sta V2+0
    ldy #3
    lda (cp2),y
    sta V2+1
    ldx #cp2
    jsr adv4
    jmp @f2
@f2d:

    ; note-on events for this frame
ev_loop:
    ldy #1
    lda (ep),y
    cmp #$FF
    beq ev_done
    cmp fr+1
    bne ev_done
    dey
    lda (ep),y
    cmp fr
    bne ev_done
    jsr apply_event
    jmp ev_loop
ev_done:
{wait_on_last_frame}
    inc fr
    bne @nf
    inc fr+1
@nf:
    lda fr+1
    cmp #>NFRAMES
    bne @cont
    lda fr
    cmp #<NFRAMES
    bne @cont
    jmp restart
@cont:
{wait_before_next_frame}    jmp frame_loop

; add 4 to the ZP pointer whose low byte is at $00,X
adv4:
    clc
    lda $00,x
    adc #4
    sta $00,x
    bcc @d
    inc $01,x
@d:
    rts

apply_event:
    ldy #2
    lda (ep),y
    tax
    lda vbl,x
    sta vb
    lda vbh,x
    sta vb+1
    ldy #8
    lda (ep),y
    ldy #2
    sta (vb),y
    ldy #9
    lda (ep),y
    ldy #3
    sta (vb),y
    lda #200
    ldy #4
    sta (vb),y
    ldy #4
    lda (ep),y
    ldy #6
    sta (vb),y
    ldy #5
    lda (ep),y
    ldy #7
    sta (vb),y
    ldy #6
    lda (ep),y
    ldy #8
    sta (vb),y
    ldy #7
    lda (ep),y
    ldy #9
    sta (vb),y
    ldy #3
    lda (ep),y
    asl
    asl
    asl
    asl
    ora #$01
    ldy #5
    sta (vb),y
    clc
    lda ep
    adc #10
    sta ep
    bcc @d
    inc ep+1
@d:
    rts

{delay_code}

vbl: .byte <V0, <V1, <V2
vbh: .byte >V0, >V1, >V2
"""

LEGACY_DELAY = """; 3-level busy-wait paces the frame rate: DELAY_HI x DELAY_MID x 256 iterations.
; Tune via the convert_sid.py delay argument (larger = slower).
delay:
    ldx #DELAY_HI
@o:
    lda #DELAY_MID
@m:
    ldy #0
@i:
    dey
    bne @i
    sec
    sbc #1
    bne @m
    dex
    bne @o
    rts
"""

TIMER_DELAY = """; Wait one frame on the sound chip timer. Subtraction handles wrap at 256 ms.
delay:
    lda TIME_MS
    sta delay_start
@wait:
    lda TIME_MS
    sec
    sbc delay_start
    cmp #FRAME_MS
    bcc @wait
    rts
"""

if __name__ == "__main__":
    main()
