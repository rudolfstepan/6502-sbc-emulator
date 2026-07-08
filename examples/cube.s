; ============================================================================
;  6502 SBC FPGA - Real-time 3D rotating wireframe cube (640x400 RGB332)
;
;  Runs as a PRG under fpga.ini.  Load/entry address is $1000.
;
;  Unlike a table-playback demo, this program computes the whole 3D pipeline
;  live on the 6502 every frame:
;
;    1. 8 model vertices at (+/-R, +/-R, +/-R)          -> vx/vy/vz tables
;    2. rotation about the Y axis, then the X axis       -> sin/cos table + 8x8
;                                                            signed multiply
;    3. perspective projection  x' = x*FOCAL/(z+DIST)     -> signed 16/16 divide
;    4. double buffering via the hardware page flip       -> $900F, banks 0-31
;                                                            (page 0) / 32-63
;                                                            (page 1)
;    5. edges drawn with an exact integer Bresenham line  -> no gaps, no jitter
;
;  The cube is drawn into the *hidden* framebuffer page, then $900F is flipped
;  during vertical blank, so the visible image is always a finished frame
;  (flicker-free).  To stay fast, each page only erases the twelve edges it drew
;  two frames ago instead of clearing the whole 256 KB page.
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
VIC_BANK = $9006            ; framebuffer bank (0..63, 8 KB each)
VIC_ISR  = $9007            ; interrupt status; bit1 = new frame
VIC_PAGE = $900F            ; visible framebuffer page (0/1)

MODE_HIRES_RGB332 = $20     ; 640x400, 1 byte/pixel
IRQ_FRAME         = $02     ; ISR bit: raster wrapped -> new frame

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
lx0lo    = $2E             ; Bresenham endpoints (16-bit)
lx0hi    = $2F
ly0lo    = $30
ly0hi    = $31
lx1lo    = $32
lx1hi    = $33
ly1lo    = $34
ly1hi    = $35
dxlo     = $36
dxhi     = $37
dylo     = $38
dyhi     = $39
sx_step  = $3A             ; +1 / -1
sy_step  = $3B
errlo    = $3C
errhi    = $3D
e2lo     = $3E
e2hi     = $3F
px_lo    = $40             ; plot_pixel input
px_hi    = $41
py_lo    = $42
py_hi    = $43
ADDRL    = $44             ; plot_pixel linear byte address (24-bit)
ADDRM    = $45
ADDRH    = $46
PTRL     = $47
PTRH     = $48
COLOR    = $49
BANK_BASE= $4A             ; 0 for page 0, 32 for page 1
tmp      = $4B
tmp16lo  = $4C
tmp16hi  = $4D
angA     = $4E             ; rotation angle about Y
angB     = $4F             ; rotation angle about X
backpg   = $50
frontpg  = $51
edgei    = $52
p0       = $53
p1       = $54
svalid0  = $55             ; SAVE0/SAVE1 hold a drawn cube yet?
svalid1  = $56
bank     = $57             ; current framebuffer bank while walking a line
cntlo    = $58             ; remaining pixels on the current line
cnthi    = $59
dx2lo    = $5A             ; 2*|dx| and 2*|dy| (Bresenham increments)
dx2hi    = $5B
dy2lo    = $5C
dy2hi    = $5D

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

    jsr clear_all_pages

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

    ; --- back page = the one not currently visible ---
    lda frontpg
    eor #$01
    sta backpg
    beq @base0                  ; back page 0 -> banks 0..31
    lda #$20                    ; back page 1 -> banks 32..63
    sta BANK_BASE
    jmp @erase
@base0:
    lda #$00
    sta BANK_BASE

    ; --- erase what this page drew two frames ago (if any) ---
@erase:
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
;  draw_edges - draw all 12 edges of the point set PSET in COLOR
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

    ldy p0                      ; endpoint 0: x_lo/x_hi/y_lo/y_hi
    lda (PSET),y
    sta lx0lo
    lda p0
    clc
    adc #8
    tay
    lda (PSET),y
    sta lx0hi
    lda p0
    clc
    adc #16
    tay
    lda (PSET),y
    sta ly0lo
    lda p0
    clc
    adc #24
    tay
    lda (PSET),y
    sta ly0hi

    ldy p1                      ; endpoint 1
    lda (PSET),y
    sta lx1lo
    lda p1
    clc
    adc #8
    tay
    lda (PSET),y
    sta lx1hi
    lda p1
    clc
    adc #16
    tay
    lda (PSET),y
    sta ly1lo
    lda p1
    clc
    adc #24
    tay
    lda (PSET),y
    sta ly1hi

    jsr draw_line
    ldx edgei
    inx
    cpx #12
    bne @loop
    rts

; ---------------------------------------------------------------------------
;  Framebuffer pointer stepping macros (inlined by draw_line).
;  PTR walks the visible 8 KB window $6000-$7FFF; when a step crosses a window
;  edge, wrap PTR and adjust the bank register.  Bank changes are rare (every
;  8 KB for x, ~12 rows for y), so the common case is a single inc/dec.
; ---------------------------------------------------------------------------
.macro STEP_XP                  ; PTR += 1
.local done
    inc PTRL
    bne done
    inc PTRH
    lda PTRH
    cmp #$80
    bne done
    lda #$60
    sta PTRH
    inc bank
    lda bank
    sta VIC_BANK
done:
.endmacro

.macro STEP_XN                  ; PTR -= 1
.local done, skip
    lda PTRL
    bne skip
    dec PTRH
skip:
    dec PTRL
    lda PTRH
    cmp #$60
    bcs done
    lda #$7f
    sta PTRH
    dec bank
    lda bank
    sta VIC_BANK
done:
.endmacro

.macro STEP_YP                  ; PTR += 640
.local done
    clc
    lda PTRL
    adc #$80
    sta PTRL
    lda PTRH
    adc #$02
    sta PTRH
    cmp #$80
    bcc done
    sec
    sbc #$20
    sta PTRH
    inc bank
    lda bank
    sta VIC_BANK
done:
.endmacro

.macro STEP_YN                  ; PTR -= 640
.local done
    sec
    lda PTRL
    sbc #$80
    sta PTRL
    lda PTRH
    sbc #$02
    sta PTRH
    cmp #$60
    bcs done
    clc
    adc #$20
    sta PTRH
    dec bank
    lda bank
    sta VIC_BANK
done:
.endmacro

; ---------------------------------------------------------------------------
;  draw_line - axis-split Bresenham with an incrementally walked framebuffer
;  pointer.  The start address is derived once; thereafter the major axis steps
;  the pointer every pixel and the minor axis steps only when the decision
;  value D turns non-negative - a single sign test per pixel, no per-pixel
;  address computation.  This is the demo's hot loop, so it is kept lean.
;
;  Endpoints are guaranteed on-screen by the projection constants (no clipping).
; ---------------------------------------------------------------------------
draw_line:
    ; |dx| and sx_step
    sec
    lda lx1lo
    sbc lx0lo
    sta dxlo
    lda lx1hi
    sbc lx0hi
    sta dxhi
    bpl @dxpos
    sec
    lda #0
    sbc dxlo
    sta dxlo
    lda #0
    sbc dxhi
    sta dxhi
    lda #$ff
    sta sx_step
    jmp @dyc
@dxpos:
    lda #$01
    sta sx_step
@dyc:
    ; |dy| and sy_step
    sec
    lda ly1lo
    sbc ly0lo
    sta dylo
    lda ly1hi
    sbc ly0hi
    sta dyhi
    bpl @dypos
    sec
    lda #0
    sbc dylo
    sta dylo
    lda #0
    sbc dyhi
    sta dyhi
    lda #$ff
    sta sy_step
    jmp @two
@dypos:
    lda #$01
    sta sy_step
@two:
    lda dxlo                    ; dx2 = 2*|dx|
    asl
    sta dx2lo
    lda dxhi
    rol
    sta dx2hi
    lda dylo                    ; dy2 = 2*|dy|
    asl
    sta dy2lo
    lda dyhi
    rol
    sta dy2hi

    ; start pointer/bank for (lx0,ly0):  linear = ly0*640 + lx0
    ldy ly0lo
    lda ly0hi
    bne @up
    lda row_lo,y
    sta ADDRL
    lda row_mid,y
    sta ADDRM
    lda row_hi,y
    sta ADDRH
    jmp @ax
@up:
    lda row_lo+256,y
    sta ADDRL
    lda row_mid+256,y
    sta ADDRM
    lda row_hi+256,y
    sta ADDRH
@ax:
    clc
    lda ADDRL
    adc lx0lo
    sta ADDRL
    lda ADDRM
    adc lx0hi
    sta ADDRM
    lda ADDRH
    adc #0
    sta ADDRH
    lda ADDRM                   ; bank = (linear >> 13) + BANK_BASE
    lsr
    lsr
    lsr
    lsr
    lsr
    sta tmp
    lda ADDRH
    and #3
    asl
    asl
    asl
    ora tmp
    clc
    adc BANK_BASE
    sta bank
    sta VIC_BANK
    lda ADDRM                   ; PTR = $6000 + (linear & $1FFF)
    and #$1f
    ora #$60
    sta PTRH
    lda ADDRL
    sta PTRL

    ldy #0                      ; Y stays 0 for every (PTR),y store

    lda dxlo                    ; major axis: |dx| >= |dy| ?
    cmp dylo
    lda dxhi
    sbc dyhi
    bcs dl_shallow
    jmp dl_steep

; ---- shallow (X-major): step X every pixel, Y when D >= 0 ----
; (labels here are global, not cheap-local, because the STEP_* macros define
;  their own local labels which would otherwise close the cheap-local scope.)
dl_shallow:
    lda dxlo                    ; cnt = |dx|
    sta cntlo
    lda dxhi
    sta cnthi
    sec                         ; D = dy2 - |dx|
    lda dy2lo
    sbc dxlo
    sta errlo
    lda dy2hi
    sbc dxhi
    sta errhi
dl_shloop:
    lda COLOR                   ; plot
    sta (PTRL),y
    lda cntlo
    ora cnthi
    bne dl_sh1
    rts
dl_sh1:
    lda errhi                   ; D >= 0 ?  -> step minor axis (Y)
    bmi dl_shx
    sec                         ; D -= dx2
    lda errlo
    sbc dx2lo
    sta errlo
    lda errhi
    sbc dx2hi
    sta errhi
    lda sy_step
    bmi dl_shyn
    STEP_YP
    jmp dl_shx
dl_shyn:
    STEP_YN
dl_shx:
    clc                         ; D += dy2
    lda errlo
    adc dy2lo
    sta errlo
    lda errhi
    adc dy2hi
    sta errhi
    lda sx_step                 ; step X (every pixel)
    bmi dl_shxn
    STEP_XP
    jmp dl_shc
dl_shxn:
    STEP_XN
dl_shc:
    lda cntlo
    bne dl_shd
    dec cnthi
dl_shd:
    dec cntlo
    jmp dl_shloop

; ---- steep (Y-major): step Y every pixel, X when D >= 0 ----
dl_steep:
    lda dylo                    ; cnt = |dy|
    sta cntlo
    lda dyhi
    sta cnthi
    sec                         ; D = dx2 - |dy|
    lda dx2lo
    sbc dylo
    sta errlo
    lda dx2hi
    sbc dyhi
    sta errhi
dl_stloop:
    lda COLOR                   ; plot
    sta (PTRL),y
    lda cntlo
    ora cnthi
    bne dl_st1
    rts
dl_st1:
    lda errhi                   ; D >= 0 ?  -> step minor axis (X)
    bmi dl_sty
    sec                         ; D -= dy2
    lda errlo
    sbc dy2lo
    sta errlo
    lda errhi
    sbc dy2hi
    sta errhi
    lda sx_step
    bmi dl_stxn
    STEP_XP
    jmp dl_sty
dl_stxn:
    STEP_XN
dl_sty:
    clc                         ; D += dx2
    lda errlo
    adc dx2lo
    sta errlo
    lda errhi
    adc dx2hi
    sta errhi
    lda sy_step                 ; step Y (every pixel)
    bmi dl_styn
    STEP_YP
    jmp dl_stc
dl_styn:
    STEP_YN
dl_stc:
    lda cntlo
    bne dl_std
    dec cnthi
dl_std:
    dec cntlo
    jmp dl_stloop

; ---------------------------------------------------------------------------
;  clear_all_pages - zero both framebuffer pages (all 64 banks)
; ---------------------------------------------------------------------------
clear_all_pages:
    ldx #0
@bank:
    stx VIC_BANK
    stx tmp                     ; remember current bank
    lda #$60
    sta PTRH
    lda #$00
    sta PTRL
    tay
@page:
    lda #0
@byte:
    sta (PTRL),y
    iny
    bne @byte
    inc PTRH
    lda PTRH
    cmp #$80
    bne @page
    ldx tmp
    inx
    cpx #64
    bne @bank
    rts

; ===========================================================================
;  Data
; ===========================================================================
.segment "RODATA"

; y*640 as a 24-bit value, one entry per screen row (0..399)
row_lo:
    .repeat 400, I
    .byte <(I * 640)
    .endrepeat
row_mid:
    .repeat 400, I
    .byte >((I * 640) & $ffff)
    .endrepeat
row_hi:
    .repeat 400, I
    .byte ((I * 640) >> 16) & $ff
    .endrepeat

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
