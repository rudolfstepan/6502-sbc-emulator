; ============================================================================
;  6502 SBC FPGA - hardware blitter liquid water demo (640x400 RGB332)
;
;  Load/entry address is $1000. Build with tools/make_water_prg.sh, upload
;  with roms/6502/upload/water.bat from the FPGA repo.
;
;  The animation is made from many small, phase-shifted FILL rectangles. There
;  are no blitter LINE commands; the moving liquid is a field of tiny droplets
;  and glints that wobble over a dark blue base.
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
phase   = $10
band    = $11
seg     = $12
color   = $13
tmp     = $14
signext = $15
pxlo    = $16
pxhi    = $17
pylo    = $18
pyhi    = $19

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
    lda #3
    sta BLIT_GAP

    lda #0
    sta phase

main_loop:
    jsr draw_background
    jsr draw_waves
    jsr draw_glints
    jsr wait_frame

    inc phase
    lda phase
    and #$0f
    sta phase
    jmp main_loop

; ---------------------------------------------------------------------------
;  draw_background - deep water base
; ---------------------------------------------------------------------------
draw_background:
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
    lda #$02
    sta color
    jmp start_fill

; ---------------------------------------------------------------------------
;  draw_waves - 28 bands x 32 tiny droplets, each wobbling independently
; ---------------------------------------------------------------------------
draw_waves:
    lda #0
    sta band
@band_loop:
    lda #0
    sta seg
@seg_loop:
    jsr prepare_y
    jsr prepare_x0
    jsr prepare_x1

    lda band
    clc
    adc phase
    adc seg
    and #$07
    tax
    lda water_palette,x
    sta color
    jsr start_fill

    inc seg
    lda seg
    cmp #32
    bne @seg_loop

    inc band
    lda band
    cmp #28
    bne @band_loop
    rts

prepare_y:
    lda phase
    clc
    adc seg
    adc band
    and #$0f
    tax
    lda wave_y,x
    sta tmp

    ldx band
    lda band_ylo,x
    sta pylo
    lda band_yhi,x
    sta pyhi
    lda tmp
    jsr add_signed_to_py

    lda pylo
    sta BLIT_Y0LO
    lda pyhi
    sta BLIT_Y0HI
    ldx seg
    lda pylo
    clc
    adc drop_h,x
    sta BLIT_Y1LO
    lda pyhi
    adc #0
    sta BLIT_Y1HI
    rts

prepare_x0:
    jsr load_x_wobble
    ldx seg
    lda seg_x0lo,x
    sta pxlo
    lda seg_x0hi,x
    sta pxhi
    lda tmp
    jsr add_signed_to_px
    lda pxlo
    sta BLIT_X0LO
    lda pxhi
    sta BLIT_X0HI
    rts

prepare_x1:
    ldx seg
    lda pxlo
    clc
    adc drop_w,x
    sta pxlo
    lda pxhi
    adc #0
    sta pxhi
    lda pxlo
    sta BLIT_X1LO
    lda pxhi
    sta BLIT_X1HI
    rts

load_x_wobble:
    lda phase
    asl
    clc
    adc band
    adc seg
    and #$0f
    tax
    lda wave_x,x
    sta tmp
    rts

; ---------------------------------------------------------------------------
;  draw_glints - small bright highlights drifting on top of the wave field
; ---------------------------------------------------------------------------
draw_glints:
    lda #0
    sta seg
@loop:
    ldx seg
    lda glint_xlo,x
    sta pxlo
    lda glint_xhi,x
    sta pxhi
    lda phase
    asl
    jsr add_unsigned_to_px

    ldx seg
    lda glint_ylo,x
    sta pylo
    lda glint_yhi,x
    sta pyhi
    lda phase
    clc
    adc seg
    and #$0f
    tax
    lda wave_y,x
    sta tmp
    lda tmp
    jsr add_signed_to_py

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

    lda #$7f
    sta color
    jsr start_fill

    inc seg
    lda seg
    cmp #10
    bne @loop
    rts

; A = unsigned offset added to pxhi:pxlo.
add_unsigned_to_px:
    clc
    adc pxlo
    sta pxlo
    lda pxhi
    adc #0
    sta pxhi
    rts

; A = signed byte added to pxhi:pxlo.
add_signed_to_px:
    jsr signed_extend_a
    lda pxlo
    clc
    adc tmp
    sta pxlo
    lda pxhi
    adc signext
    sta pxhi
    rts

; A = signed byte added to pyhi:pylo.
add_signed_to_py:
    jsr signed_extend_a
    lda pylo
    clc
    adc tmp
    sta pylo
    lda pyhi
    adc signext
    sta pyhi
    rts

signed_extend_a:
    sta tmp
    lda #0
    sta signext
    lda tmp
    bpl @done
    lda #$ff
    sta signext
@done:
    rts

start_fill:
    lda color
    sta BLIT_COL
    lda #OP_FILL
    sta BLIT_OP
    lda #0
    sta BLIT_PG
    sta BLIT_TRIG
    jmp blit_wait

blit_wait:
    lda BLIT_TRIG
    bmi blit_wait
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

; 28 water bands from near-surface to deep water.
band_ylo: .byte <28, <41, <54, <67, <80, <93, <106, <119, <132, <145, <158, <171, <184, <197, <210, <223, <236, <249, <262, <275, <288, <301, <314, <327, <340, <353, <366, <379
band_yhi: .byte >28, >41, >54, >67, >80, >93, >106, >119, >132, >145, >158, >171, >184, >197, >210, >223, >236, >249, >262, >275, >288, >301, >314, >327, >340, >353, >366, >379

; 32 droplets across the 640-pixel framebuffer. Most are single pixels.
seg_x0lo: .byte <6, <26, <46, <66, <86, <106, <126, <146, <166, <186, <206, <226, <246, <266, <286, <306, <326, <346, <366, <386, <406, <426, <446, <466, <486, <506, <526, <546, <566, <586, <606, <626
seg_x0hi: .byte >6, >26, >46, >66, >86, >106, >126, >146, >166, >186, >206, >226, >246, >266, >286, >306, >326, >346, >366, >386, >406, >426, >446, >466, >486, >506, >526, >546, >566, >586, >606, >626

drop_w:
    .byte 0, 0, 1, 0, 0, 2, 0, 1, 0, 0, 1, 0, 2, 0, 0, 1
    .byte 0, 0, 1, 0, 0, 2, 0, 1, 0, 0, 1, 0, 2, 0, 0, 1
drop_h:
    .byte 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0
    .byte 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0

; Two's-complement signed offsets.
wave_y: .byte 0, 2, 4, 5, 4, 2, 0, $fe, $fc, $fb, $fc, $fe, 0, 1, 3, 1
wave_x: .byte 0, 3, 6, 8, 6, 3, 0, $fd, $fa, $f8, $fa, $fd, 0, 2, 4, 2

; RGB332 dark blue through cyan-white, biased toward darker water tones.
water_palette:
    .byte $03, $07, $0b, $03, $07, $1f, $0b, $5f

glint_xlo: .byte <35, <112, <188, <248, <315, <377, <445, <503, <548, <585
glint_xhi: .byte >35, >112, >188, >248, >315, >377, >445, >503, >548, >585
glint_ylo: .byte <88, <122, <166, <205, <236, <275, <309, <334, <185, <257
glint_yhi: .byte >88, >122, >166, >205, >236, >275, >309, >334, >185, >257
