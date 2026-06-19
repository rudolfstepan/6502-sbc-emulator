; ============================================================
; Mandelbrot Set — 320x200 Bitmap, 16 C64 Colors
; Standalone ROM for $C000-$FFFF (replaces EhBASIC)
;
; 4.12 signed fixed-point arithmetic (range -8.0 .. +7.999)
; 20 iterations, ~5-8 min on 1 MHz 6502
;
; Build:
;   ca65 --cpu 65c02 -o mandelbrot_bitmap.o mandelbrot_bitmap.s
;   ld65 -C mandelbrot_bitmap.cfg -o mandelbrot_bitmap.bin mandelbrot_bitmap.o
;
; Upload (pad to 16 KB with kernel or standalone):
;   python fpga/tools/upload_monitor_hex.py mandelbrot_bitmap.bin \
;       --port COM15 --baud 230400 --address 0xC000 --run
; ============================================================

; --- Hardware registers ---
VIC_MODE    = $9000
UART_DATA   = $8810
UART_SR     = $8811
UART_RDRF   = $08

; --- Memory map ---
BMP_BASE    = $9010         ; bitmap RAM (8000 bytes)
COL_BASE    = $8400         ; color RAM (1000 bytes)

; --- Mandelbrot constants (4.12 fixed-point) ---
X_LEFT      = $E000         ; -2.0
CI_START    = $ECCD         ; -1.2
SX_STEP     = 38            ; 3.0/320 * 4096 ≈ 38
SY_STEP     = 49            ; 2.4/200 * 4096 ≈ 49
ESCAPE_HI   = $40           ; 4.0 in 4.12 = $4000, check high byte >= $40
MAX_ITER    = 20

; ============================================================
.segment "ZEROPAGE"

ZR:         .res 2          ; z real
ZI:         .res 2          ; z imaginary
CR:         .res 2          ; c real
CI:         .res 2          ; c imaginary
ZR2:        .res 2          ; zr² (positive)
ZI2:        .res 2          ; zi² (positive)
TMP:        .res 2          ; scratch
ITER:       .res 1          ; iteration counter
BITS:       .res 1          ; accumulated 8-pixel byte
LASTCOL:    .res 1          ; last escape color in current cell
PY:         .res 1          ; pixel Y (0-199)
PXB:        .res 1          ; byte X (0-39)
BMPLO:      .res 1          ; bitmap row pointer low
BMPHI:      .res 1          ; bitmap row pointer high
COLLO:      .res 1          ; color row pointer low
COLHI:      .res 1          ; color row pointer high
YCELL:      .res 1          ; Y within color cell (0-7)
SIGN:       .res 1          ; multiply sign flag
MUL_A:      .res 2          ; multiply operand A (destroyed)
MUL_B:      .res 2          ; multiply operand B (multiplicand)
MUL_M:      .res 2          ; multiplier working copy (shifted out)
MUL_R:      .res 4          ; 32-bit multiply result

; ============================================================
.segment "CODE"

RESET:
    sei
    ldx #$FF
    txs

    ; --- Enable bitmap mode ---
    lda #$01
    sta VIC_MODE

    ; --- Clear bitmap RAM (8000 bytes) ---
    lda #<BMP_BASE
    sta TMP
    lda #>BMP_BASE
    sta TMP+1
    lda #0
    tay
    ldx #32                 ; 32 pages = 8192 bytes (covers 8000)
clr_bmp:
    sta (TMP),y
    iny
    bne clr_bmp
    inc TMP+1
    dex
    bne clr_bmp

    ; --- Fill color RAM with white-on-black ($01) ---
    lda #<COL_BASE
    sta TMP
    lda #>COL_BASE
    sta TMP+1
    lda #$01                ; fg=white, bg=black
    ldy #0
    ldx #4
clr_col:
    sta (TMP),y
    iny
    bne clr_col
    inc TMP+1
    dex
    bne clr_col

    ; --- Initialize outer loop ---
    lda #<CI_START
    sta CI
    lda #>CI_START
    sta CI+1

    lda #<BMP_BASE
    sta BMPLO
    lda #>BMP_BASE
    sta BMPHI

    lda #<COL_BASE
    sta COLLO
    lda #>COL_BASE
    sta COLHI

    lda #0
    sta PY
    sta YCELL

; ============================================================
; Main loop: for PY = 0 to 199
; ============================================================
row_loop:
    ; Reset CR to X_LEFT for this row
    lda #<X_LEFT
    sta CR
    lda #>X_LEFT
    sta CR+1

    lda #0
    sta PXB

; --- for PXB = 0 to 39 (byte columns) ---
byte_loop:
    lda #0
    sta BITS
    sta LASTCOL

    ; --- for 8 pixels within this byte ---
    ldx #0                  ; pixel index 0-7
pixel_loop:
    stx TMP                 ; save pixel index

    ; --- Mandelbrot iteration: z = 0, iterate z = z² + c ---
    lda #0
    sta ZR
    sta ZR+1
    sta ZI
    sta ZI+1
    lda #MAX_ITER
    sta ITER

iter_loop:
    ; --- Compute ZR2 = ZR * ZR ---
    lda ZR
    sta MUL_A
    sta MUL_B
    lda ZR+1
    sta MUL_A+1
    sta MUL_B+1
    jsr fpmul
    lda MUL_R+1
    sta ZR2
    lda MUL_R+2
    sta ZR2+1
    ; Check overflow: if ZR2 >= 4.0, escape
    lda ZR2+1
    bmi escaped             ; negative = overflow past 8.0
    cmp #ESCAPE_HI
    bcs escaped

    ; --- Compute ZI2 = ZI * ZI ---
    lda ZI
    sta MUL_A
    sta MUL_B
    lda ZI+1
    sta MUL_A+1
    sta MUL_B+1
    jsr fpmul
    lda MUL_R+1
    sta ZI2
    lda MUL_R+2
    sta ZI2+1
    lda ZI2+1
    bmi escaped
    cmp #ESCAPE_HI
    bcs escaped

    ; --- Check ZR2 + ZI2 > 4.0 ---
    clc
    lda ZR2
    adc ZI2
    sta TMP+1               ; temp low (reuse TMP+1, TMP has pixel index)
    lda ZR2+1
    adc ZI2+1
    bcs escaped             ; carry = overflow
    bmi escaped             ; negative = overflow
    cmp #ESCAPE_HI
    bcs escaped

    ; --- Compute new ZI = 2 * ZR * ZI + CI ---
    lda ZR
    sta MUL_A
    lda ZR+1
    sta MUL_A+1
    lda ZI
    sta MUL_B
    lda ZI+1
    sta MUL_B+1
    jsr fpmul
    ; result * 2 (shift left 1)
    asl MUL_R+1
    rol MUL_R+2
    ; add CI
    clc
    lda MUL_R+1
    adc CI
    sta ZI
    lda MUL_R+2
    adc CI+1
    sta ZI+1

    ; --- Compute new ZR = ZR2 - ZI2 + CR ---
    sec
    lda ZR2
    sbc ZI2
    sta ZR
    lda ZR2+1
    sbc ZI2+1
    sta ZR+1
    clc
    lda ZR
    adc CR
    sta ZR
    lda ZR+1
    adc CR+1
    sta ZR+1

    ; --- Next iteration ---
    dec ITER
    beq no_escape
    jmp iter_loop
no_escape:

    ; Did not escape — pixel stays off
    jmp next_pixel

escaped:
    ; --- Set pixel bit ---
    ldx TMP                 ; restore pixel index (0-7)
    lda mask_table,x
    ora BITS
    sta BITS

    ; --- Set color from iteration count ---
    lda #MAX_ITER
    sec
    sbc ITER                ; A = iterations used (1..MAX_ITER)
    tax
    lda color_table,x       ; look up palette color
    sta LASTCOL

next_pixel:
    ; --- Advance CR by SX ---
    clc
    lda CR
    adc #<SX_STEP
    sta CR
    lda CR+1
    adc #>SX_STEP
    sta CR+1

    ldx TMP                 ; restore pixel index
    inx
    cpx #8
    bcs :+
    jmp pixel_loop
:

    ; --- Store 8-pixel byte to bitmap RAM ---
    lda BITS
    beq skip_bmp            ; all zeros, skip write
    ldy PXB
    sta (BMPLO),y
skip_bmp:

    ; --- Store color to color RAM ---
    lda LASTCOL
    beq skip_col
    ldy PXB
    sta (COLLO),y
skip_col:

    ; --- Next byte column ---
    inc PXB
    lda PXB
    cmp #40
    bcs :+
    jmp byte_loop
:

    ; --- Advance bitmap pointer by 40 ---
    clc
    lda BMPLO
    adc #40
    sta BMPLO
    bcc :+
    inc BMPHI
:

    ; --- Advance color pointer every 8 rows ---
    inc YCELL
    lda YCELL
    cmp #8
    bcc :+
    lda #0
    sta YCELL
    clc
    lda COLLO
    adc #40
    sta COLLO
    bcc :+
    inc COLHI
:

    ; --- Advance CI by SY ---
    clc
    lda CI
    adc #<SY_STEP
    sta CI
    lda CI+1
    adc #>SY_STEP
    sta CI+1

    ; --- Next row ---
    inc PY
    lda PY
    cmp #200
    bcs :+
    jmp row_loop
:

    ; ============================================================
    ; Done — wait for UART key, then text mode
    ; ============================================================
wait_key:
    lda UART_SR
    and #UART_RDRF
    beq wait_key
    lda UART_DATA           ; consume key

    lda #$00
    sta VIC_MODE            ; back to text mode

halt:
    jmp halt

; ============================================================
; fpmul — Signed 4.12 fixed-point multiply
;
; Input:  MUL_A (16-bit signed, destroyed)
;         MUL_B (16-bit signed, preserved)
; Output: MUL_R+1 (result low), MUL_R+2 (result high)
;         in 4.12 signed fixed-point
; ============================================================
.proc fpmul
    ; Determine result sign
    lda MUL_A+1
    eor MUL_B+1
    sta SIGN

    ; Absolute value of A
    lda MUL_A+1
    bpl a_pos
    jsr neg_a
a_pos:

    ; Absolute value of B (save original for restore)
    lda MUL_B+1
    bpl b_pos
    jsr neg_b
b_pos:

    ; --- Unsigned 16x16 → 32 multiply (shift-add, product shifts right) ---
    ; Multiplier copy in MUL_M shifts out 1 bit/iter; result in MUL_R+0..+3.
    lda MUL_A
    sta MUL_M
    lda MUL_A+1
    sta MUL_M+1
    lda #0
    sta MUL_R
    sta MUL_R+1
    sta MUL_R+2
    sta MUL_R+3

    ldx #16
mul_loop:
    lsr MUL_M+1             ; multiplier LSB -> carry
    ror MUL_M
    bcc no_add
    clc
    lda MUL_R+2
    adc MUL_B
    sta MUL_R+2
    lda MUL_R+3
    adc MUL_B+1
    sta MUL_R+3
no_add:
    ror MUL_R+3            ; rotate 32-bit result right (carry from add at top)
    ror MUL_R+2
    ror MUL_R+1
    ror MUL_R
    dex
    bne mul_loop

    ; --- Extract 4.12: shift bytes [3:2:1] right by 4 ---
    lsr MUL_R+3
    ror MUL_R+2
    ror MUL_R+1
    lsr MUL_R+3
    ror MUL_R+2
    ror MUL_R+1
    lsr MUL_R+3
    ror MUL_R+2
    ror MUL_R+1
    lsr MUL_R+3
    ror MUL_R+2
    ror MUL_R+1
    ; Result: MUL_R+1 = low byte, MUL_R+2 = high byte

    ; --- Apply sign ---
    bit SIGN
    bpl no_neg
    sec
    lda #0
    sbc MUL_R+1
    sta MUL_R+1
    lda #0
    sbc MUL_R+2
    sta MUL_R+2
no_neg:
    ; MUL_A / MUL_B may be left negated; the Mandelbrot caller always
    ; reloads both operands before each call, so no restore is needed.
    rts

neg_a:
    sec
    lda #0
    sbc MUL_A
    sta MUL_A
    lda #0
    sbc MUL_A+1
    sta MUL_A+1
    rts

neg_b:
    sec
    lda #0
    sbc MUL_B
    sta MUL_B
    lda #0
    sbc MUL_B+1
    sta MUL_B+1
    rts
.endproc

; ============================================================
.segment "RODATA"

; Pixel mask table: bit 7 = pixel 0 (leftmost), bit 0 = pixel 7
mask_table:
    .byte $80, $40, $20, $10, $08, $04, $02, $01

; Color gradient: iteration count → C64 palette index
; Index 0 unused, 1-20 = blue→cyan→green→yellow→red→purple
color_table:
    .byte 0                 ; 0: unused
    .byte 6                 ; 1: blue
    .byte 6                 ; 2: blue
    .byte 14                ; 3: light blue
    .byte 14                ; 4: light blue
    .byte 3                 ; 5: cyan
    .byte 3                 ; 6: cyan
    .byte 13                ; 7: light green
    .byte 5                 ; 8: green
    .byte 7                 ; 9: yellow
    .byte 7                 ; 10: yellow
    .byte 10                ; 11: light red
    .byte 2                 ; 12: red
    .byte 8                 ; 13: orange
    .byte 9                 ; 14: brown
    .byte 4                 ; 15: purple
    .byte 12                ; 16: gray
    .byte 15                ; 17: light gray
    .byte 1                 ; 18: white
    .byte 11                ; 19: dark gray
    .byte 11                ; 20: dark gray

; ============================================================
.segment "VECTORS"
    .word RESET             ; $FFFA NMI
    .word RESET             ; $FFFC RESET
    .word RESET             ; $FFFE IRQ
