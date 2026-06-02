; ============================================================
;  6502 SBC  —  Advanced Graphics Demo
;  4 animated parts, each ~200 frames (~3s at 60fps):
;
;  PART 0 – COPPER BARS    moving rainbow colour bars
;  PART 1 – SINE PLASMA    smooth wave colour plasma
;  PART 2 – SPRITE CIRCLE  8 sprites rotating in formation
;  PART 3 – FIRE           scrolling pixel fire
;
;  VIC hardware:
;    Blitter  $8840-$884F   (FILL, COPY, CLEAR, LINE, CIRCLE, SCROLL, FILL_CIRCLE)
;    Sprites  $8850-$888F   8 × 8 bytes
;    SprData  $8900-$89FF   8 × 32 bytes
;    ColRAM   $8400-$87FF
;    BmpRAM   $9010-$AF4F   320×200 1bpp
;    VIC_CTRL $9000         bit0=bitmap bit1=sprites
;    VIC_FRAME$9005         read-only render counter (vsync)
; ============================================================

; ── VIC registers ───────────────────────────────────────────
VIC_CTRL  = $9000
VIC_FRAME = $9005

; ── Blitter ─────────────────────────────────────────────────
BL_X_L    = $8840
BL_X_H    = $8841
BL_Y      = $8842
BL_W      = $8843
BL_H      = $8844
BL_COLOR  = $8848
BL_OP     = $8849
BL_TRIG   = $884F

OP_FILL   = 0
OP_COPY   = 1
OP_CLEAR  = 2
OP_LINE   = 3
OP_CIRCLE = 4
OP_SCROLL = 5
OP_FCIRC  = 6

; ── Sprites ─────────────────────────────────────────────────
SPRBASE   = $8850     ; +i*8: X,Y,FLAGS,COLOR,DATA,pad
SPRDATA   = $8900

; ── Colour RAM ──────────────────────────────────────────────
COLRAM    = $8400

; ── Zero page ───────────────────────────────────────────────
ZP_FRAME  = $00     ; global frame lo
ZP_LAST   = $01     ; last VIC_FRAME (vsync)
ZP_PTR    = $02     ; 2-byte row pointer
ZP_ROW    = $04     ; loop row counter
ZP_RXOR   = $05     ; row-constant for colour loop
ZP_FG     = $06     ; temp fg nibble
ZP_PART   = $07     ; current part 0-3
ZP_PF     = $08     ; part frame (0..PART_DUR-1)
ZP_RNDLO  = $0A     ; LFSR lo
ZP_RNDHI  = $0B     ; LFSR hi
ZP_BOFF   = $0C     ; sprite byte offset (0,8,..,56)

; Sprite physics ($10-$4F: 8 sprites × 8 bytes)
; +0=X +1=Y +2=XDIR +3=YDIR +4=SPEED +5-7=pad
ZP_SP     = $10

PART_DUR  = 200     ; frames per part

; ============================================================
.segment "CODE"

demo_start:
    SEI
    CLD
    LDX  #$FF
    TXS

    ; seed LFSR
    LDA  #$A5
    STA  ZP_RNDLO
    LDA  #$1E
    STA  ZP_RNDHI

    LDA  #0
    STA  ZP_FRAME
    STA  ZP_LAST
    STA  ZP_PART
    STA  ZP_PF

    ; upload sprite ball shape (slot 0 – all 8 sprites share it)
    JSR  upload_ball

    ; init current part (part 0)
    JSR  init_part

    ; enable bitmap + sprites
    LDA  #$03
    STA  VIC_CTRL

    LDA  VIC_FRAME
    STA  ZP_LAST

; ── Main loop ───────────────────────────────────────────────
main_loop:
@vsync:
    LDA  VIC_FRAME
    CMP  ZP_LAST
    BEQ  @vsync
    STA  ZP_LAST

    INC  ZP_FRAME
    INC  ZP_PF

    ; dispatch
    LDA  ZP_PART
    BNE  @not0
    JSR  update_part0
    JMP  @advance
@not0:
    CMP  #1
    BNE  @not1
    JSR  update_part1
    JMP  @advance
@not1:
    CMP  #2
    BNE  @not2
    JSR  update_part2
    JMP  @advance
@not2:
    JSR  update_part3

@advance:
    LDA  ZP_PF
    CMP  #PART_DUR
    BCC  main_loop
    LDA  #0
    STA  ZP_PF
    INC  ZP_PART
    LDA  ZP_PART
    CMP  #4
    BCC  @no_wrap
    LDA  #0
    STA  ZP_PART
@no_wrap:
    JSR  init_part
    JMP  main_loop

; ============================================================
; init_part — clear bitmap + setup for current part
; ============================================================
init_part:
    LDA  #OP_CLEAR
    STA  BL_OP
    LDA  #0
    STA  BL_TRIG

    LDA  ZP_PART
    BNE  @not0
    JSR  init_part0
    RTS
@not0:
    CMP  #1
    BNE  @not1
    JSR  init_part1
    RTS
@not1:
    CMP  #2
    BNE  @not2
    JSR  init_part2
    RTS
@not2:
    JSR  init_part3
    RTS

; ============================================================
; PART 0 — COPPER BARS
; Bitmap: solid-fill stripes (8-row fg, 8-row bg alternating)
; Colour: each row gets rotating palette entry → moving bars
; Sprites: 8 bouncing balls
; ============================================================
init_part0:
    ; Draw horizontal fg-stripes in bitmap (every 8 rows on)
    LDA  #OP_FILL
    STA  BL_OP
    LDA  #1
    STA  BL_COLOR
    LDA  #0
    STA  BL_X_L
    STA  BL_X_H
    LDA  #$FF         ; W=256 (wraps to 256)
    STA  BL_W
    LDA  #8
    STA  BL_H

    LDA  #0           ; start Y=0
@stripe_loop:
    STA  BL_Y
    STA  BL_TRIG
    CLC
    ADC  #16          ; skip 8 rows, draw 8, skip 8...
    CMP  #200
    BCC  @stripe_loop

    ; also fill right side columns 256-319 (bytes 32-39 per row)
    JSR  fill_right_columns

    ; initialise sprites (bouncing)
    JSR  init_sprites_bounce
    RTS

fill_right_columns:
    ; Blitter FILL columns 256-319 (bytes 32-39 of each stripe row)
    LDA  #OP_FILL
    STA  BL_OP
    LDA  #1
    STA  BL_COLOR
    LDA  #64          ; X=256  low
    STA  BL_X_L
    LDA  #1           ; X_H=1  → X=256
    STA  BL_X_H
    LDA  #64          ; W=64
    STA  BL_W
    LDA  #8
    STA  BL_H

    LDA  #0
@rloop:
    STA  BL_Y
    STA  BL_TRIG
    CLC
    ADC  #16
    CMP  #200
    BCC  @rloop
    LDA  #0
    STA  BL_X_H      ; restore X_H
    RTS

update_part0:
    JSR  update_colram_bars
    JSR  update_sprites_bounce
    RTS

; Copper bars: row r gets bg=(r*2 + frame) & $F, fg complement
update_colram_bars:
    LDA  #0
    STA  ZP_ROW
@row:
    LDA  ZP_ROW
    ASL             ; row * 2
    CLC
    ADC  ZP_FRAME   ; + frame (scrolls the colours)
    AND  #$0F       ; bg colour nibble
    STA  ZP_FG      ; temp bg
    EOR  #$07       ; fg = bg rotated by 7 (not complement, for nicer look)
    AND  #$0F
    ASL             ; fg → high nibble position
    ASL
    ASL
    ASL
    STA  ZP_RXOR    ; save fg-high
    LDA  ZP_FG      ; bg back
    ORA  ZP_RXOR    ; attr = fg<<4 | bg
    ; write all 40 cells in this row
    LDX  ZP_ROW
    LDY  colram_lo, X
    STY  ZP_PTR
    LDY  colram_hi, X
    STY  ZP_PTR+1
    LDY  #39
@col:
    STA  (ZP_PTR), Y
    DEY
    BPL  @col
    INC  ZP_ROW
    LDA  ZP_ROW
    CMP  #25
    BNE  @row
    RTS

; ============================================================
; PART 1 — SINE PLASMA
; Bitmap: all pixels set ($FF)
; Colour: sin64[col*2+frame] + sin64[row*2+frame] per cell
; ============================================================
init_part1:
    ; Fill entire bitmap with $FF (all fg pixels)
    LDA  #OP_FILL
    STA  BL_OP
    LDA  #1
    STA  BL_COLOR
    LDA  #0
    STA  BL_X_L
    STA  BL_X_H
    LDA  #$FF         ; W=256
    STA  BL_W
    LDA  #$FF         ; H=256 (clamped to 200 in blitter)
    STA  BL_H
    STA  BL_TRIG
    ; Fill columns 256-319
    LDA  #1
    STA  BL_X_H
    LDA  #64
    STA  BL_X_L
    STA  BL_W
    LDA  #$FF
    STA  BL_H
    STA  BL_TRIG
    LDA  #0
    STA  BL_X_H
    ; disable sprites during plasma
    LDA  #$01         ; bitmap only, no sprites
    STA  VIC_CTRL
    RTS

update_part1:
    JSR  update_colram_plasma
    ; re-enable sprites for last 50 frames of this part
    LDA  ZP_PF
    CMP  #150
    BCC  @no_sp
    LDA  #$03
    STA  VIC_CTRL
    JSR  update_sprites_bounce
@no_sp:
    RTS

; Plasma: fg = sin64[(col*2+frame)&63], bg = sin64[(row*2+frame)&63]
update_colram_plasma:
    ; Precompute frame & 63 once → used as offset
    LDA  #0
    STA  ZP_ROW
@row_pl:
    ; ZP_RXOR = sin64[(row*2 + frame) & 63]  (row constant for this row)
    LDA  ZP_ROW
    ASL             ; row*2
    CLC
    ADC  ZP_FRAME
    AND  #63
    TAX
    LDA  sin64, X
    STA  ZP_RXOR    ; row sin value

    ; set ZP_PTR to COLRAM row
    LDX  ZP_ROW
    LDA  colram_lo, X
    STA  ZP_PTR
    LDA  colram_hi, X
    STA  ZP_PTR+1

    LDY  #39
@col_pl:
    TYA
    ASL             ; col*2
    CLC
    ADC  ZP_FRAME
    AND  #63
    TAX
    LDA  sin64, X   ; col sin value
    CLC
    ADC  ZP_RXOR    ; + row sin value
    LSR             ; /2 to keep in [0..15]
    AND  #$0F       ; fg
    STA  ZP_FG
    EOR  #$0F       ; bg = complement
    ASL
    ASL
    ASL
    ASL
    ORA  ZP_FG
    STA  (ZP_PTR), Y
    DEY
    BPL  @col_pl

    INC  ZP_ROW
    LDA  ZP_ROW
    CMP  #25
    BNE  @row_pl
    RTS

; ============================================================
; PART 2 — SPRITE CIRCLE DANCE
; Bitmap: concentric circles drawn at init
; 8 sprites rotate around a circle
; Colour: slow palette spin
; ============================================================
init_part2:
    ; Draw concentric circles
    LDA  #$A0       ; X=160
    STA  BL_X_L
    LDA  #0
    STA  BL_X_H
    LDA  #99        ; Y=99
    STA  BL_Y
    LDA  #1
    STA  BL_COLOR
    LDA  #OP_CIRCLE
    STA  BL_OP
    LDA  #85
    STA  BL_W
    STA  BL_TRIG
    LDA  #68
    STA  BL_W
    STA  BL_TRIG
    LDA  #51
    STA  BL_W
    STA  BL_TRIG
    LDA  #34
    STA  BL_W
    STA  BL_TRIG
    LDA  #17
    STA  BL_W
    STA  BL_TRIG
    ; Fill centre disc
    LDA  #OP_FCIRC
    STA  BL_OP
    LDA  #8
    STA  BL_W
    STA  BL_TRIG
    ; 8 radial spokes
    LDA  #OP_LINE
    STA  BL_OP
    JSR  draw_spokes
    ; re-enable sprites
    LDA  #$03
    STA  VIC_CTRL
    RTS

update_part2:
    JSR  update_sprites_circle
    JSR  update_colram_spin
    RTS

; sprites rotate around circle: sprite i → circle position (i+frame) mod 8
update_sprites_circle:
    LDA  #0
    STA  ZP_BOFF    ; sprite byte offset
    LDX  #0         ; sprite index

@sp_circ:
    ; position index = (sprite_index + frame) & 7
    TXA
    CLC
    ADC  ZP_FRAME
    AND  #7
    TAY             ; Y = circle position index
    ; get X,Y from table
    LDA  circle_x, Y
    STA  SPRBASE+0, X  ; wait, X is byte offset here (used as index *8)
    LDA  circle_y, Y
    STA  SPRBASE+1, X

    ; set colour cycling per sprite
    TXA             ; X = byte offset (0,8,16...)
    LSR
    LSR
    LSR  ; divide by 8 = sprite index
    CLC
    ADC  ZP_FRAME
    AND  #$0F
    BNE  @ok_col
    LDA  #1         ; never colour 0 (transparent)
@ok_col:
    STA  SPRBASE+3, X

    TXA
    CLC
    ADC  #8
    TAX
    STA  ZP_BOFF
    CPX  #64
    BNE  @sp_circ
    RTS

circle_x: .byte 210,195,160,125,110,125,160,195
circle_y: .byte  99,134,149,134, 99, 64, 49, 64

; slow colour spin: increment all colour entries by 1 each 4 frames
update_colram_spin:
    LDA  ZP_FRAME
    AND  #3
    BNE  @done      ; only update every 4 frames
    LDA  #0
    STA  ZP_ROW
@row_spin:
    LDX  ZP_ROW
    LDA  colram_lo, X
    STA  ZP_PTR
    LDA  colram_hi, X
    STA  ZP_PTR+1
    LDY  #39
@col_spin:
    LDA  (ZP_PTR), Y
    ; increment both nibbles by 1, wrapping within each nibble
    ; fg nibble (low)
    PHA
    AND  #$0F
    CLC
    ADC  #1
    AND  #$0F
    STA  ZP_FG
    PLA
    ; bg nibble (high)
    LSR
    LSR
    LSR
    LSR
    CLC
    ADC  #1
    AND  #$0F
    ASL
    ASL
    ASL
    ASL
    ORA  ZP_FG
    STA  (ZP_PTR), Y
    DEY
    BPL  @col_spin
    INC  ZP_ROW
    LDA  ZP_ROW
    CMP  #25
    BNE  @row_spin
@done:
    RTS

; ============================================================
; PART 3 — FIRE
; Scroll bitmap up 1 row/frame, add random sparks at bottom.
; Colour RAM = heat gradient preset at init.
; ============================================================
init_part3:
    ; Set fire colour gradient in colour RAM
    JSR  set_fire_colors
    ; Fill bottom third of bitmap with pixels
    LDA  #OP_FILL
    STA  BL_OP
    LDA  #1
    STA  BL_COLOR
    LDA  #0
    STA  BL_X_L
    STA  BL_X_H
    LDA  #$FF
    STA  BL_W
    LDA  #50          ; H=50 rows
    STA  BL_H
    LDA  #150         ; Y=150
    STA  BL_Y
    STA  BL_TRIG
    LDA  #$03
    STA  VIC_CTRL
    RTS

set_fire_colors:
    ; rows 0-4:   black  (bg=$0, fg=$0)
    ; rows 5-8:   red    (bg=$0, fg=$2)
    ; rows 9-12:  orange (bg=$2, fg=$8)
    ; rows 13-16: yellow (bg=$8, fg=$7)
    ; rows 17-20: bright (bg=$7, fg=$1)
    ; rows 21-24: white  (bg=$1, fg=$F)
    LDA  #0
    STA  ZP_ROW
@fr:
    LDX  ZP_ROW
    LDA  fire_attr, X   ; one attribute byte per row
    STA  ZP_FG
    LDA  colram_lo, X
    STA  ZP_PTR
    LDA  colram_hi, X
    STA  ZP_PTR+1
    LDY  #39
@fc:
    LDA  ZP_FG
    STA  (ZP_PTR), Y
    DEY
    BPL  @fc
    INC  ZP_ROW
    LDA  ZP_ROW
    CMP  #25
    BNE  @fr
    RTS

fire_attr:
    .byte $00,$00,$00,$00,$00   ; rows 0-4   black
    .byte $02,$02,$02,$02       ; rows 5-8   red
    .byte $28,$28,$28,$28       ; rows 9-12  orange
    .byte $87,$87,$87,$87       ; rows 13-16 yellow
    .byte $71,$71,$71,$71       ; rows 17-20 bright
    .byte $1F,$1F,$1F,$1F,$1F  ; rows 21-25 white

update_part3:
    ; Scroll bitmap up 1 pixel row
    LDA  #OP_SCROLL
    STA  BL_OP
    LDA  #1
    STA  BL_H
    STA  BL_TRIG
    ; Add 12 random sparks at bottom
    LDX  #12
@spark:
    JSR  lfsr_step
    AND  #$FE           ; even X (byte-aligned is fine)
    STA  BL_X_L
    LDA  #0
    STA  BL_X_H
    LDA  #199
    STA  BL_Y
    LDA  #3
    STA  BL_W
    STA  BL_H
    LDA  #1
    STA  BL_COLOR
    LDA  #OP_FILL
    STA  BL_OP
    STA  BL_TRIG
    DEX
    BNE  @spark
    ; Also bounce sprites through fire for visual variety
    JSR  update_sprites_bounce
    RTS

; ============================================================
; SHARED: Bouncing-sprite update
; ============================================================
init_sprites_bounce:
    LDA  #0
    STA  ZP_BOFF

    LDX  #0           ; sprite index
@loop:
    LDY  ZP_BOFF
    LDA  start_x, X
    STA  ZP_SP+0, Y
    LDA  start_y, X
    STA  ZP_SP+1, Y
    LDA  #0
    STA  ZP_SP+2, Y  ; XDIR=right
    LDA  #0
    STA  ZP_SP+3, Y  ; YDIR=down
    LDA  start_spd, X
    STA  ZP_SP+4, Y
    LDA  start_x, X
    STA  SPRBASE+0, Y
    LDA  start_y, X
    STA  SPRBASE+1, Y
    LDA  #$01
    STA  SPRBASE+2, Y  ; enable 8×8
    LDA  ball_colors, X
    STA SPRBASE+3, Y
    LDA  #0
    STA  SPRBASE+4, Y  ; data slot 0
    TYA
    CLC
    ADC  #8
    STA  ZP_BOFF
    INX
    CPX  #8
    BNE  @loop
    RTS

update_sprites_bounce:
    LDA  #0
    STA  ZP_BOFF
@sp_loop:
    LDY  ZP_BOFF
    ; ── X ──────────────────────────────────────────────────
    LDA  ZP_SP+2, Y
    BNE  @left_x
    LDA  ZP_SP+0, Y
    CLC
    ADC  ZP_SP+4, Y
    CMP  #248
    BCC  @ok_x
    LDA  #248
    STA  ZP_SP+0, Y
    LDA  #1
    STA  ZP_SP+2, Y
    JMP  @done_x
@left_x:
    LDA  ZP_SP+0, Y
    SEC
    SBC  ZP_SP+4, Y
    BCS  @ok_x
    LDA  #0
    STA  ZP_SP+0, Y
    LDA  #0
    STA  ZP_SP+2, Y
    JMP  @done_x
@ok_x: STA  ZP_SP+0, Y
@done_x:
    ; ── Y ──────────────────────────────────────────────────
    LDA  ZP_SP+3, Y
    BNE  @up_y
    LDA  ZP_SP+1, Y
    CLC
    ADC  ZP_SP+4, Y
    CMP  #192
    BCC  @ok_y
    LDA  #192
    STA  ZP_SP+1, Y
    LDA  #1
    STA  ZP_SP+3, Y
    JMP  @done_y
@up_y:
    LDA  ZP_SP+1, Y
    SEC
    SBC  ZP_SP+4, Y
    BCS  @ok_y
    LDA  #0
    STA  ZP_SP+1, Y
    LDA  #0
    STA  ZP_SP+3, Y
    JMP  @done_y
@ok_y: STA  ZP_SP+1, Y
@done_y:
    ; write to VIC
    LDA  ZP_SP+0, Y
    STA  SPRBASE+0, Y
    LDA  ZP_SP+1, Y
    STA  SPRBASE+1, Y
    ; advance
    TYA
    CLC
    ADC  #8
    TAY
    STY  ZP_BOFF
    CPY  #64
    BEQ  @sp_done
    JMP  @sp_loop
@sp_done:
    RTS

start_x:    .byte  20, 60,100,140,180,220, 40,200
start_y:    .byte  10, 30, 50, 70, 90,110, 20,150
start_spd:  .byte   2,  3,  2,  4,  1,  3,  2,  3
ball_colors:.byte   1,  5,  2,  7,  3, 13, 10, 14

; ============================================================
; draw_spokes — 8 lines from centre (160,99)
; ============================================================
draw_spokes:
    LDA  #$A0
    STA  BL_X_L
    LDA  #0
    STA  BL_X_H
    LDA  #99
    STA  BL_Y
    LDX  #0
@sl:
    LDA  spoke_x, X
    STA  BL_W
    LDA  spoke_y, X
    STA  BL_H
    LDA  #0
    STA  BL_TRIG
    INX
    CPX  #8
    BNE  @sl
    RTS

spoke_x: .byte 160,223,250,223,160, 96, 70, 96
spoke_y: .byte   9, 36, 99,162,189,162, 99, 36

; ============================================================
; upload_ball — 8×8 ball sprite to slot 0
; ============================================================
upload_ball:
    LDY  #0
@loop:
    LDA  ball_shape, Y
    STA  SPRDATA, Y
    INY
    CPY  #8
    BNE  @loop
    RTS

ball_shape: .byte $3C,$7E,$FF,$FF,$FF,$FF,$7E,$3C

; ============================================================
; lfsr_step — 16-bit LFSR, returns random byte in A
; ============================================================
lfsr_step:
    LDA  ZP_RNDHI
    LSR
    ROR  ZP_RNDLO
    BCC  @done
    LDA  ZP_RNDHI
    EOR  #$B4
    STA  ZP_RNDHI
@done:
    LDA  ZP_RNDLO
    RTS

; ============================================================
; COLRAM row address tables ($8400 + row*40)
; ============================================================
colram_lo:
    .byte $00,$28,$50,$78,$A0,$C8,$F0
    .byte $18,$40,$68,$90,$B8,$E0
    .byte $08,$30,$58,$80,$A8,$D0,$F8
    .byte $20,$48,$70,$98,$C0

colram_hi:
    .byte $84,$84,$84,$84,$84,$84,$84
    .byte $85,$85,$85,$85,$85,$85
    .byte $86,$86,$86,$86,$86,$86,$86
    .byte $87,$87,$87,$87,$87

; ============================================================
; 64-entry sine table (period=64, values 0-15)
; sin64[i] = round(sin(i*2*pi/64) * 7.5 + 7.5)
; ============================================================
sin64:
    .byte  8, 8, 9,10,10,11,12,12
    .byte 13,13,14,14,14,15,15,15
    .byte 15,15,15,15,14,14,14,13
    .byte 13,12,12,11,10,10, 9, 8
    .byte  7, 7, 6, 5, 5, 4, 3, 3
    .byte  2, 2, 1, 1, 1, 0, 0, 0
    .byte  0, 0, 0, 0, 1, 1, 1, 2
    .byte  2, 3, 3, 4, 5, 5, 6, 7

; ============================================================
; Interrupt stubs + vectors
; ============================================================
.segment "RODATA"
nmi_handler:
irq_handler:
    RTI

.segment "VECTORS"
    .word nmi_handler
    .word demo_start
    .word irq_handler
