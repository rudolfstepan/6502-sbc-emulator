; ============================================================================
;  Blitter animation test: draw objects, then MOVE them (erase + redraw).
;
;  Runs on the flashed bitstream via UART upload -- no re-synth.
;
;  Animation pattern (flicker-free): wait ONCE per frame for the vertical
;  blanking, then erase + redraw + decorate back-to-back with the $884F BUSY
;  poll between ops. All drawing lands in the blanking / top margin before the
;  raster reaches the object row, so the object is never shown half-drawn.
;
;  IMPORTANT: the FPGA has NO frame flag at $9007 (reads as $00 there; that
;  register layout exists only in the emulator). The frame wait uses the
;  C64-compatible raster read-back at $D011 instead: bit 7 = raster bit 8 of
;  the free-running 525-line scan counter. One frame = bit 8 rises (line 256)
;  and falls again (line 512, inside vertical blanking).
;
;  What the outcome means:
;    * red square with white X glides smoothly -> raster wait, LINE op,
;      erase/redraw AND the $884F busy poll all work -> cube uses the same
;      pattern and must work too
;    * screen freezes after a partial draw      -> the $884F busy poll hangs
;      (sticky busy never clears) -> that is then the last bug to fix
; ============================================================================
.import __LOADADDR__
.segment "EXEHDR"
    .word __LOADADDR__

VIC_MODE   = $9000
VIC_PAGE   = $900F
VIC2_CTRL1 = $D011          ; C64-style read-back: bit 7 = raster line bit 8

; zero page
curlo = $10                 ; current object x (16-bit)
curhi = $11
oldlo = $12                 ; previously drawn x
oldhi = $13
pxlo  = $14                 ; staging x for the coord helpers
pxhi  = $15

OBJ_Y  = 180                ; object row (fits in one byte, y+39 = 219)
OBJ_W  = 39                 ; object is 40x40
STEP   = 4                  ; pixels per animation step

.segment "CODE"

start:
    sei
    cld
    ldx #$ff
    txs

    lda #$20
    sta VIC_MODE            ; 640x400 hi-res
    lda #$00
    sta VIC_PAGE            ; page 0

    ; ---- clear the whole screen black (FILL + busy wait) ----
    lda #$00
    sta $8840
    sta $8841
    sta $8842
    sta $8843
    lda #<639
    sta $8844
    lda #>639
    sta $8845
    lda #<399
    sta $8846
    lda #>399
    sta $8847
    lda #$00
    sta $8848               ; colour black
    sta $8849               ; OP = FILL
    sta $884A               ; page 0
    sta $884F               ; trigger
    jsr busy_wait           ; full-screen fill takes ~3 frames

    ; ---- static marker: green square (10,10)-(60,40) ----
    lda #10
    sta $8840
    sta $8842
    lda #0
    sta $8841
    sta $8843
    lda #60
    sta $8844
    lda #0
    sta $8845
    lda #40
    sta $8846
    lda #0
    sta $8847
    lda #$1C                ; green (RGB332)
    sta $8848
    lda #$00
    sta $8849               ; FILL
    sta $884A
    sta $884F
    jsr busy_wait

    ; ---- init positions ----
    lda #40
    sta curlo
    sta oldlo
    lda #0
    sta curhi
    sta oldhi

; ---------------------------------------------------------------------------
;  Animation loop: ONE vblank wait per step, then erase + draw + X back-to-back
;  with busy polling. Everything lands in the blanking/top margin (~7 ms before
;  the raster reaches row 180), so the motion is flicker-free.
; ---------------------------------------------------------------------------
loop:
    ldx #1
    jsr wait_frames         ; sync to vertical blanking (raster line 512)

    ; erase old object (black FILL over its rectangle)
    lda oldlo
    sta pxlo
    lda oldhi
    sta pxhi
    jsr set_rect_coords
    lda #$00
    jsr fill_go
    jsr busy_wait

    ; advance x, wrap 560 -> 40
    clc
    lda curlo
    adc #STEP
    sta curlo
    lda curhi
    adc #0
    sta curhi
    cmp #2                  ; x >= 560 ($230)?
    bcc @nowrap
    bne @wrap
    lda curlo
    cmp #$30
    bcc @nowrap
@wrap:
    lda #40
    sta curlo
    lda #0
    sta curhi
@nowrap:

    ; draw red square at new x
    lda curlo
    sta pxlo
    lda curhi
    sta pxhi
    jsr set_rect_coords
    lda #$E0                ; red
    jsr fill_go
    jsr busy_wait

    ; white X: diagonal 1 = the rect corners (same coords, LINE op)
    jsr set_rect_coords
    lda #$FF
    jsr line_go
    jsr busy_wait

    ; diagonal 2 = top-right to bottom-left
    jsr set_x2_coords
    lda #$FF
    jsr line_go
    jsr busy_wait

    ; remember what is on screen
    lda curlo
    sta oldlo
    lda curhi
    sta oldhi
    jmp loop

; ---------------------------------------------------------------------------
;  helpers
; ---------------------------------------------------------------------------

; (px,OBJ_Y)-(px+39,OBJ_Y+39) into the blit coordinate registers
set_rect_coords:
    lda pxlo
    sta $8840
    lda pxhi
    sta $8841
    lda #OBJ_Y
    sta $8842
    lda #0
    sta $8843
    clc
    lda pxlo
    adc #OBJ_W
    sta $8844
    lda pxhi
    adc #0
    sta $8845
    lda #OBJ_Y+OBJ_W
    sta $8846
    lda #0
    sta $8847
    rts

; (px+39,OBJ_Y)-(px,OBJ_Y+39): the other diagonal
set_x2_coords:
    clc
    lda pxlo
    adc #OBJ_W
    sta $8840
    lda pxhi
    adc #0
    sta $8841
    lda #OBJ_Y
    sta $8842
    lda #0
    sta $8843
    lda pxlo
    sta $8844
    lda pxhi
    sta $8845
    lda #OBJ_Y+OBJ_W
    sta $8846
    lda #0
    sta $8847
    rts

fill_go:                    ; A = colour
    sta $8848
    lda #$00
    sta $8849               ; OP = FILL
    lda #$00
    sta $884A               ; page 0
    sta $884F               ; trigger
    rts

line_go:                    ; A = colour
    sta $8848
    lda #$03
    sta $8849               ; OP = LINE
    lda #$00
    sta $884A
    sta $884F
    rts

busy_wait:                  ; poll $884F bit 7 (sticky busy) until the op is done
    lda $884F
    bmi busy_wait
    rts

; X = number of frames. One frame = raster bit 8 ($D011 bit 7) goes high at
; line 256 and low again at line 512 -- that falling edge is once per 525-line
; frame and sits inside the vertical blanking (visible lines end at 479).
wait_frames:
@f:
@hi:
    lda VIC2_CTRL1
    bpl @hi                 ; wait for raster >= 256 (bit 8 set)
@lo:
    lda VIC2_CTRL1
    bmi @lo                 ; wait for the wrap past line 511 -> in vblank
    dex
    bne @f
    rts
