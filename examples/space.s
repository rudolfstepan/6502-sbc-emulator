; ============================================================================
;  6502 SBC FPGA - Space flight: warp starfield + passing planets (640x400)
;
;  UART-loadable PRG (load/entry $1000, fpga.ini). All drawing goes through
;  the hardware blitter ($8840-$884F):
;
;    * 24 stars stream radially out of the screen centre. Each star is a
;      2x2 FILL; per frame its position advances by its velocity and the
;      velocity grows exponentially (v += v/16), which is exactly how a
;      constant-speed fly-through looks in perspective - no divide needed.
;      Stars leaving the screen respawn near the centre in a random
;      direction (8-bit LFSR).
;    * One planet at a time spawns near the centre, drifts outward at 1/8
;      star speed and grows through 10 precomputed disc sizes (r=2..33).
;      The disc is drawn as one FILL per row using a half-width profile
;      table; the previous image is wiped with a single bounding-box FILL.
;
;  Frame loop is vblank-synced like the cube: the emulator frame flag
;  ($9007 bit 1) and the FPGA raster read-back ($D011 bit 7) are polled
;  together, so the same PRG runs on both targets. Every blit is busy-polled
;  ($884F bit 7, sticky busy).
; ============================================================================

.import __LOADADDR__

.segment "EXEHDR"
    .word __LOADADDR__

; ---- registers ------------------------------------------------------------
VIC_MODE   = $9000
VIC_ISR    = $9007          ; emulator frame flag (FPGA reads $00 here)
VIC_PAGE   = $900F
VIC2_CTRL1 = $D011          ; FPGA: bit 7 = raster line bit 8

BLIT_X0LO = $8840
BLIT_X0HI = $8841
BLIT_Y0LO = $8842
BLIT_Y0HI = $8843
BLIT_X1LO = $8844
BLIT_X1HI = $8845
BLIT_Y1LO = $8846
BLIT_Y1HI = $8847
BLIT_COL  = $8848
BLIT_OP   = $8849           ; 0 = FILL
BLIT_PG   = $884A
BLIT_GAP  = $884B
BLIT_TRIG = $884F

MODE_HIRES = $20
IRQ_FRAME  = $02

NSTARS = 24

; ---- star arrays (all below $6000 = real board RAM) -----------------------
; positions/velocities are 10.6 fixed point (1/64 pixel units)
SXL  = $4000                ; star x lo
SXH  = SXL+NSTARS
SYL  = SXH+NSTARS
SYH  = SYL+NSTARS
SVXL = SYH+NSTARS           ; star velocity
SVXH = SVXL+NSTARS
SVYL = SVXH+NSTARS
SVYH = SVYL+NSTARS
SOXL = SVYH+NSTARS          ; old drawn pixel position (for erase)
SOXH = SOXL+NSTARS
SOYL = SOXH+NSTARS
SOYH = SOYL+NSTARS

; ---- zero page -------------------------------------------------------------
rnd    = $10                ; LFSR state
t1     = $11
t2     = $12
tsl    = $13                ; 16-bit shift scratch
tsh    = $14
pxl    = $15                ; extracted pixel position (16-bit)
pxh    = $16
pyl    = $17
pyh    = $18
pstate = $19                ; planet: 0 = paused, 1 = active
pcnt   = $1A                ; pause countdown
psize  = $1B                ; planet size index 0..9
pcol   = $1C                ; planet colour
pcix   = $1D                ; colour rotation index
gdiv   = $1E                ; growth divider
ppxl   = $1F                ; planet position (10.6 fixed)
ppxh   = $20
ppyl   = $21
ppyh   = $22
pvxl   = $23                ; planet velocity
pvxh   = $24
pvyl   = $25
pvyh   = $26
opxl   = $27                ; old planet centre pixel
opxh   = $28
opyl   = $29
opyh   = $2A
opr    = $2B                ; old planet radius+1 (0 = nothing drawn)
DPTR   = $2C                ; disc profile pointer (2 bytes)
prow   = $2E                ; disc rows remaining
cyl    = $2F                ; current disc row y (16-bit)
cyh    = $30
hw     = $31                ; current row half-width
prad   = $32                ; current planet radius
kcnt   = $33                ; init pre-advance counter

.segment "CODE"

start:
    sei
    cld
    ldx #$ff
    txs

    lda #MODE_HIRES
    sta VIC_MODE
    lda #$00
    sta VIC_PAGE
    lda #$A7
    sta rnd

    jsr clear_screen        ; blitter-fill the screen black

    ; ---- init stars: spawn, then pre-advance a random number of steps so the
    ;      field starts spread out instead of pulsing out of the centre ----
    ldx #NSTARS-1
@sinit:
    jsr star_respawn
    jsr rand
    and #$1F
    clc
    adc #8
    sta kcnt
@sadv:
    jsr star_step
    dec kcnt
    bne @sadv
    lda #<320               ; harmless first erase position: screen centre
    sta SOXL,x
    lda #>320
    sta SOXH,x
    lda #200
    sta SOYL,x
    lda #0
    sta SOYH,x
    dex
    bpl @sinit

    ; ---- init planet: paused, first spawn after ~1s ----
    lda #0
    sta pstate
    sta pcix
    sta opr
    lda #60
    sta pcnt

; ============================================================================
;  Main loop
; ============================================================================
main_loop:
    jsr wait_frame

    ; ---- erase all stars (2x2 black at old position) ----
    ldx #NSTARS-1
@erase:
    lda SOXL,x
    sta BLIT_X0LO
    clc
    adc #1
    sta BLIT_X1LO
    lda SOXH,x
    sta BLIT_X0HI
    adc #0
    sta BLIT_X1HI
    lda SOYL,x
    sta BLIT_Y0LO
    clc
    adc #1
    sta BLIT_Y1LO
    lda SOYH,x
    sta BLIT_Y0HI
    adc #0
    sta BLIT_Y1HI
    jsr black_fill
    dex
    bpl @erase

    ; ---- erase planet bounding box (covers the old disc) ----
    lda opr
    beq @no_perase
    sec
    lda opxl
    sbc opr
    sta BLIT_X0LO
    lda opxh
    sbc #0
    sta BLIT_X0HI
    clc
    lda opxl
    adc opr
    sta BLIT_X1LO
    lda opxh
    adc #0
    sta BLIT_X1HI
    sec
    lda opyl
    sbc opr
    sta BLIT_Y0LO
    lda opyh
    sbc #0
    sta BLIT_Y0HI
    clc
    lda opyl
    adc opr
    sta BLIT_Y1LO
    lda opyh
    adc #0
    sta BLIT_Y1HI
    jsr black_fill
    lda #0
    sta opr
@no_perase:

    ; ---- update + draw all stars ----
    ldx #NSTARS-1
@stars:
    jsr star_update_draw
    dex
    bpl @stars

    ; ---- planet ----
    jsr planet_update

    jmp main_loop

; ---------------------------------------------------------------------------
;  star_step - X = star index: pos += vel, vel += vel>>4 (exponential warp)
; ---------------------------------------------------------------------------
star_step:
    clc                     ; pos += vel (x)
    lda SVXL,x
    adc SXL,x
    sta SXL,x
    lda SVXH,x
    adc SXH,x
    sta SXH,x
    clc                     ; pos += vel (y)
    lda SVYL,x
    adc SYL,x
    sta SYL,x
    lda SVYH,x
    adc SYH,x
    sta SYH,x

    lda SVXH,x              ; vel.x += vel.x >> 4 (arithmetic)
    sta tsh
    lda SVXL,x
    sta tsl
    ldy #4
@shx:
    lda tsh
    cmp #$80
    ror tsh
    ror tsl
    dey
    bne @shx
    clc
    lda tsl
    adc SVXL,x
    sta SVXL,x
    lda tsh
    adc SVXH,x
    sta SVXH,x

    lda SVYH,x              ; vel.y += vel.y >> 4
    sta tsh
    lda SVYL,x
    sta tsl
    ldy #4
@shy:
    lda tsh
    cmp #$80
    ror tsh
    ror tsl
    dey
    bne @shy
    clc
    lda tsl
    adc SVYL,x
    sta SVYL,x
    lda tsh
    adc SVYH,x
    sta SVYH,x
    rts

; ---------------------------------------------------------------------------
;  star_update_draw - X = star index: step, extract pixel, respawn if off
;  screen, draw 2x2 white, remember position for next frame's erase.
; ---------------------------------------------------------------------------
star_update_draw:
    jsr star_step
@extract:
    lda SXH,x               ; pixel x = pos >> 6  (via <<2 of the high part)
    sta t2
    lda #0
    sta pxh
    lda SXL,x
    asl a
    rol t2
    rol pxh
    asl a
    rol t2
    rol pxh
    lda t2
    sta pxl
    lda SYH,x               ; pixel y = pos >> 6
    sta t2
    lda #0
    sta pyh
    lda SYL,x
    asl a
    rol t2
    rol pyh
    asl a
    rol t2
    rol pyh
    lda t2
    sta pyl

    ; bounds: x in [2..637], y in [2..397] else respawn
    lda pxh
    cmp #3
    bcs @respawn
    cmp #2
    bne @x_low
    lda pxl
    cmp #$7E                ; > 637?
    bcs @respawn
    bcc @x_ok
@x_low:
    lda pxh
    bne @x_ok               ; 256..511 always fine
    lda pxl
    cmp #2
    bcc @respawn
@x_ok:
    lda pyh
    cmp #2
    bcs @respawn
    cmp #1
    bne @y_low
    lda pyl
    cmp #$8E                ; > 397?
    bcs @respawn
    bcc @y_ok
@y_low:
    lda pyl
    cmp #2
    bcc @respawn
@y_ok:

    ; draw 2x2 white at (px,py)
    lda pxl
    sta BLIT_X0LO
    clc
    adc #1
    sta BLIT_X1LO
    lda pxh
    sta BLIT_X0HI
    adc #0
    sta BLIT_X1HI
    lda pyl
    sta BLIT_Y0LO
    clc
    adc #1
    sta BLIT_Y1LO
    lda pyh
    sta BLIT_Y0HI
    adc #0
    sta BLIT_Y1HI
    lda #$FF
    jsr fill_go

    lda pxl                 ; remember for next frame's erase
    sta SOXL,x
    lda pxh
    sta SOXH,x
    lda pyl
    sta SOYL,x
    lda pyh
    sta SOYH,x
    rts

@respawn:
    jsr star_respawn
    jmp @extract

; ---------------------------------------------------------------------------
;  star_respawn - X = star index: centre +-16px, random direction
; ---------------------------------------------------------------------------
star_respawn:
    jsr rand
    and #$1F
    tay
    lda dir_x,y
    sta SVXL,x
    bmi @nx
    lda #0
    beq @sx
@nx:
    lda #$FF
@sx:
    sta SVXH,x
    lda dir_y,y
    sta SVYL,x
    bmi @ny
    lda #0
    beq @sy
@ny:
    lda #$FF
@sy:
    sta SVYH,x

    jsr rnd_off64           ; t2:t1 = (rand&31 - 16) * 64
    clc
    lda t1
    adc #<20480             ; centre x = 320*64
    sta SXL,x
    lda t2
    adc #>20480
    sta SXH,x
    jsr rnd_off64
    clc
    lda t1
    adc #<12800             ; centre y = 200*64
    sta SYL,x
    lda t2
    adc #>12800
    sta SYH,x
    rts

; ---------------------------------------------------------------------------
;  planet_update - pause/spawn/fly/grow/draw
; ---------------------------------------------------------------------------
planet_update:
    lda pstate
    bne @active

    dec pcnt                ; paused: count down to the next spawn
    bne @done
    ; spawn: centre offset, slow random direction, smallest disc
    jsr rand
    and #$1F
    tay
    lda dir_x,y             ; velocity = direction / 8 (planets drift slowly)
    cmp #$80
    ror a
    cmp #$80
    ror a
    cmp #$80
    ror a
    sta pvxl
    bmi @pnx
    lda #0
    beq @psx
@pnx:
    lda #$FF
@psx:
    sta pvxh
    lda dir_y,y
    cmp #$80
    ror a
    cmp #$80
    ror a
    cmp #$80
    ror a
    sta pvyl
    bmi @pny
    lda #0
    beq @psy
@pny:
    lda #$FF
@psy:
    sta pvyh
    jsr rnd_off64
    clc
    lda t1
    adc #<20480
    sta ppxl
    lda t2
    adc #>20480
    sta ppxh
    jsr rnd_off64
    clc
    lda t1
    adc #<12800
    sta ppyl
    lda t2
    adc #>12800
    sta ppyh
    lda #0
    sta psize
    lda #8
    sta gdiv
    ldy pcix                ; next colour
    lda pcolors,y
    sta pcol
    iny
    tya
    and #3
    sta pcix
    lda #1
    sta pstate
@done:
    rts

@active:
    clc                     ; pos += vel
    lda pvxl
    adc ppxl
    sta ppxl
    lda pvxh
    adc ppxh
    sta ppxh
    clc
    lda pvyl
    adc ppyl
    sta ppyl
    lda pvyh
    adc ppyh
    sta ppyh

    lda pvxh                ; vel += vel >> 4 (same warp feel as the stars)
    sta tsh
    lda pvxl
    sta tsl
    ldy #4
@pshx:
    lda tsh
    cmp #$80
    ror tsh
    ror tsl
    dey
    bne @pshx
    clc
    lda tsl
    adc pvxl
    sta pvxl
    lda tsh
    adc pvxh
    sta pvxh
    lda pvyh
    sta tsh
    lda pvyl
    sta tsl
    ldy #4
@pshy:
    lda tsh
    cmp #$80
    ror tsh
    ror tsl
    dey
    bne @pshy
    clc
    lda tsl
    adc pvyl
    sta pvyl
    lda tsh
    adc pvyh
    sta pvyh

    dec gdiv                ; grow through the disc sizes
    bne @nogrow
    lda #8
    sta gdiv
    lda psize
    cmp #9
    bcs @nogrow
    inc psize
@nogrow:

    lda ppxh                ; pixel position = pos >> 6
    sta t2
    lda #0
    sta pxh
    lda ppxl
    asl a
    rol t2
    rol pxh
    asl a
    rol t2
    rol pxh
    lda t2
    sta pxl
    lda ppyh
    sta t2
    lda #0
    sta pyh
    lda ppyl
    asl a
    rol t2
    rol pyh
    asl a
    rol t2
    rol pyh
    lda t2
    sta pyl

    ; margins (max radius 33): x in [34..605], y in [34..365] else despawn
    lda pxh
    cmp #3
    bcs @desp_j
    cmp #2
    bne @px_low
    lda pxl
    cmp #$5E                ; > 605?
    bcs @desp_j
    bcc @px_ok
@px_low:
    lda pxh
    bne @px_ok
    lda pxl
    cmp #34
    bcc @desp_j
@px_ok:
    lda pyh
    cmp #2
    bcs @desp_j
    cmp #1
    bne @py_low
    lda pyl
    cmp #$6E                ; > 365?
    bcs @desp_j
    bcc @py_ok
@desp_j:
    jmp @despawn            ; (out of branch range past the draw loop)
@py_low:
    lda pyl
    cmp #34
    bcc @desp_j
@py_ok:

    ; ---- draw the disc: one FILL per row, half-widths from the profile ----
    ldy psize
    lda radius_tab,y
    sta prad
    lda disc_lo,y
    sta DPTR
    lda disc_hi,y
    sta DPTR+1
    lda prad
    asl a
    clc
    adc #1
    sta prow                ; rows = 2r+1
    sec
    lda pyl
    sbc prad
    sta cyl                 ; cy = py - r
    lda pyh
    sbc #0
    sta cyh
    ldy #0
@rowloop:
    lda (DPTR),y
    sta hw
    sec
    lda pxl
    sbc hw
    sta BLIT_X0LO
    lda pxh
    sbc #0
    sta BLIT_X0HI
    clc
    lda pxl
    adc hw
    sta BLIT_X1LO
    lda pxh
    adc #0
    sta BLIT_X1HI
    lda cyl
    sta BLIT_Y0LO
    sta BLIT_Y1LO
    lda cyh
    sta BLIT_Y0HI
    sta BLIT_Y1HI
    lda pcol
    jsr fill_go
    inc cyl
    bne @nocy
    inc cyh
@nocy:
    iny
    dec prow
    bne @rowloop

    lda pxl                 ; remember centre + radius for next frame's erase
    sta opxl
    lda pxh
    sta opxh
    lda pyl
    sta opyl
    lda pyh
    sta opyh
    lda prad
    clc
    adc #1
    sta opr
    rts

@despawn:
    lda #0
    sta pstate
    lda #90                 ; ~1.5 s pause before the next planet
    sta pcnt
    rts

; ---------------------------------------------------------------------------
;  helpers
; ---------------------------------------------------------------------------

rand:                       ; 8-bit LFSR, period 255
    lda rnd
    asl a
    bcc @nofb
    eor #$1D
@nofb:
    sta rnd
    rts

rnd_off64:                  ; t2:t1 = (rand & 31 - 16) * 64  (signed 16-bit)
    jsr rand
    and #$1F
    sec
    sbc #16                 ; -16..15
    sta t1
    cmp #$80                ; hi byte = value >> 2 (arithmetic)
    ror a
    cmp #$80
    ror a
    sta t2
    lda t1
    asl a                   ; lo byte = value << 6
    asl a
    asl a
    asl a
    asl a
    asl a
    sta t1
    rts

fill_go:                    ; A = colour; coordinate registers already set
    sta BLIT_COL
    lda #$00
    sta BLIT_OP             ; FILL
    sta BLIT_PG             ; page 0
    sta BLIT_TRIG
blit_wait:
    lda BLIT_TRIG           ; bit 7 = sticky busy
    bmi blit_wait
    rts

black_fill:                 ; black FILL of the already-set rectangle
    lda #$00
    jmp fill_go

clear_screen:               ; full-screen black FILL
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
    jmp black_fill

; wait for the next vblank on BOTH targets (emulator $9007 / FPGA $D011)
wait_frame:
    lda #IRQ_FRAME
    sta VIC_ISR
    ldy #0                  ; raster phase: 0 = wait high, 1 = wait low
@poll:
    lda VIC_ISR
    and #IRQ_FRAME
    bne @hit
    lda VIC2_CTRL1
    bmi @high
    cpy #1
    beq @hit                ; raster bit 8 fell -> FPGA vblank
    bne @poll
@high:
    ldy #1
    bne @poll
@hit:
    lda #IRQ_FRAME
    sta VIC_ISR
    rts

; ===========================================================================
;  Data
; ===========================================================================
.segment "RODATA"

; 32 directions * 40, in 1/64 px per frame (start speed 0.625 px/frame)
dir_x:
    .byte $28,$27,$25,$21,$1C,$16,$0F,$08,$00,$F8,$F1,$EA,$E4,$DF,$DB,$D9
    .byte $D8,$D9,$DB,$DF,$E4,$EA,$F1,$F8,$00,$08,$0F,$16,$1C,$21,$25,$27
dir_y:
    .byte $00,$08,$0F,$16,$1C,$21,$25,$27,$28,$27,$25,$21,$1C,$16,$0F,$08
    .byte $00,$F8,$F1,$EA,$E4,$DF,$DB,$D9,$D8,$D9,$DB,$DF,$E4,$EA,$F1,$F8

; planet colours (RGB332): red, orange, cyan, steel blue
pcolors:
    .byte $E0,$F8,$1F,$53

; planet discs: radius per size index, then per-row half-width profiles
radius_tab:
    .byte 2,3,4,6,8,11,15,20,26,33
disc2:
    .byte $00,$02,$02,$02,$00
disc3:
    .byte $00,$02,$03,$03,$03,$02,$00
disc4:
    .byte $00,$03,$03,$04,$04,$04,$03,$03,$00
disc6:
    .byte $00,$03,$04,$05,$06,$06,$06,$06,$06,$05,$04,$03,$00
disc8:
    .byte $00,$04,$05,$06,$07,$07,$08,$08,$08,$08,$08,$07,$07,$06,$05,$04
    .byte $00
disc11:
    .byte $00,$05,$06,$08,$08,$09,$0A,$0A,$0B,$0B,$0B,$0B,$0B,$0B,$0B,$0A
    .byte $0A,$09,$08,$08,$06,$05,$00
disc15:
    .byte $00,$05,$07,$09,$0A,$0B,$0C,$0D,$0D,$0E,$0E,$0E,$0F,$0F,$0F,$0F
    .byte $0F,$0F,$0F,$0E,$0E,$0E,$0D,$0D,$0C,$0B,$0A,$09,$07,$05,$00
disc20:
    .byte $00,$06,$09,$0B,$0C,$0D,$0E,$0F,$10,$11,$11,$12,$12,$13,$13,$13
    .byte $14,$14,$14,$14,$14,$14,$14,$14,$14,$13,$13,$13,$12,$12,$11,$11
    .byte $10,$0F,$0E,$0D,$0C,$0B,$09,$06,$00
disc26:
    .byte $00,$07,$0A,$0C,$0E,$0F,$11,$12,$13,$14,$14,$15,$16,$17,$17,$18
    .byte $18,$18,$19,$19,$19,$1A,$1A,$1A,$1A,$1A,$1A,$1A,$1A,$1A,$1A,$1A
    .byte $19,$19,$19,$18,$18,$18,$17,$17,$16,$15,$14,$14,$13,$12,$11,$0F
    .byte $0E,$0C,$0A,$07,$00
disc33:
    .byte $00,$08,$0B,$0E,$10,$11,$13,$14,$16,$17,$18,$19,$19,$1A,$1B,$1C
    .byte $1C,$1D,$1D,$1E,$1E,$1F,$1F,$1F,$20,$20,$20,$20,$21,$21,$21,$21
    .byte $21,$21,$21,$21,$21,$21,$21,$20,$20,$20,$20,$1F,$1F,$1F,$1E,$1E
    .byte $1D,$1D,$1C,$1C,$1B,$1A,$19,$19,$18,$17,$16,$14,$13,$11,$10,$0E
    .byte $0B,$08,$00
disc_lo:
    .byte <disc2,<disc3,<disc4,<disc6,<disc8,<disc11,<disc15,<disc20,<disc26,<disc33
disc_hi:
    .byte >disc2,>disc3,>disc4,>disc6,>disc8,>disc11,>disc15,>disc20,>disc26,>disc33
