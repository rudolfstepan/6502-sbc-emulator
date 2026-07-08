; ============================================================================
;  6502 SBC FPGA - Real-time 3D rotating wireframe cube (640x400 RGB332)
;
;  Runs as a PRG under fpga.ini.  Load/entry address is $1000.
;
;  The 6502 computes the whole 3D pipeline live every frame and hands the line
;  drawing to the hardware 2D blitter ($8840-$884F), so it never plots pixels
;  over the (slow, DDR3-backed) framebuffer bus itself:
;
;    1. 8 model vertices at (+/-R, +/-R, +/-R)          -> vx/vy/vz tables
;    2. rotation about the Y axis, then the X axis       -> sin/cos table + 8x8
;                                                            signed multiply
;    3. perspective projection  x' = x*FOCAL/(z+DIST)     -> signed 16/16 divide
;    4. double buffering via the hardware page flip       -> $900F, banks 0-31
;                                                            (page 0) / 32-63
;                                                            (page 1)
;    5. each edge is one blitter LINE command; the CPU just writes the two
;       endpoints + colour + page and polls BUSY.  The startup clear is two
;       blitter FILL commands.
;
;  The cube is drawn into the *hidden* framebuffer page, then $900F is flipped
;  during vertical blank, so the visible image is always a finished frame
;  (flicker-free).  To stay fast, each page only erases the twelve edges it drew
;  two frames ago (twelve black LINE commands) instead of clearing the page.
;
;  Fixed-point conventions
;  -----------------------
;    * sin/cos are stored as round(sin*64) in signed bytes (-64..+64).
;    * model/rotated coordinates are signed bytes; a corner's magnitude is
;      R*sqrt(3) = 104 < 127, so everything stays inside signed 8-bit.
;    * a rotation term is  coord*trig  (signed 8x8 -> 16), summed, then >>6.
;    * projection divides a signed 16-bit numerator by the positive depth.
;  These exact integer ops were cross-checked against the C/Python reference so
;  the values below are guaranteed on-range.
; ============================================================================

.import __LOADADDR__

.segment "EXEHDR"
    .word __LOADADDR__

; ---- VIC registers -------------------------------------------------------
VIC_MODE = $9000            ; graphics mode
VIC_ISR  = $9007            ; interrupt status; bit1 = new frame
VIC_PAGE = $900F            ; visible framebuffer page (0/1)

MODE_HIRES_RGB332 = $20     ; 640x400, 1 byte/pixel
IRQ_FRAME         = $02     ; ISR bit: raster wrapped -> new frame

; ---- hardware 2D blitter ($8840-$884F) ----------------------------------
; Byte index into the active 640x400 8bpp frame; X is 10-bit, Y is 9-bit.
BLIT_X0LO = $8840
BLIT_X0HI = $8841           ; x0[9:8]
BLIT_Y0LO = $8842
BLIT_Y0HI = $8843           ; y0[8]
BLIT_X1LO = $8844
BLIT_X1HI = $8845
BLIT_Y1LO = $8846
BLIT_Y1HI = $8847
BLIT_COL  = $8848           ; RGB332 colour byte
BLIT_OP   = $8849           ; 0 = FILL rect, 3 = LINE
BLIT_PG   = $884A           ; target framebuffer page (bit 0)
BLIT_TRIG = $884F           ; write = start; read bit7 = BUSY

OP_FILL = 0
OP_LINE = 3

; ---- geometry / projection constants ------------------------------------
R          = 60             ; cube half-size (corner magnitude = R*sqrt3 = 104)
FOCAL      = 110            ; focal length (fits a positive signed byte)
VIEW_DIST  = 210            ; camera distance added to z (keeps depth positive)
CENTER_X   = 320            ; screen centre (640x400)
CENTER_Y   = 200
; screen scale is x3, applied as (q<<1)+q below.

; ---- read/write scratch in RAM ($0000-$5FFF is real board RAM) -----------
; Each "point set" is 32 bytes: [x_lo*8][x_hi*8][y_lo*8][y_hi*8]
NEWPTS = $4000              ; freshly projected vertices for this frame
SAVE0  = $4020             ; what is currently drawn on page 0
SAVE1  = $4040             ; what is currently drawn on page 1

; ---- zero page -----------------------------------------------------------
m_a      = $10              ; signed 8x8 multiply inputs / result
m_b      = $11
prod_lo  = $12
prod_hi  = $13
msign    = $14
dvnd_lo  = $15             ; unsigned 16/16 divide: dividend -> quotient
dvnd_hi  = $16
dvsr_lo  = $17
dvsr_hi  = $18
rem_lo   = $19
rem_hi   = $1A
qsign    = $1B
accl     = $1C             ; signed 16-bit rotation accumulator
acch     = $1D
rx       = $1E             ; rotated coordinates (signed bytes)
ry       = $1F
rz       = $20
cA       = $21             ; per-frame trig
sA       = $22
cB       = $23
sB       = $24
denom_lo = $25             ; z + VIEW_DIST (positive 16-bit)
denom_hi = $26
vidx     = $27             ; current vertex index
PSET     = $28             ; pointer to active point set (2 bytes: $28/$29)
scrxlo   = $2A             ; projected screen coordinate of current vertex
scrxhi   = $2B
scrylo   = $2C
scryhi   = $2D
COLOR    = $2E             ; line/fill colour for the current pass
tmp      = $2F
tmp16lo  = $30
tmp16hi  = $31
angA     = $32             ; rotation angle about Y
angB     = $33             ; rotation angle about X
backpg   = $34
frontpg  = $35
blit_pg  = $36             ; blitter target page for this frame
edgei    = $37
p0       = $38
p1       = $39
svalid0  = $3A             ; SAVE0/SAVE1 hold a drawn cube yet?
svalid1  = $3B

.segment "CODE"

; ---------------------------------------------------------------------------
;  Entry
; ---------------------------------------------------------------------------
start:
    sei
    cld
    ldx #$ff
    txs

    lda #MODE_HIRES_RGB332
    sta VIC_MODE

    lda #0
    sta angA
    sta angB
    sta frontpg
    sta svalid0
    sta svalid1
    sta VIC_PAGE                ; show page 0 (blank) first

    jsr clear_pages             ; blitter-fill both pages to black

; ---------------------------------------------------------------------------
;  Main loop: transform -> pick hidden page -> erase old -> draw new -> flip
; ---------------------------------------------------------------------------
main_loop:
    ; --- trig for this frame: sin = sintab[a], cos = sintab[a+64] ---
    ldx angA
    lda sintab,x
    sta sA
    txa
    clc
    adc #64
    tax
    lda sintab,x
    sta cA

    ldx angB
    lda sintab,x
    sta sB
    txa
    clc
    adc #64
    tax
    lda sintab,x
    sta cB

    ; --- project all 8 vertices into NEWPTS ---
    ldx #0
@vloop:
    stx vidx
    jsr transform_vertex        ; -> scrxlo/hi, scrylo/hi
    ldx vidx
    lda scrxlo
    sta NEWPTS+0,x
    lda scrxhi
    sta NEWPTS+8,x
    lda scrylo
    sta NEWPTS+16,x
    lda scryhi
    sta NEWPTS+24,x
    inx
    cpx #8
    bne @vloop

    ; --- back page = the one not currently visible; blitter targets it ---
    lda frontpg
    eor #$01
    sta backpg
    sta blit_pg

    ; --- erase what this page drew two frames ago (if any) ---
    lda backpg
    bne @erase_p1
    lda svalid0
    beq @draw_new
    lda #<SAVE0
    sta PSET
    lda #>SAVE0
    sta PSET+1
    lda #$00                    ; background colour = black
    sta COLOR
    jsr draw_edges
    jmp @draw_new
@erase_p1:
    lda svalid1
    beq @draw_new
    lda #<SAVE1
    sta PSET
    lda #>SAVE1
    sta PSET+1
    lda #$00
    sta COLOR
    jsr draw_edges

    ; --- draw the new cube in white ---
@draw_new:
    lda #<NEWPTS
    sta PSET
    lda #>NEWPTS
    sta PSET+1
    lda #$ff                    ; white (RGB332 = all ones)
    sta COLOR
    jsr draw_edges

    ; --- remember what we just drew on this page ---
    lda backpg
    bne @save1
    ldx #0
@cp0:
    lda NEWPTS,x
    sta SAVE0,x
    inx
    cpx #32
    bne @cp0
    lda #1
    sta svalid0
    jmp @flip
@save1:
    ldx #0
@cp1:
    lda NEWPTS,x
    sta SAVE1,x
    inx
    cpx #32
    bne @cp1
    lda #1
    sta svalid1

    ; --- wait for vertical blank, then reveal the finished page ---
@flip:
    jsr wait_frame
    lda backpg
    sta VIC_PAGE
    sta frontpg

    ; --- advance the two rotation angles ---
    lda angA
    clc
    adc #2
    sta angA
    lda angB
    clc
    adc #1
    sta angB
    jmp main_loop

; ---------------------------------------------------------------------------
;  wait_frame - poll the VIC frame flag and acknowledge it
; ---------------------------------------------------------------------------
wait_frame:
    lda #IRQ_FRAME              ; drop any frame flag already pending, so we
    sta VIC_ISR                 ; block until the *next* real vblank edge
@poll:
    lda VIC_ISR
    and #IRQ_FRAME
    beq @poll
    lda #IRQ_FRAME
    sta VIC_ISR                 ; acknowledge (write-1-to-clear)
    rts

; ---------------------------------------------------------------------------
;  transform_vertex - vertex #vidx -> rotated, projected screen coords
;
;   rotate about Y:  x1 = (x*cosA + z*sinA) >> 6
;                    z1 = (z*cosA - x*sinA) >> 6 ,  y1 = y
;   rotate about X:  y2 = (y1*cosB - z1*sinB) >> 6
;                    z2 = (z1*cosB + y1*sinB) >> 6 ,  x2 = x1
;   project:         sx = CENTER_X + 3*(x2*FOCAL / (z2+VIEW_DIST))
;                    sy = CENTER_Y - 3*(y2*FOCAL / (z2+VIEW_DIST))
; ---------------------------------------------------------------------------
transform_vertex:
    ; x1 = (x*cA + z*sA) >> 6
    ldx vidx
    lda vx_tab,x
    sta m_a
    lda cA
    sta m_b
    jsr smul8
    lda prod_lo
    sta accl
    lda prod_hi
    sta acch
    ldx vidx
    lda vz_tab,x
    sta m_a
    lda sA
    sta m_b
    jsr smul8
    clc
    lda accl
    adc prod_lo
    sta accl
    lda acch
    adc prod_hi
    sta acch
    jsr asr6_acc
    lda accl
    sta rx

    ; z1 = (z*cA - x*sA) >> 6
    ldx vidx
    lda vz_tab,x
    sta m_a
    lda cA
    sta m_b
    jsr smul8
    lda prod_lo
    sta accl
    lda prod_hi
    sta acch
    ldx vidx
    lda vx_tab,x
    sta m_a
    lda sA
    sta m_b
    jsr smul8
    sec
    lda accl
    sbc prod_lo
    sta accl
    lda acch
    sbc prod_hi
    sta acch
    jsr asr6_acc
    lda accl
    sta rz

    ; y1 = y (unchanged by the Y rotation)
    ldx vidx
    lda vy_tab,x
    sta ry

    ; y2 = (y1*cB - z1*sB) >> 6
    lda ry
    sta m_a
    lda cB
    sta m_b
    jsr smul8
    lda prod_lo
    sta accl
    lda prod_hi
    sta acch
    lda rz
    sta m_a
    lda sB
    sta m_b
    jsr smul8
    sec
    lda accl
    sbc prod_lo
    sta accl
    lda acch
    sbc prod_hi
    sta acch
    jsr asr6_acc
    lda accl
    sta tmp                     ; stash y2 (ry/rz still needed for z2)

    ; z2 = (z1*cB + y1*sB) >> 6
    lda rz
    sta m_a
    lda cB
    sta m_b
    jsr smul8
    lda prod_lo
    sta accl
    lda prod_hi
    sta acch
    lda ry
    sta m_a
    lda sB
    sta m_b
    jsr smul8
    clc
    lda accl
    adc prod_lo
    sta accl
    lda acch
    adc prod_hi
    sta acch
    jsr asr6_acc
    lda accl
    sta rz                      ; z2
    lda tmp
    sta ry                      ; y2  (x2 is still in rx)

    ; denom = z2 + VIEW_DIST  (sign-extend z2 into 16-bit, always > 0)
    lda rz
    sta denom_lo
    ldx rz
    bmi @zneg
    lda #0
    jmp @zext
@zneg:
    lda #$ff
@zext:
    sta denom_hi
    clc
    lda denom_lo
    adc #<VIEW_DIST
    sta denom_lo
    lda denom_hi
    adc #>VIEW_DIST
    sta denom_hi

    ; sx = CENTER_X + 3 * (x2*FOCAL / denom)
    lda rx
    sta m_a
    lda #FOCAL
    sta m_b
    jsr smul8                   ; prod = x2*FOCAL (signed 16)
    jsr div_signed              ; dvnd = quotient (signed 16)
    jsr times3                  ; tmp16 = 3*quotient
    clc
    lda tmp16lo
    adc #<CENTER_X
    sta scrxlo
    lda tmp16hi
    adc #>CENTER_X
    sta scrxhi

    ; sy = CENTER_Y - 3 * (y2*FOCAL / denom)
    lda ry
    sta m_a
    lda #FOCAL
    sta m_b
    jsr smul8
    jsr div_signed
    jsr times3
    sec
    lda #<CENTER_Y
    sbc tmp16lo
    sta scrylo
    lda #>CENTER_Y
    sbc tmp16hi
    sta scryhi
    rts

; tmp16 = 3 * dvnd   (signed 16-bit: (q<<1)+q)
times3:
    lda dvnd_lo
    sta tmp16lo
    lda dvnd_hi
    sta tmp16hi
    asl tmp16lo
    rol tmp16hi
    clc
    lda tmp16lo
    adc dvnd_lo
    sta tmp16lo
    lda tmp16hi
    adc dvnd_hi
    sta tmp16hi
    rts

; ---------------------------------------------------------------------------
;  smul8 - signed(m_a) * signed(m_b) -> signed 16-bit prod_lo/prod_hi
;  (take magnitudes, unsigned 8x8 shift-add, then re-apply the sign)
; ---------------------------------------------------------------------------
smul8:
    lda #0
    sta msign
    lda m_a
    bpl @a_ok
    sec
    lda #0
    sbc m_a
    sta m_a
    lda #1
    sta msign
@a_ok:
    lda m_b
    bpl @b_ok
    sec
    lda #0
    sbc m_b
    sta m_b
    lda msign
    eor #1
    sta msign
@b_ok:
    lda #0
    sta prod_hi
    sta prod_lo
    ldx #8
@mul:
    lsr m_a
    bcc @noadd
    clc
    lda prod_hi
    adc m_b
    sta prod_hi
@noadd:
    ror prod_hi
    ror prod_lo
    dex
    bne @mul
    lda msign
    beq @done
    sec                         ; negate the 16-bit product
    lda #0
    sbc prod_lo
    sta prod_lo
    lda #0
    sbc prod_hi
    sta prod_hi
@done:
    rts

; ---------------------------------------------------------------------------
;  asr6_acc - arithmetic shift accl/acch right by 6 (signed /64)
; ---------------------------------------------------------------------------
asr6_acc:
    ldx #6
@l:
    lda acch
    cmp #$80                    ; carry = sign bit of the 16-bit value
    ror acch
    ror accl
    dex
    bne @l
    rts

; ---------------------------------------------------------------------------
;  div_signed - signed(prod) / positive(denom) -> signed quotient in dvnd
; ---------------------------------------------------------------------------
div_signed:
    lda prod_hi
    bmi @neg
    lda prod_lo
    sta dvnd_lo
    lda prod_hi
    sta dvnd_hi
    lda #0
    sta qsign
    jmp @go
@neg:
    sec
    lda #0
    sbc prod_lo
    sta dvnd_lo
    lda #0
    sbc prod_hi
    sta dvnd_hi
    lda #1
    sta qsign
@go:
    lda denom_lo
    sta dvsr_lo
    lda denom_hi
    sta dvsr_hi
    jsr divide16
    lda qsign
    beq @done
    sec
    lda #0
    sbc dvnd_lo
    sta dvnd_lo
    lda #0
    sbc dvnd_hi
    sta dvnd_hi
@done:
    rts

; ---------------------------------------------------------------------------
;  divide16 - unsigned dvnd / dvsr -> quotient in dvnd, remainder in rem
; ---------------------------------------------------------------------------
divide16:
    lda #0
    sta rem_lo
    sta rem_hi
    ldx #16
@loop:
    asl dvnd_lo
    rol dvnd_hi
    rol rem_lo
    rol rem_hi
    sec
    lda rem_lo
    sbc dvsr_lo
    tay
    lda rem_hi
    sbc dvsr_hi
    bcc @skip                   ; rem < divisor -> quotient bit 0
    sta rem_hi
    sty rem_lo
    inc dvnd_lo                 ; quotient bit 1 (low bit is free after asl)
@skip:
    dex
    bne @loop
    rts

; ---------------------------------------------------------------------------
;  draw_edges - draw all 12 edges of point set PSET in COLOR on page blit_pg,
;  one hardware blitter LINE command per edge.
; ---------------------------------------------------------------------------
draw_edges:
    ldx #0
@loop:
    stx edgei
    lda edge_from,x
    sta p0
    ldx edgei
    lda edge_to,x
    sta p1

    ; endpoint 0 -> blitter (x0,y0).  Point set: xlo@+0 xhi@+8 ylo@+16 yhi@+24
    ldy p0
    lda (PSET),y
    sta BLIT_X0LO
    lda p0
    clc
    adc #8
    tay
    lda (PSET),y
    sta BLIT_X0HI
    lda p0
    clc
    adc #16
    tay
    lda (PSET),y
    sta BLIT_Y0LO
    lda p0
    clc
    adc #24
    tay
    lda (PSET),y
    sta BLIT_Y0HI

    ; endpoint 1 -> blitter (x1,y1)
    ldy p1
    lda (PSET),y
    sta BLIT_X1LO
    lda p1
    clc
    adc #8
    tay
    lda (PSET),y
    sta BLIT_X1HI
    lda p1
    clc
    adc #16
    tay
    lda (PSET),y
    sta BLIT_Y1LO
    lda p1
    clc
    adc #24
    tay
    lda (PSET),y
    sta BLIT_Y1HI

    lda COLOR
    sta BLIT_COL
    lda #OP_LINE
    sta BLIT_OP
    lda blit_pg
    sta BLIT_PG
    sta BLIT_TRIG               ; any write triggers the op
@busy:
    lda BLIT_TRIG              ; bit7 = BUSY
    bmi @busy

    ldx edgei
    inx
    cpx #12
    bne @loop
    rts

; ---------------------------------------------------------------------------
;  clear_pages - blitter-FILL both framebuffer pages to black
; ---------------------------------------------------------------------------
clear_pages:
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
    lda #$00                    ; page 0
    sta BLIT_PG
    sta BLIT_TRIG
    jsr blit_wait
    lda #$01                    ; page 1
    sta BLIT_PG
    sta BLIT_TRIG
    jsr blit_wait
    rts

blit_wait:
    lda BLIT_TRIG
    bmi blit_wait
    rts

; ===========================================================================
;  Data
; ===========================================================================
.segment "RODATA"

; the 12 cube edges as (from,to) vertex indices
edge_from:
    .byte 0,1,2,3, 4,5,6,7, 0,1,2,3
edge_to:
    .byte 1,2,3,0, 5,6,7,4, 4,5,6,7

; 8 model vertices, signed bytes: +/-60 = $3C / $C4
vx_tab:
    .byte $C4,$3C,$3C,$C4,$C4,$3C,$3C,$C4
vy_tab:
    .byte $C4,$C4,$3C,$3C,$C4,$C4,$3C,$3C
vz_tab:
    .byte $C4,$C4,$C4,$C4,$3C,$3C,$3C,$3C

; sintab[i] = round(sin(2*pi*i/256) * 64), signed byte.  cos = sintab[i+64].
sintab:
    .byte $00,$02,$03,$05,$06,$08,$09,$0B,$0C,$0E,$10,$11,$13,$14,$16,$17
    .byte $18,$1A,$1B,$1D,$1E,$20,$21,$22,$24,$25,$26,$27,$29,$2A,$2B,$2C
    .byte $2D,$2E,$2F,$30,$31,$32,$33,$34,$35,$36,$37,$38,$38,$39,$3A,$3B
    .byte $3B,$3C,$3C,$3D,$3D,$3E,$3E,$3E,$3F,$3F,$3F,$40,$40,$40,$40,$40
    .byte $40,$40,$40,$40,$40,$40,$3F,$3F,$3F,$3E,$3E,$3E,$3D,$3D,$3C,$3C
    .byte $3B,$3B,$3A,$39,$38,$38,$37,$36,$35,$34,$33,$32,$31,$30,$2F,$2E
    .byte $2D,$2C,$2B,$2A,$29,$27,$26,$25,$24,$22,$21,$20,$1E,$1D,$1B,$1A
    .byte $18,$17,$16,$14,$13,$11,$10,$0E,$0C,$0B,$09,$08,$06,$05,$03,$02
    .byte $00,$FE,$FD,$FB,$FA,$F8,$F7,$F5,$F4,$F2,$F0,$EF,$ED,$EC,$EA,$E9
    .byte $E8,$E6,$E5,$E3,$E2,$E0,$DF,$DE,$DC,$DB,$DA,$D9,$D7,$D6,$D5,$D4
    .byte $D3,$D2,$D1,$D0,$CF,$CE,$CD,$CC,$CB,$CA,$C9,$C8,$C8,$C7,$C6,$C5
    .byte $C5,$C4,$C4,$C3,$C3,$C2,$C2,$C2,$C1,$C1,$C1,$C0,$C0,$C0,$C0,$C0
    .byte $C0,$C0,$C0,$C0,$C0,$C0,$C1,$C1,$C1,$C2,$C2,$C2,$C3,$C3,$C4,$C4
    .byte $C5,$C5,$C6,$C7,$C8,$C8,$C9,$CA,$CB,$CC,$CD,$CE,$CF,$D0,$D1,$D2
    .byte $D3,$D4,$D5,$D6,$D7,$D9,$DA,$DB,$DC,$DE,$DF,$E0,$E2,$E3,$E5,$E6
    .byte $E8,$E9,$EA,$EC,$ED,$EF,$F0,$F2,$F4,$F5,$F7,$F8,$FA,$FB,$FD,$FE
