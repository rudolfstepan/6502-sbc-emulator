; ============================================================================
;  6502 SBC FPGA - hardware blitter pixel fireworks demo (640x400 RGB332)
;
;  Load/entry address is $1000. Build with tools/make_fireworks_prg.sh, upload
;  with roms/6502/upload/fireworks.bat from the FPGA repo.
;
;  This demo does not use blitter LINE at all. Every spark is a tiny FILL
;  rectangle, so the effect is made from spraying pixels instead of spokes.
; ============================================================================

.import __LOADADDR__

.segment "EXEHDR"
    .word __LOADADDR__

; ---- VIC registers ---------------------------------------------------------
VIC_MODE   = $9000
VIC_ISR    = $9007
VIC_PAGE   = $900F
VIC2_CTRL1 = $D011

MODE_HIRES_RGB332 = $20
IRQ_FRAME         = $02

; ---- hardware 2D blitter ($8840-$884F) ------------------------------------
BLIT_X0LO = $8840
BLIT_X0HI = $8841
BLIT_Y0LO = $8842
BLIT_Y0HI = $8843
BLIT_X1LO = $8844
BLIT_X1HI = $8845
BLIT_Y1LO = $8846
BLIT_Y1HI = $8847
BLIT_COL  = $8848
BLIT_OP   = $8849
BLIT_PG   = $884A
BLIT_GAP  = $884B
BLIT_TRIG = $884F

OP_FILL = 0

; ---- zero page scratch -----------------------------------------------------
cxlo    = $10
cxhi    = $11
cylo    = $12
cyhi    = $13
burst   = $14
phase   = $15
spark   = $16
color   = $17
signext = $18
tmp     = $19
offlo   = $1A
offhi   = $1B
pxlo    = $1C
pxhi    = $1D
pylo    = $1E
pyhi    = $1F

.segment "CODE"

start:
    sei
    cld
    ldx #$ff
    txs

    lda #MODE_HIRES_RGB332
    sta VIC_MODE
    lda #0
    sta VIC_PAGE
    lda #4
    sta BLIT_GAP

    jsr clear_page

main_loop:
    lda #0
    sta burst

burst_loop:
    jsr clear_page

    ldx burst
    lda burst_xlo,x
    sta cxlo
    lda burst_xhi,x
    sta cxhi
    lda burst_ylo,x
    sta cylo
    lda burst_yhi,x
    sta cyhi

    jsr draw_core
    lda #3
    jsr wait_frames

    lda #1
    sta phase
phase_loop:
    jsr draw_sparks
    lda #3
    jsr wait_frames

    inc phase
    lda phase
    cmp #8
    bne phase_loop

    lda #22
    jsr wait_frames

    inc burst
    lda burst
    cmp #5
    bne burst_loop
    jmp main_loop

; ---------------------------------------------------------------------------
;  draw_core - a small bright block at the ignition point
; ---------------------------------------------------------------------------
draw_core:
    lda cxlo
    sec
    sbc #2
    sta BLIT_X0LO
    lda cxhi
    sbc #0
    sta BLIT_X0HI
    lda cylo
    sec
    sbc #2
    sta BLIT_Y0LO
    lda cyhi
    sbc #0
    sta BLIT_Y0HI

    lda cxlo
    clc
    adc #2
    sta BLIT_X1LO
    lda cxhi
    adc #0
    sta BLIT_X1HI
    lda cylo
    clc
    adc #2
    sta BLIT_Y1LO
    lda cyhi
    adc #0
    sta BLIT_Y1HI

    lda #$e7
    sta color
    jmp start_fill

; ---------------------------------------------------------------------------
;  draw_sparks - draw 32 pixel particles for the current expansion phase
; ---------------------------------------------------------------------------
draw_sparks:
    lda #0
    sta spark
@loop:
    ldx spark
    lda vx_table,x
    jsr scale_signed_by_phase
    jsr set_pixel_x_from_offset

    ldx spark
    lda vy_table,x
    jsr scale_signed_by_phase
    jsr set_pixel_y_from_offset

    lda spark
    clc
    adc phase
    and #$07
    tax
    lda palette,x
    sta color
    jsr plot_spark

    inc spark
    lda spark
    cmp #32
    bne @loop
    rts

; A = signed 8-bit velocity. Result = A * phase in offhi:offlo.
scale_signed_by_phase:
    sta tmp
    lda #0
    sta offlo
    sta offhi
    lda tmp
    bpl @positive
    lda #$ff
    bne @have_sign
@positive:
    lda #0
@have_sign:
    sta signext
    ldx phase
    beq @done
@mul:
    lda offlo
    clc
    adc tmp
    sta offlo
    lda offhi
    adc signext
    sta offhi
    dex
    bne @mul
@done:
    rts

set_pixel_x_from_offset:
    lda offlo
    clc
    adc cxlo
    sta pxlo
    lda cxhi
    adc offhi
    sta pxhi
    rts

set_pixel_y_from_offset:
    lda offlo
    clc
    adc cylo
    sta pylo
    lda cyhi
    adc offhi
    sta pyhi
    rts

; Draw a 2x2 pixel-art spark at px/py.
plot_spark:
    lda pxlo
    sta BLIT_X0LO
    lda pxhi
    sta BLIT_X0HI
    lda pylo
    sta BLIT_Y0LO
    lda pyhi
    sta BLIT_Y0HI

    lda pxlo
    clc
    adc #1
    sta BLIT_X1LO
    lda pxhi
    adc #0
    sta BLIT_X1HI
    lda pylo
    clc
    adc #1
    sta BLIT_Y1LO
    lda pyhi
    adc #0
    sta BLIT_Y1HI

start_fill:
    lda color
    sta BLIT_COL
    lda #OP_FILL
    sta BLIT_OP
    lda #0
    sta BLIT_PG
    sta BLIT_TRIG
    jmp blit_wait

clear_page:
    lda #$00
    sta BLIT_X0LO
    sta BLIT_X0HI
    sta BLIT_Y0LO
    sta BLIT_Y0HI
    lda #<639
    sta BLIT_X1LO
    lda #>639
    sta BLIT_X1HI
    lda #<399
    sta BLIT_Y1LO
    lda #>399
    sta BLIT_Y1HI
    lda #$00
    sta BLIT_COL
    lda #OP_FILL
    sta BLIT_OP
    lda #0
    sta BLIT_PG
    sta BLIT_TRIG
    jsr blit_wait
    rts

blit_wait:
    lda BLIT_TRIG
    bmi blit_wait
    rts

; A = number of frames to wait
wait_frames:
    tax
@loop:
    jsr wait_frame
    dex
    bne @loop
    rts

; Wait for vblank on emulator ($9007 bit 1) and FPGA ($D011 raster bit 8 edge).
wait_frame:
    lda #IRQ_FRAME
    sta VIC_ISR
    ldy #0
@poll:
    lda VIC_ISR
    and #IRQ_FRAME
    bne @done
    lda VIC2_CTRL1
    bmi @high
    cpy #1
    beq @done
    bne @poll
@high:
    ldy #1
    bne @poll
@done:
    lda #IRQ_FRAME
    sta VIC_ISR
    rts

.segment "RODATA"

; Burst centers are chosen so phase 7 at velocity +/-16 stays on screen.
burst_xlo: .byte <120, <320, <520, <210, <430
burst_xhi: .byte >120, >320, >520, >210, >430
burst_ylo: .byte <150, <125, <155, <225, <215
burst_yhi: .byte >150, >125, >155, >225, >215

; RGB332: pink, white, yellow, orange, cyan, blue-white, green, red.
palette:
    .byte $e7, $ff, $fc, $f8, $1f, $7f, $1c, $e0

; 32 signed velocity vectors around the burst. Written as two's complement
; bytes because ca65 range-checks .byte operands.
vx_table:
    .byte   0,  3,  6,  9, 11, 13, 15, 16
    .byte  16, 15, 13, 11,  9,  6,  3,  0
    .byte $fd,$fa,$f7,$f5,$f3,$f1,$f0,$f0
    .byte $f0,$f1,$f3,$f5,$f7,$fa,$fd,  0

vy_table:
    .byte $f0,$f0,$f1,$f3,$f5,$f7,$fa,$fd
    .byte   0,  3,  6,  9, 11, 13, 15, 16
    .byte  16, 15, 13, 11,  9,  6,  3,  0
    .byte $fd,$fa,$f7,$f5,$f3,$f1,$f0,$f0
