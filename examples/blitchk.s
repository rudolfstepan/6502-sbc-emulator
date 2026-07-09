; ============================================================================
;  Blitter write/readback diagnostic: WHERE do pixels survive an erase, WHY?
;
;  UART-loadable PRG ($1000, fpga.ini). Method:
;    1. Stress like the animations do: 8 passes of full-screen blitter FILL
;       $FF then FILL $00 -- each pass is a SINGLE fill (deliberately no
;       double-write; we are measuring the raw miss rate of one erase pass).
;    2. CPU reads back all 256000 framebuffer bytes through the banked $6000
;       window ($9006 = bank 0..31) and classifies every byte != $00:
;         value == $FF  -> the final black write was DROPPED entirely
;         other value   -> the write (or the readback) got BIT-CORRUPTED
;    3. Draws the result as graphics (no text needed):
;         y  2..8   white bar  = total errors   (1 px per error, cap 620)
;         y 12..18  yellow bar = dropped writes
;         y 22..28  cyan bar   = corrupted bytes
;         y 40..52  8 boxes    = OR of wrong-value bits (bit7 left .. bit0
;                                right); grey = bit clean, white = bit flipped
;         y 380 up  16 columns = errors per byte lane inside the 16-byte DDR3
;                                burst (lane 0 left); peaked = byte-lane/DM
;                                problem, flat = whole bursts lost
;
;  Reading the outcome:
;    * long white+yellow, cyan ~0, flat lanes -> whole bursts dropped
;    * cyan > 0, specific bit boxes lit       -> DDR3 data-eye/bit-lane margin
;    * everything zero                        -> DDR3 CONTENT is fine; leftover
;      pixels must then come from the display READ path, not the writes
; ============================================================================

.import __LOADADDR__

.segment "EXEHDR"
    .word __LOADADDR__

VIC_MODE  = $9000
VIC_BANK  = $9006
VIC_PAGE  = $900F

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

PASSES = 8

; zero page
PTR    = $10                ; readback pointer (2 bytes)
bankno = $12
plimit = $13                ; end page of the current bank ($80, last bank $68)
dropl  = $14                ; bytes still reading $FF (write dropped)
droph  = $15
corl   = $16                ; bytes reading anything else (corrupted)
corh   = $17
cor_or = $18                ; OR of all wrong values seen
t1     = $19
lenl   = $1A                ; bar length scratch
lenh   = $1B
kpass  = $1C
bcol   = $1D                ; bar colour
by0    = $1E                ; bar y0/y1 (always < 256)
by1    = $1F
h8     = $20                ; histogram column height

; lane histogram: 16 x 16-bit counters
L_LO = $4000
L_HI = $4010

.segment "CODE"

start:
    sei
    cld
    ldx #$ff
    txs

    lda #$20
    sta VIC_MODE            ; 640x400 hi-res
    lda #$00
    sta VIC_PAGE

    ; ---- stress: PASSES x (FILL $FF ; FILL $00), single-pass fills ----
    lda #PASSES
    sta kpass
@stress:
    lda #$FF
    jsr fill_screen
    lda #$00
    jsr fill_screen
    dec kpass
    bne @stress

    ; ---- clear tallies ----
    lda #0
    sta dropl
    sta droph
    sta corl
    sta corh
    sta cor_or
    ldx #15
@clr:
    sta L_LO,x
    sta L_HI,x
    dex
    bpl @clr

    ; ---- readback: banks 0..31 through the $6000 window ----
    lda #0
    sta bankno
@bank:
    lda bankno
    sta VIC_BANK
    lda #$80                ; full bank: pages $60..$7F
    sta plimit
    lda bankno
    cmp #31
    bne @limok
    lda #$68                ; last bank holds only 2048 frame bytes
    sta plimit
@limok:
    lda #$60
    sta PTR+1
    lda #$00
    sta PTR
@page:
    ldy #0
@byte:
    lda (PTR),y
    beq @next               ; expected black: OK
    cmp #$FF
    bne @corrupt
    inc dropl               ; whole write dropped ($FF survived)
    bne @lane
    inc droph
    jmp @lane
@corrupt:
    ora cor_or              ; collect which bits went wrong
    sta cor_or
    inc corl
    bne @lane
    inc corh
@lane:
    tya
    and #15                 ; byte lane within the 16-byte burst
    tax
    inc L_LO,x
    bne @next
    inc L_HI,x
@next:
    iny
    bne @byte
    inc PTR+1
    lda PTR+1
    cmp plimit
    bne @page
    inc bankno
    lda bankno
    cmp #32
    bne @bank

    ; ---- draw the report ----
    ; total = drop + cor (white, rows 2..8)
    clc
    lda dropl
    adc corl
    sta lenl
    lda droph
    adc corh
    sta lenh
    lda #$FF
    sta bcol
    lda #2
    sta by0
    lda #8
    sta by1
    jsr draw_bar

    lda dropl               ; dropped writes (yellow, rows 12..18)
    sta lenl
    lda droph
    sta lenh
    lda #$FC
    sta bcol
    lda #12
    sta by0
    lda #18
    sta by1
    jsr draw_bar

    lda corl                ; corrupted bytes (cyan, rows 22..28)
    sta lenl
    lda corh
    sta lenh
    lda #$1F
    sta bcol
    lda #22
    sta by0
    lda #28
    sta by1
    jsr draw_bar

    ; ---- 8 bit boxes: grey background, white when the bit ever flipped ----
    ldx #7                  ; X = bit number, box 0 (left) = bit 7
@boxes:
    txa
    eor #7                  ; box index = 7 - bit
    tay
    lda box_x_lo,y
    sta BLIT_X0LO
    clc
    adc #10
    sta BLIT_X1LO
    lda box_x_hi,y
    sta BLIT_X0HI
    adc #0
    sta BLIT_X1HI
    lda #40
    sta BLIT_Y0LO
    lda #52
    sta BLIT_Y1LO
    lda #0
    sta BLIT_Y0HI
    sta BLIT_Y1HI
    lda #$24                ; dark grey
    sta t1
    txa
    tay
    lda cor_or
@shift:
    dey
    bmi @tested
    lsr a
    jmp @shift
@tested:
    and #1                  ; bit X of cor_or
    beq @grey
    lda #$FF
    sta t1
@grey:
    lda t1
    jsr fill2
    dex
    bpl @boxes

    ; ---- lane histogram: 16 columns, height = min(count,200), base y=380 ----
    ldx #0
@lanes:
    lda L_HI,x
    beq @small
    lda #200
    bne @have
@small:
    lda L_LO,x
    cmp #200
    bcc @have
    lda #200
@have:
    sta h8
    cmp #0                  ; (sta does not set flags)
    beq @skip               ; empty lane: nothing to draw
    lda lane_x_lo,x
    sta BLIT_X0LO
    clc
    adc #12
    sta BLIT_X1LO
    lda lane_x_hi,x
    sta BLIT_X0HI
    adc #0
    sta BLIT_X1HI
    sec                     ; y0 = 380 - height
    lda #$7C                ; 380 = $017C
    sbc h8
    sta BLIT_Y0LO
    lda #$01
    sbc #0
    sta BLIT_Y0HI
    lda #$7C
    sta BLIT_Y1LO
    lda #$01
    sta BLIT_Y1HI
    lda #$FF
    jsr fill2
@skip:
    inx
    cpx #16
    bne @lanes

hang:
    jmp hang

; ---------------------------------------------------------------------------
;  draw_bar - horizontal bar rows by0..by1, length lenl/lenh (cap 620), bcol
; ---------------------------------------------------------------------------
draw_bar:
    lda lenl                ; nothing to draw?
    ora lenh
    bne @cap
    rts
@cap:
    lda lenh                ; cap at 620 = $026C
    cmp #3
    bcs @clip
    cmp #2
    bne @capok
    lda lenl
    cmp #$6D
    bcc @capok
@clip:
    lda #$6C
    sta lenl
    lda #$02
    sta lenh
@capok:
    lda #2                  ; x0 = 2
    sta BLIT_X0LO
    lda #0
    sta BLIT_X0HI
    clc                     ; x1 = 2 + len
    lda lenl
    adc #2
    sta BLIT_X1LO
    lda lenh
    adc #0
    sta BLIT_X1HI
    lda by0
    sta BLIT_Y0LO
    lda by1
    sta BLIT_Y1LO
    lda #0
    sta BLIT_Y0HI
    sta BLIT_Y1HI
    lda bcol
    ; fall through: draw the report robustly (double fill)
fill2:
    jsr fill_go
    sta BLIT_TRIG           ; identical registers: fill a second time
    jmp blit_wait

; ---------------------------------------------------------------------------
;  fill_screen - single-pass full-screen FILL in colour A (the test subject!)
; ---------------------------------------------------------------------------
fill_screen:
    pha
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
    pla
fill_go:                    ; A = colour; coordinate registers already set
    sta BLIT_COL
    lda #$00
    sta BLIT_OP             ; FILL
    sta BLIT_PG
    sta BLIT_TRIG
blit_wait:
    lda BLIT_TRIG           ; bit 7 = sticky busy
    bmi blit_wait
    rts

.segment "RODATA"

; x positions: 16 lane columns (64 + 24k) and 8 bit boxes (500 + 14k)
lane_x_lo:
    .repeat 16, I
    .byte <(64 + I*24)
    .endrepeat
lane_x_hi:
    .repeat 16, I
    .byte >(64 + I*24)
    .endrepeat
box_x_lo:
    .repeat 8, I
    .byte <(500 + I*14)
    .endrepeat
box_x_hi:
    .repeat 8, I
    .byte >(500 + I*14)
    .endrepeat
