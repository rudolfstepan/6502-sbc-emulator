; ============================================================
;  6502 SBC — Audio-Visual Demo ROM  (16 KB at $C000-$FFFF)
;
;  Visual effects driven by VIC frame IRQ (~50 fps):
;    Part 0 – Copper bars + bouncing sprites   (~4 s)
;    Part 1 – Sine plasma                       (~4 s)
;    Part 2 – Sprite circle dance               (~4 s)
;    Part 3 – Fire scroller                     (~4 s)
;    (loops continuously)
;
;  Audio runs in the main loop (~60 s song, then repeats):
;    Intro laser sweep
;    Section A – 28-chord ambient (triangle/sine/sawtooth)
;    SID arp × 2  (square wave)
;    Section B – 16-chord Dm/Bb/Am bridge
;    SID arp × 1, then back to A
;
;  Waveform encoding in CONTROL bits [6:4]:
;    0=sine  1=square  2=sawtooth  3=triangle  4=noise
; ============================================================

; ── VIC ──────────────────────────────────────────────────────
VIC_CTRL  = $9000
VIC_FRAME = $9005
VIC_ISR   = $9006       ; write 1 to ack interrupt
VIC_IER   = $9007       ; bit0=raster  bit1=frame
IRQ_FRAME = $02

; ── Blitter ──────────────────────────────────────────────────
BL_X_L    = $8840
BL_X_H    = $8841
BL_Y      = $8842
BL_W      = $8843
BL_H      = $8844
BL_COLOR  = $8848
BL_OP     = $8849
BL_TRIG   = $884F

OP_FILL   = 0
OP_CLEAR  = 2
OP_LINE   = 3
OP_CIRCLE = 4
OP_SCROLL = 5
OP_FCIRC  = 6

; ── Sprites / colour RAM ──────────────────────────────────────
SPRBASE   = $8850
SPRDATA   = $8900
COLRAM    = $8400

; ── Sound chip ───────────────────────────────────────────────
V0_FLO = $8830
V0_FHI = $8831
V0_DLO = $8832
V0_DHI = $8833
V0_VOL = $8834
V0_CTL = $8835
V0_ATK = $8836
V0_DEC = $8837
V0_SUS = $8838
V0_REL = $8839

V1_FLO = $8890
V1_FHI = $8891
V1_DLO = $8892
V1_DHI = $8893
V1_VOL = $8894
V1_CTL = $8895
V1_ATK = $8896
V1_DEC = $8897
V1_SUS = $8898
V1_REL = $8899

V2_FLO = $889A
V2_FHI = $889B
V2_DLO = $889C
V2_DHI = $889D
V2_VOL = $889E
V2_CTL = $889F
V2_ATK = $88A0
V2_DEC = $88A1
V2_SUS = $88A2
V2_REL = $88A3

V3_FLO = $88A4
V3_FHI = $88A5
V3_DLO = $88A6
V3_DHI = $88A7
V3_VOL = $88A8
V3_CTL = $88A9
V3_ATK = $88AA
V3_DEC = $88AB
V3_SUS = $88AC
V3_REL = $88AD

; ── Visual zero-page  $00–$4F (same layout as demo.s) ────────
ZP_FRAME  = $00     ; global frame counter
ZP_LAST   = $01     ; unused in IRQ mode but kept for layout
ZP_PTR    = $02     ; 2-byte row pointer for colour RAM writes
ZP_ROW    = $04
ZP_RXOR   = $05
ZP_FG     = $06
ZP_PART   = $07     ; current visual part 0-3
ZP_PF     = $08     ; frames within current part
ZP_RNDLO  = $0A
ZP_RNDHI  = $0B
ZP_BOFF   = $0C
ZP_SCR_POS= $0D     ; text scroller: current position in scr_msg (0–255)
ZP_SCR_CLR= $0E     ; text scroller: base rainbow colour index
ZP_SP     = $10     ; sprite physics: 8 sprites × 8 bytes → $10–$4F

; ── Audio zero-page  $50–$56 (clear of visual range) ─────────
snd_ptr_lo  = $50
snd_ptr_hi  = $51
snd_dly_cnt = $52
sweep_lo    = $53
sweep_hi    = $54
sweep_cnt   = $55
snd_dly_last= $56   ; last VIC_FRAME value for frame-polling delay

PART_DUR  = 200     ; VIC frames per visual part (~4 s at 50 fps)

; ============================================================
.segment "CODE"

; ── Reset ────────────────────────────────────────────────────
reset:
    SEI
    CLD
    LDX  #$FF
    TXS

    LDA  #$A5
    STA  ZP_RNDLO
    LDA  #$1E
    STA  ZP_RNDHI
    LDA  #0
    STA  ZP_FRAME
    STA  ZP_LAST
    STA  ZP_PART
    STA  ZP_PF
    STA  ZP_SCR_POS
    STA  ZP_SCR_CLR

    JSR  upload_ball
    JSR  init_part
    LDA  #$03
    STA  VIC_CTRL       ; bitmap + sprites on

    JSR  setup_patches
    JSR  intro_sweep

    LDA  #IRQ_FRAME
    STA  VIC_IER        ; enable VIC frame interrupt
    CLI

forever:
    JSR  play_poly_showcase
    JSR  play_hyper_arp
    JSR  play_hyper_arp
    JSR  play_ambient_bridge
    JSR  play_hyper_arp
    JMP  forever

; ── IRQ handler — visual update on every VIC frame ───────────
irq_handler:
    PHA
    TXA
    PHA
    TYA
    PHA

    LDA  #IRQ_FRAME
    STA  VIC_ISR        ; acknowledge

    INC  ZP_FRAME
    INC  ZP_PF

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
    CMP  #3
    BNE  @not3
    JSR  update_part3
    JMP  @advance
@not3:
    JSR  update_part4

@advance:
    LDA  ZP_PF
    CMP  #PART_DUR
    BCC  @irq_done
    LDA  #0
    STA  ZP_PF
    INC  ZP_PART
    LDA  ZP_PART
    CMP  #5            ; 5 parts: 0=bars 1=plasma 2=circle 3=fire 4=scroller
    BCC  @no_wrap
    LDA  #0
    STA  ZP_PART
@no_wrap:
    JSR  init_part

@irq_done:
    PLA
    TAY
    PLA
    TAX
    PLA
    RTI

; ============================================================
; VISUAL — init / update  (ported verbatim from demo.s)
; ============================================================

init_part:
    ; restore bitmap+sprites as default (part 4 will override to text mode)
    LDA  #$03
    STA  VIC_CTRL
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
    CMP  #3
    BNE  @not3
    JSR  init_part3
    RTS
@not3:
    JSR  init_part4
    RTS

; ── Part 0: Copper bars ───────────────────────────────────────
init_part0:
    LDA  #OP_FILL
    STA  BL_OP
    LDA  #1
    STA  BL_COLOR
    LDA  #0
    STA  BL_X_L
    STA  BL_X_H
    LDA  #$FF
    STA  BL_W
    LDA  #8
    STA  BL_H
    LDA  #0
@stripe_loop:
    STA  BL_Y
    STA  BL_TRIG
    CLC
    ADC  #16
    CMP  #200
    BCC  @stripe_loop
    JSR  fill_right_columns
    JSR  init_sprites_bounce
    RTS

fill_right_columns:
    LDA  #OP_FILL
    STA  BL_OP
    LDA  #1
    STA  BL_COLOR
    LDA  #64
    STA  BL_X_L
    LDA  #1
    STA  BL_X_H
    LDA  #64
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
    STA  BL_X_H
    RTS

update_part0:
    JSR  update_colram_bars
    JSR  update_sprites_bounce
    RTS

update_colram_bars:
    LDA  #0
    STA  ZP_ROW
@row:
    LDA  ZP_ROW
    ASL
    CLC
    ADC  ZP_FRAME
    AND  #$0F
    STA  ZP_FG
    EOR  #$07
    AND  #$0F
    ASL
    ASL
    ASL
    ASL
    STA  ZP_RXOR
    LDA  ZP_FG
    ORA  ZP_RXOR
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

; ── Part 1: Sine plasma ────────────────────────────────────────
init_part1:
    LDA  #OP_FILL
    STA  BL_OP
    LDA  #1
    STA  BL_COLOR
    LDA  #0
    STA  BL_X_L
    STA  BL_X_H
    LDA  #$FF
    STA  BL_W
    STA  BL_H
    STA  BL_TRIG
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
    LDA  #$01
    STA  VIC_CTRL
    RTS

update_part1:
    JSR  update_colram_plasma
    LDA  ZP_PF
    CMP  #150
    BCC  @no_sp
    LDA  #$03
    STA  VIC_CTRL
    JSR  update_sprites_bounce
@no_sp:
    RTS

update_colram_plasma:
    LDA  #0
    STA  ZP_ROW
@row_pl:
    LDA  ZP_ROW
    ASL
    CLC
    ADC  ZP_FRAME
    AND  #63
    TAX
    LDA  sin64, X
    STA  ZP_RXOR
    LDX  ZP_ROW
    LDA  colram_lo, X
    STA  ZP_PTR
    LDA  colram_hi, X
    STA  ZP_PTR+1
    LDY  #39
@col_pl:
    TYA
    ASL
    CLC
    ADC  ZP_FRAME
    AND  #63
    TAX
    LDA  sin64, X
    CLC
    ADC  ZP_RXOR
    LSR
    AND  #$0F
    STA  ZP_FG
    EOR  #$0F
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

; ── Part 2: Sprite circle dance ────────────────────────────────
init_part2:
    LDA  #$A0
    STA  BL_X_L
    LDA  #0
    STA  BL_X_H
    LDA  #99
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
    LDA  #OP_FCIRC
    STA  BL_OP
    LDA  #8
    STA  BL_W
    STA  BL_TRIG
    LDA  #OP_LINE
    STA  BL_OP
    JSR  draw_spokes
    LDA  #$03
    STA  VIC_CTRL
    RTS

update_part2:
    JSR  update_sprites_circle
    JSR  update_colram_spin
    RTS

update_sprites_circle:
    LDA  #0
    STA  ZP_BOFF
    LDX  #0
@sp_circ:
    TXA
    CLC
    ADC  ZP_FRAME
    AND  #7
    TAY
    LDA  circle_x, Y
    STA  SPRBASE+0, X
    LDA  circle_y, Y
    STA  SPRBASE+1, X
    TXA
    LSR
    LSR
    LSR
    CLC
    ADC  ZP_FRAME
    AND  #$0F
    BNE  @ok_col
    LDA  #1
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

update_colram_spin:
    LDA  ZP_FRAME
    AND  #3
    BNE  @spin_done
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
    PHA
    AND  #$0F
    CLC
    ADC  #1
    AND  #$0F
    STA  ZP_FG
    PLA
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
@spin_done:
    RTS

; ── Part 3: Fire scroller ─────────────────────────────────────
init_part3:
    JSR  set_fire_colors
    LDA  #OP_FILL
    STA  BL_OP
    LDA  #1
    STA  BL_COLOR
    LDA  #0
    STA  BL_X_L
    STA  BL_X_H
    LDA  #$FF
    STA  BL_W
    LDA  #50
    STA  BL_H
    LDA  #150
    STA  BL_Y
    STA  BL_TRIG
    LDA  #$03
    STA  VIC_CTRL
    RTS

set_fire_colors:
    LDA  #0
    STA  ZP_ROW
@fr:
    LDX  ZP_ROW
    LDA  fire_attr, X
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

update_part3:
    LDA  #OP_SCROLL
    STA  BL_OP
    LDA  #1
    STA  BL_H
    STA  BL_TRIG
    LDX  #12
@spark:
    JSR  lfsr_step
    AND  #$FE
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
    JSR  update_sprites_bounce
    RTS

; ── Part 4: Full-screen text scroller ────────────────────────
; All 25 rows display scr_msg with a diagonal stagger,
; scrolling right-to-left. Rainbow colours cycle row by row.
init_part4:
    LDA  #$00
    STA  VIC_CTRL          ; text mode (overrides init_part default)

    ; clear VRAM $8000-$83FF (1024 bytes) with spaces
    LDA  #$00
    STA  ZP_PTR
    LDA  #$80
    STA  ZP_PTR+1
    LDA  #$20              ; space
    LDY  #0
@ip4_clr:
    STA  (ZP_PTR), Y
    INY
    BNE  @ip4_clr
    INC  ZP_PTR+1
    LDA  ZP_PTR+1
    CMP  #$84
    BNE  @ip4_clr

    LDA  #0
    STA  ZP_SCR_POS
    STA  ZP_SCR_CLR
    JSR  scr_set_colors
    RTS

update_part4:
    ; advance scroll 1 char every 2 frames (comfortable reading speed)
    LDA  ZP_FRAME
    AND  #1
    BNE  @no_scroll
    INC  ZP_SCR_POS
@no_scroll:

    ; animate rainbow every 4 frames
    LDA  ZP_FRAME
    AND  #3
    BNE  @no_color
    INC  ZP_SCR_CLR
    JSR  scr_set_colors
@no_color:

    ; write all 25 rows to VRAM ($8000+)
    LDA  #$00
    STA  ZP_PTR
    LDA  #$80
    STA  ZP_PTR+1
    LDA  #0
    STA  ZP_ROW
@up4_row:
    ; index = (ZP_SCR_POS + ZP_ROW*2) — natural 8-bit wrap = mod-256
    LDA  ZP_ROW
    ASL
    CLC
    ADC  ZP_SCR_POS
    TAX
    LDY  #0
@up4_char:
    LDA  scr_msg, X        ; X auto-wraps at 256
    STA  (ZP_PTR), Y
    INX
    INY
    CPY  #40
    BNE  @up4_char
    ; advance ZP_PTR by 40 (next VRAM row)
    CLC
    LDA  ZP_PTR
    ADC  #40
    STA  ZP_PTR
    BCC  @up4_no_carry
    INC  ZP_PTR+1
@up4_no_carry:
    INC  ZP_ROW
    LDA  ZP_ROW
    CMP  #25
    BNE  @up4_row
    RTS

; set all 25 colour-RAM rows to cycling rainbow fg on black bg
scr_set_colors:
    LDA  #0
    STA  ZP_ROW
@ssc_row:
    LDX  ZP_ROW
    LDA  colram_lo, X
    STA  ZP_PTR
    LDA  colram_hi, X
    STA  ZP_PTR+1
    LDA  ZP_SCR_CLR
    CLC
    ADC  ZP_ROW
    AND  #$0F
    BNE  @ssc_nz
    LDA  #1                ; never 0 (would be black-on-black)
@ssc_nz:
    ASL
    ASL
    ASL
    ASL                    ; to high nibble (fg colour)
    LDY  #39
@ssc_col:
    STA  (ZP_PTR), Y
    DEY
    BPL  @ssc_col
    INC  ZP_ROW
    LDA  ZP_ROW
    CMP  #25
    BNE  @ssc_row
    RTS

; ── Shared: bouncing sprites ──────────────────────────────────
init_sprites_bounce:
    LDA  #0
    STA  ZP_BOFF
    LDX  #0
@sib_loop:
    LDY  ZP_BOFF
    LDA  start_x, X
    STA  ZP_SP+0, Y
    LDA  start_y, X
    STA  ZP_SP+1, Y
    LDA  #0
    STA  ZP_SP+2, Y
    STA  ZP_SP+3, Y
    LDA  start_spd, X
    STA  ZP_SP+4, Y
    LDA  start_x, X
    STA  SPRBASE+0, Y
    LDA  start_y, X
    STA  SPRBASE+1, Y
    LDA  #$01
    STA  SPRBASE+2, Y
    LDA  ball_colors, X
    STA  SPRBASE+3, Y
    LDA  #0
    STA  SPRBASE+4, Y
    TYA
    CLC
    ADC  #8
    STA  ZP_BOFF
    INX
    CPX  #8
    BNE  @sib_loop
    RTS

update_sprites_bounce:
    LDA  #0
    STA  ZP_BOFF
@usb_loop:
    LDY  ZP_BOFF
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
    STA  ZP_SP+2, Y
    JMP  @done_x
@ok_x:
    STA  ZP_SP+0, Y
@done_x:
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
    STA  ZP_SP+3, Y
    JMP  @done_y
@ok_y:
    STA  ZP_SP+1, Y
@done_y:
    LDA  ZP_SP+0, Y
    STA  SPRBASE+0, Y
    LDA  ZP_SP+1, Y
    STA  SPRBASE+1, Y
    TYA
    CLC
    ADC  #8
    TAY
    STY  ZP_BOFF
    CPY  #64
    BEQ  @usb_done
    JMP  @usb_loop
@usb_done:
    RTS

; ── draw_spokes ───────────────────────────────────────────────
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

; ── upload_ball ───────────────────────────────────────────────
upload_ball:
    LDY  #0
@ub_loop:
    LDA  ball_shape, Y
    STA  SPRDATA, Y
    INY
    CPY  #8
    BNE  @ub_loop
    RTS

; ── LFSR random number ────────────────────────────────────────
lfsr_step:
    LDA  ZP_RNDHI
    LSR
    ROR  ZP_RNDLO
    BCC  @rng_done
    LDA  ZP_RNDHI
    EOR  #$B4
    STA  ZP_RNDHI
@rng_done:
    LDA  ZP_RNDLO
    RTS

; ============================================================
; AUDIO — 4-voice chip music
; ZP: snd_ptr_lo=$50  snd_ptr_hi=$51  snd_dly_cnt=$52
;     sweep_lo=$53    sweep_hi=$54    sweep_cnt=$55
; ============================================================

; ── setup_patches ─────────────────────────────────────────────
setup_patches:
    LDA #220
    STA V0_VOL
    LDA #2
    STA V0_ATK
    LDA #3
    STA V0_DEC
    LDA #150
    STA V0_SUS
    LDA #6
    STA V0_REL

    LDA #185
    STA V1_VOL
    LDA #8
    STA V1_ATK
    LDA #10
    STA V1_DEC
    LDA #190
    STA V1_SUS
    LDA #14
    STA V1_REL

    LDA #180
    STA V2_VOL
    LDA #0
    STA V2_ATK
    LDA #2
    STA V2_DEC
    LDA #90
    STA V2_SUS
    LDA #3
    STA V2_REL

    LDA #255
    STA V3_VOL
    LDA #0
    STA V3_ATK
    LDA #2
    STA V3_DEC
    LDA #120
    STA V3_SUS
    LDA #6
    STA V3_REL
    RTS

; ── intro_sweep — rising+falling laser on voice 3 ─────────────
intro_sweep:
    LDA  #120
    STA  sweep_lo
    LDA  #0
    STA  sweep_hi

    LDA  #24
    STA  sweep_cnt
sweep_up:
    LDA  sweep_lo
    STA  V3_FLO
    LDA  sweep_hi
    STA  V3_FHI
    LDA  #60
    STA  V3_DLO
    LDA  #0
    STA  V3_DHI
    LDA  #$21           ; sawtooth | trigger
    STA  V3_CTL
    LDA  #2
    JSR  delay_25ms_units
    CLC
    LDA  sweep_lo
    ADC  #18
    STA  sweep_lo
    LDA  sweep_hi
    ADC  #0
    STA  sweep_hi
    DEC  sweep_cnt
    BNE  sweep_up

    LDA  #24
    STA  sweep_cnt
sweep_down:
    LDA  sweep_lo
    STA  V3_FLO
    LDA  sweep_hi
    STA  V3_FHI
    LDA  #60
    STA  V3_DLO
    LDA  #0
    STA  V3_DHI
    LDA  #$21
    STA  V3_CTL
    LDA  #2
    JSR  delay_25ms_units
    SEC
    LDA  sweep_lo
    SBC  #14
    STA  sweep_lo
    LDA  sweep_hi
    SBC  #0
    STA  sweep_hi
    DEC  sweep_cnt
    BNE  sweep_down
    RTS

; ── ambient_play_engine — shared 4-voice loop ─────────────────
; On entry: snd_ptr_lo/hi → 11-byte-per-entry table
; Format:   V0FL,V0FH, V1FL,V1FH, V2FL,V2FH, V3FL,V3FH, DLO,DHI,WAIT
; Terminated by first byte = 0.
.proc ambient_play_engine
    LDY  #0
amb_next:
    LDA  (snd_ptr_lo), Y
    BEQ  amb_done
    STA  V0_FLO
    INY
    LDA  (snd_ptr_lo), Y
    STA  V0_FHI
    INY
    LDA  (snd_ptr_lo), Y
    STA  V1_FLO
    INY
    LDA  (snd_ptr_lo), Y
    STA  V1_FHI
    INY
    LDA  (snd_ptr_lo), Y
    STA  V2_FLO
    INY
    LDA  (snd_ptr_lo), Y
    STA  V2_FHI
    INY
    LDA  (snd_ptr_lo), Y
    STA  V3_FLO
    INY
    LDA  (snd_ptr_lo), Y
    STA  V3_FHI
    INY
    LDA  (snd_ptr_lo), Y
    STA  V0_DLO
    STA  V1_DLO
    STA  V2_DLO
    STA  V3_DLO
    INY
    LDA  (snd_ptr_lo), Y
    STA  V0_DHI
    STA  V1_DHI
    STA  V2_DHI
    STA  V3_DHI
    INY
    LDA  (snd_ptr_lo), Y
    PHA
    LDA  #$31           ; triangle | trigger (V0 lead)
    STA  V0_CTL
    LDA  #$01           ; sine     | trigger (V1 pad)
    STA  V1_CTL
    LDA  #$31           ; triangle | trigger (V2 harmony)
    STA  V2_CTL
    LDA  #$21           ; sawtooth | trigger (V3 bass)
    STA  V3_CTL
    CLC
    LDA  snd_ptr_lo
    ADC  #11
    STA  snd_ptr_lo
    BCC  amb_ptr_ok
    INC  snd_ptr_hi
amb_ptr_ok:
    PLA
    JSR  delay_25ms_units
    LDY  #0
    JMP  amb_next
amb_done:
    RTS
.endproc

; ── play_poly_showcase — set ambient ADSR, play Section A ─────
.proc play_poly_showcase
    LDA  #200
    STA  V0_VOL
    LDA  #10
    STA  V0_ATK
    LDA  #5
    STA  V0_DEC
    LDA  #200
    STA  V0_SUS
    LDA  #25
    STA  V0_REL

    LDA  #165
    STA  V1_VOL
    LDA  #20
    STA  V1_ATK
    LDA  #8
    STA  V1_DEC
    LDA  #220
    STA  V1_SUS
    LDA  #35
    STA  V1_REL

    LDA  #175
    STA  V2_VOL
    LDA  #15
    STA  V2_ATK
    LDA  #6
    STA  V2_DEC
    LDA  #210
    STA  V2_SUS
    LDA  #28
    STA  V2_REL

    LDA  #230
    STA  V3_VOL
    LDA  #3
    STA  V3_ATK
    LDA  #12
    STA  V3_DEC
    LDA  #160
    STA  V3_SUS
    LDA  #18
    STA  V3_REL

    LDA  #<ambient_data
    STA  snd_ptr_lo
    LDA  #>ambient_data
    STA  snd_ptr_hi
    JMP  ambient_play_engine
.endproc

; ── play_ambient_bridge — play Section B ─────────────────────
.proc play_ambient_bridge
    LDA  #<bridge_data
    STA  snd_ptr_lo
    LDA  #>bridge_data
    STA  snd_ptr_hi
    JMP  ambient_play_engine
.endproc

; ── play_hyper_arp — SID-style square-wave arpeggio ──────────
.proc play_hyper_arp
    ; Fill the silence: sustain V0/V1 as an Am pad underneath the arp.
    ; Uses existing ambient ADSR (set by play_poly_showcase).
    ; 12000 ms = DHI=46, DLO=224  (46*256+224=12000)
    LDA  #220              ; A3 = 220 Hz
    STA  V0_FLO
    LDA  #0
    STA  V0_FHI
    LDA  #224
    STA  V0_DLO
    LDA  #46
    STA  V0_DHI
    LDA  #$01              ; sine | trigger
    STA  V0_CTL

    LDA  #165              ; E3 = 165 Hz (completes the Am chord)
    STA  V1_FLO
    LDA  #0
    STA  V1_FHI
    LDA  #224
    STA  V1_DLO
    LDA  #46
    STA  V1_DHI
    LDA  #$01
    STA  V1_CTL

    ; V2/V3: sharp arp voice ADSR
    LDA  #0
    STA  V2_ATK
    LDA  #1
    STA  V2_DEC
    LDA  #70
    STA  V2_SUS
    LDA  #2
    STA  V2_REL
    LDA  #0
    STA  V3_ATK
    LDA  #4
    STA  V3_DEC
    LDA  #20
    STA  V3_SUS
    LDA  #8
    STA  V3_REL

    LDA  #<arp_data
    STA  snd_ptr_lo
    LDA  #>arp_data
    STA  snd_ptr_hi

    LDY  #0
arp_next:
    LDA  (snd_ptr_lo), Y
    BEQ  arp_done
    STA  V2_FLO
    INY
    LDA  (snd_ptr_lo), Y
    STA  V2_FHI
    INY
    LDA  (snd_ptr_lo), Y
    STA  V3_FLO
    INY
    LDA  (snd_ptr_lo), Y
    STA  V3_FHI
    INY
    LDA  (snd_ptr_lo), Y
    STA  V2_DLO
    STA  V3_DLO
    INY
    LDA  (snd_ptr_lo), Y
    STA  V2_DHI
    STA  V3_DHI
    INY
    LDA  (snd_ptr_lo), Y
    PHA
    LDA  #$11           ; square | trigger
    STA  V2_CTL
    STA  V3_CTL
    CLC
    LDA  snd_ptr_lo
    ADC  #7
    STA  snd_ptr_lo
    BCC  arp_ptr_ok
    INC  snd_ptr_hi
arp_ptr_ok:
    PLA
    JSR  delay_25ms_units
    LDY  #0
    JMP  arp_next
arp_done:
    LDA  #2
    STA  V3_DEC
    LDA  #120
    STA  V3_SUS
    LDA  #6
    STA  V3_REL
    RTS
.endproc

; ── delay_25ms_units — wait A VIC frames ─────────────────────
; Polls VIC_FRAME ($9005) instead of counting CPU cycles.
; VIC_FRAME advances once per raster frame (every 20 000 cycles
; at 1 MHz / 50 fps) regardless of IRQ overhead, so the sound
; timing is immune to how heavy the visual ISR is.
; 1 frame ≈ 20 ms; original WAIT values were in 25 ms units,
; so we scale: frames = A + A>>2  (≈ A × 1.25 → ~25 ms/unit).
.proc delay_25ms_units
    ; scale A from 25ms units to frames: frames ≈ A * 5/4
    PHA
    LSR
    LSR                 ; A = original >> 2
    STA  snd_dly_cnt
    PLA
    CLC
    ADC  snd_dly_cnt    ; A = original + original/4
    BNE  dly_start
    INC  snd_dly_cnt    ; guard against zero
    JMP  dly_poll
dly_start:
    STA  snd_dly_cnt
dly_poll:
    LDA  VIC_FRAME
    STA  snd_dly_last
dly_wait:
    LDA  VIC_FRAME
    CMP  snd_dly_last
    BEQ  dly_wait       ; same frame — keep waiting
    STA  snd_dly_last   ; new frame ticked
    DEC  snd_dly_cnt
    BNE  dly_wait
    RTS
.endproc

; ============================================================
; DATA — visual
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

sin64:
    .byte  8, 8, 9,10,10,11,12,12
    .byte 13,13,14,14,14,15,15,15
    .byte 15,15,15,15,14,14,14,13
    .byte 13,12,12,11,10,10, 9, 8
    .byte  7, 7, 6, 5, 5, 4, 3, 3
    .byte  2, 2, 1, 1, 1, 0, 0, 0
    .byte  0, 0, 0, 0, 1, 1, 1, 2
    .byte  2, 3, 3, 4, 5, 5, 6, 7

start_x:    .byte  20, 60,100,140,180,220, 40,200
start_y:    .byte  10, 30, 50, 70, 90,110, 20,150
start_spd:  .byte   2,  3,  2,  4,  1,  3,  2,  3
ball_colors:.byte   1,  5,  2,  7,  3, 13, 10, 14

spoke_x: .byte 160,223,250,223,160, 96, 70, 96
spoke_y: .byte   9, 36, 99,162,189,162, 99, 36

ball_shape: .byte $3C,$7E,$FF,$FF,$FF,$FF,$7E,$3C

fire_attr:
    .byte $00,$00,$00,$00,$00
    .byte $02,$02,$02,$02
    .byte $28,$28,$28,$28
    .byte $87,$87,$87,$87
    .byte $71,$71,$71,$71
    .byte $1F,$1F,$1F,$1F,$1F

; ============================================================
; DATA — text scroller  (exactly 256 bytes, 8-bit index wraps)
; ============================================================
scr_msg:
    .byte "   * 6502 SBC AUDIO-VISUAL DEMO *   COPPER BARS  SINE PLASMA  SPRITE DANCE  FIRE  "
    .byte "4-VOICE CHIP MUSIC WITH TRIANGLE  SAWTOOTH  SQUARE AND NOISE WAVEFORMS  "
    .byte "THIS IS A NEW DEMO FOR THE 6502 SBC EMULATOR  "
    .byte "GREETINGS TO ALL 6502 FANS!  "
    .res  scr_msg + 256 - *, $20   ; pad to exactly 256 bytes with spaces

; ============================================================
; DATA — audio  (11 bytes/chord: V0FL,V0FH,V1FL,V1FH,
;                V2FL,V2FH,V3FL,V3FH,DLO,DHI,WAIT)
; dur=2000ms (DLO=208,DHI=7)  WAIT=40→1s  50→1.25s  60→1.5s
; ============================================================
ambient_data:
    ; — Part 1: gentle intro, lower register —
    .byte 220,0, 165,0, 131,0, 110,0, 208,7, 40  ; Am
    .byte   5,1, 220,0, 175,0,  87,0, 208,7, 40  ; F
    .byte  73,1, 196,0, 165,0,  65,0, 208,7, 40  ; C
    .byte  37,1, 247,0, 196,0,  98,0, 208,7, 40  ; G
    .byte 220,0, 165,0, 131,0, 110,0, 208,7, 40  ; Am
    .byte   5,1, 220,0, 175,0,  87,0, 208,7, 40  ; F
    .byte 136,1,  73,1,   5,1,  65,0, 208,7, 40  ; C (high)
    .byte  37,1, 196,0, 247,0,  98,0, 208,7, 40  ; G/B
    ; — Part 2: building, mid-high register —
    .byte 136,1,  73,1,   5,1, 110,0, 208,7, 40  ; Am7
    .byte 184,1,   5,1, 220,0,  87,0, 208,7, 40  ; Fmaj7
    .byte 147,2, 136,1,   5,1, 131,0, 208,7, 40  ; C
    .byte  75,2, 238,1, 136,1,  98,0, 208,7, 40  ; G
    .byte 136,1,  73,1,   5,1, 110,0, 208,7, 40  ; Am7
    .byte  93,1,  37,1, 220,0,  73,0, 208,7, 40  ; Dm
    .byte 147,2, 238,1,  73,1,  82,0, 208,7, 40  ; E (tension)
    .byte 184,1,  73,1,   5,1, 110,0, 208,7, 50  ; Am (resolve)
    ; — Part 3: peak, high register —
    .byte 147,2,  11,2, 184,1, 110,0, 208,7, 40  ; Am
    .byte  23,4, 184,1,  93,1,  87,0, 208,7, 40  ; F
    .byte 147,2,  11,2, 136,1,  65,0, 208,7, 40  ; C
    .byte  75,2, 238,1, 136,1,  98,0, 208,7, 40  ; G
    .byte 186,2,  75,2, 184,1,  73,0, 208,7, 40  ; Dm
    .byte 147,2,  11,2, 184,1, 110,0, 208,7, 40  ; Am
    .byte  75,2, 238,1, 136,1,  98,0, 208,7, 40  ; G
    .byte  23,4, 112,3, 147,2, 110,0, 208,7, 50  ; Am climax
    ; — Part 4: outro, descend —
    .byte  73,1, 220,0, 165,0, 131,0, 208,7, 40  ; Am/C
    .byte  93,1,   5,1, 220,0,  87,0, 208,7, 40  ; F
    .byte  37,1, 196,0, 247,0,  98,0, 208,7, 40  ; G
    .byte 220,0, 165,0, 131,0, 110,0, 208,7, 60  ; Am final
    .byte 0

; — Bridge: Dm/Bb/Am space —
bridge_data:
    .byte  75,2, 184,1,  93,1,  73,0, 208,7, 40  ; Dm
    .byte 186,2,  75,2, 210,1,  58,0, 208,7, 40  ; Bb
    .byte  23,4, 184,1,  73,1, 110,0, 208,7, 40  ; Am
    .byte 147,2, 238,1, 159,1,  82,0, 208,7, 40  ; E7
    .byte 186,2,  75,2, 184,1,  73,0, 208,7, 40  ; Dm
    .byte  75,2, 210,1, 136,1,  98,0, 208,7, 40  ; Gm
    .byte 147,2, 136,1,   5,1,  65,0, 208,7, 40  ; C
    .byte  23,4, 184,1,  93,1,  87,0, 208,7, 40  ; F
    .byte 112,3, 186,2,  75,2,  73,0, 208,7, 40  ; Dm (high)
    .byte  16,3, 147,2,  11,2,  65,0, 208,7, 40  ; C
    .byte 186,2,  75,2, 210,1,  58,0, 208,7, 40  ; Bb
    .byte 147,2,  11,2, 184,1, 110,0, 208,7, 40  ; Am
    .byte  75,2, 184,1,  93,1,  73,0, 208,7, 40  ; Dm
    .byte  75,2, 238,1, 136,1,  98,0, 208,7, 40  ; G
    .byte  16,3, 147,2,  11,2, 110,0, 208,7, 40  ; Am7
    .byte 184,1,  73,1,   5,1, 110,0, 208,7, 60  ; Am final
    .byte 0

; — SID arp: Am/C/G/F, 12 notes × 4 chords —
; (7 bytes: V2FL,V2FH, V3FL,V3FH, DLO,DHI, WAIT)
arp_data:
    .byte 184,1, 110,0, 80,0, 4   ; A4+A2
    .byte  11,2, 110,0, 80,0, 4   ; C5+A2
    .byte 147,2, 110,0, 80,0, 4   ; E5+A2
    .byte 184,1, 110,0, 80,0, 4
    .byte  11,2, 110,0, 80,0, 4
    .byte 147,2, 110,0, 80,0, 4
    .byte 220,3, 110,0, 80,0, 4   ; A5+A2 (octave)
    .byte 147,2, 110,0, 80,0, 4
    .byte  11,2, 110,0, 80,0, 4
    .byte 220,3, 110,0, 80,0, 4
    .byte 147,2, 110,0, 80,0, 4
    .byte  11,2, 110,0, 80,0, 4
    .byte  11,2,  65,0, 80,0, 4   ; C5+C2
    .byte 147,2,  65,0, 80,0, 4   ; E5+C2
    .byte  16,3,  65,0, 80,0, 4   ; G5+C2
    .byte  11,2,  65,0, 80,0, 4
    .byte 147,2,  65,0, 80,0, 4
    .byte  16,3,  65,0, 80,0, 4
    .byte  23,4,  65,0, 80,0, 4   ; C6+C2
    .byte  16,3,  65,0, 80,0, 4
    .byte 147,2,  65,0, 80,0, 4
    .byte  23,4,  65,0, 80,0, 4
    .byte  16,3,  65,0, 80,0, 4
    .byte 147,2,  65,0, 80,0, 4
    .byte  16,3,  49,0, 80,0, 4   ; G5+G1
    .byte 220,3,  49,0, 80,0, 4   ; B5+G1
    .byte  75,2,  49,0, 80,0, 4   ; D5+G1
    .byte  16,3,  49,0, 80,0, 4
    .byte 220,3,  49,0, 80,0, 4
    .byte  75,2,  49,0, 80,0, 4
    .byte  16,3,  49,0, 80,0, 4
    .byte 220,3,  49,0, 80,0, 4
    .byte  75,2,  49,0, 80,0, 4
    .byte  16,3,  49,0, 80,0, 4
    .byte 220,3,  49,0, 80,0, 4
    .byte  75,2,  49,0, 80,0, 4
    .byte 186,2,  44,0, 80,0, 4   ; F5+F1
    .byte 184,1,  44,0, 80,0, 4   ; A4+F1
    .byte  11,2,  44,0, 80,0, 4   ; C5+F1
    .byte 186,2,  44,0, 80,0, 4
    .byte 184,1,  44,0, 80,0, 4
    .byte  11,2,  44,0, 80,0, 4
    .byte 186,2,  44,0, 80,0, 4
    .byte 184,1,  44,0, 80,0, 4
    .byte  11,2,  44,0, 80,0, 4
    .byte 186,2,  44,0, 80,0, 4
    .byte 184,1,  44,0, 80,0, 4
    .byte  11,2,  44,0,160,0, 8   ; hold — end of phrase
    .byte 0

; ============================================================
.segment "RODATA"
nmi_handler:
    RTI

.segment "VECTORS"
    .word nmi_handler
    .word reset
    .word irq_handler
