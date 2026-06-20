; soundtest.s — 4-voice sound-chip demo ROM for the FPGA SBC.
;
; Builds a 16 KB ROM image ($C000-$FFFF) that uploads to the shadow ROM and runs
; exactly like the EhBASIC ROM:
;
;   make -C fpga/sw soundtest
;   python fpga/tools/upload_monitor_hex.py fpga/sw/soundtest.rom \
;          --port COM15 --baud 230400 --address 0xC000 --run --verbose
;
; On start it writes a title to the HDMI text screen and then loops forever
; through a demo: each of the 5 waveforms on voice 0, an ADSR "swell", and a
; 4-voice chord — exercising sound_chip4 (sine/square/saw/triangle/noise, ADSR
; envelopes, note duration, and the mixer).

; ── Sound chip: voice base addresses (src/soundchip.h) ──────────────────
V0 = $8830
V1 = $8890
V2 = $889A
V3 = $88A4
; register offsets within a voice
R_CTRL = 5

; ── VIC text screen ─────────────────────────────────────────────────────
SCREEN = $8000
COLOR  = $8400

; ── PLAY macro: load voice base + param block, call play ────────────────
.macro PLAY vbase, pblock
    lda #<vbase
    sta vptr
    lda #>vbase
    sta vptr+1
    lda #<pblock
    sta pptr
    lda #>pblock
    sta pptr+1
    jsr play
.endmacro

.segment "ZEROPAGE"
vptr:   .res 2          ; voice base pointer
pptr:   .res 2          ; parameter-block pointer
dctr:   .res 1          ; delay outer counter

.segment "CODE"

reset:
    sei
    cld
    ldx #$FF
    txs

    jsr title

main_loop:
    ; ---- one note per waveform on voice 0 ----
    PLAY V0, p_sine
    jsr pause
    PLAY V0, p_square
    jsr pause
    PLAY V0, p_saw
    jsr pause
    PLAY V0, p_tri
    jsr pause
    PLAY V0, p_noise
    jsr pause

    ; ---- ADSR swell on voice 0 ----
    PLAY V0, p_swell
    jsr pause_long

    ; ---- 4-voice chord (trigger all voices together) ----
    PLAY V0, p_ch0
    PLAY V1, p_ch1
    PLAY V2, p_ch2
    PLAY V3, p_ch3
    jsr pause_long
    jsr pause

    jmp main_loop

; ── play: copy the 10-byte param block into the voice, then trigger ─────
; The block's CONTROL byte has bit0 = 0 (waveform only). We copy all ten
; registers (so ATTACK..RELEASE are set), then re-write CONTROL with bit0 = 1,
; which captures the registers and starts the note (matches the C model).
play:
    ldy #0
@copy:
    lda (pptr),y
    sta (vptr),y
    iny
    cpy #10
    bne @copy
    ldy #R_CTRL
    lda (vptr),y
    ora #$01
    sta (vptr),y
    rts

; ── title: write "SOUND TEST" to the text screen in white ───────────────
title:
    ldx #0
@t:
    lda title_txt,x
    sta SCREEN,x
    lda #$01            ; white
    sta COLOR,x
    inx
    cpx #title_len
    bne @t
    rts

; ── delay loops (note auto-stops after its duration; these space them) ──
pause:
    lda #$06
    bne delay
pause_long:
    lda #$20
delay:
    sta dctr
@o:
    ldx #0
@x:
    ldy #0
@y:
    iny
    bne @y
    inx
    bne @x
    dec dctr
    bne @o
    rts

; ── interrupt handlers (unused) ─────────────────────────────────────────
irqh:
    rti

.segment "RODATA"

; "SOUND TEST" in VIC screen codes (A=1 .. Z=26, space=32)
title_txt:
    .byte 19,15,21,14,4, 32, 20,5,19,20
title_len = * - title_txt

; Parameter blocks: FREQ_LO,FREQ_HI, DUR_LO,DUR_HI, VOLUME, CONTROL,
;                   ATTACK, DECAY, SUSTAIN, RELEASE
; CONTROL = waveform<<4 (bit0 cleared; play sets the trigger bit).
; Waveforms: 0=sine 1=square 2=sawtooth 3=triangle 4=noise.

; 440 Hz = $01B8, 250 ms = $00FA, flat envelope (sustain 255)
p_sine:   .byte $B8,$01, $FA,$00, 255, $00, 0,0,255,0
p_square: .byte $B8,$01, $FA,$00, 255, $10, 0,0,255,0
p_saw:    .byte $B8,$01, $FA,$00, 255, $20, 0,0,255,0
p_tri:    .byte $B8,$01, $FA,$00, 255, $30, 0,0,255,0
; noise: pitch barely matters; 700 ms burst
p_noise:  .byte $00,$02, $BC,$02, 255, $40, 0,0,255,0

; ADSR swell: 330 Hz (E4), 1200 ms, sine, attack 200 ms / decay 200 ms /
; sustain 120 / release 320 ms  (8 ms per ADSR unit)
p_swell:  .byte $4A,$01, $B0,$04, 255, $00, 25,25,120,40

; C-major chord, 900 ms, sine, gentle envelope
; C4=262=$0106  E4=330=$014A  G4=392=$0188  C5=523=$020B
p_ch0:    .byte $06,$01, $84,$03, 200, $00, 3,12,180,30
p_ch1:    .byte $4A,$01, $84,$03, 200, $00, 3,12,180,30
p_ch2:    .byte $88,$01, $84,$03, 200, $00, 3,12,180,30
p_ch3:    .byte $0B,$02, $84,$03, 200, $00, 3,12,180,30

.segment "VECTORS"
    .word irqh          ; $FFFA NMI
    .word reset         ; $FFFC RESET
    .word irqh          ; $FFFE IRQ/BRK
