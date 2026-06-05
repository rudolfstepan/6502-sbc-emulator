; ============================================================
; rom_demo.s  -  6502 SBC ROM: VGA welcome screen + serial keyboard
;
; ROM: 2 KB at $F800-$FFFF
; Reset entry:  $F800
; IRQ handler:  irq_handler
;
; Hardware:
;   VIC text RAM  $8000-$87FF  (40x25 chars)
;   VIA 6522      $8800-$880F  (Timer 1 IRQ, Port B -> LEDs)
;   UART 6551     $8810-$8813  (RX keyboard, TX echo)
;
; Screen layout:
;   Row 2:  "  **** 6502 SINGLE BOARD COMPUTER ****  "
;   Row 4:  " 4096 BYTES RAM     2048 BYTES ROM     "
;   Row 6:  "BEREIT."
;   Row 8:  "VIA-T1:  00"   (live tick counter, updated ~3Hz by ISR)
;   Row 9-24: input area (keyboard echo, wraps and clears on overflow)
;
; VIA Timer 1: free-running, period $FFFF (~1.3 ms @ 50 MHz).
; Every 256th IRQ (~330 ms): increment tick counter, update row 8, blink LED.
;
; Main loop: poll UART RX (status $8811 bit 3 = RDRF).
; On char received: echo back via TX ($8810 write), display on VIC screen.
; Backspace ($08/$7F) erases last char. CR/LF advances to next line.
; Input area wraps (clear + restart) when row 24 is full.
;
; Build:
;   ca65 --cpu 6502 -t none -l rom_demo.lst rom_demo.s -o rom_demo.o
;   ld65 -C rom_demo.cfg -o rom_demo.bin rom_demo.o -m rom_demo.map
;   python bin_to_fpga_hex.py rom_demo.bin 0xF800 0x0800 ../sim/rom_welcome.hex
; ============================================================

; ---- Hardware addresses ----
VIC_BASE    = $8000

VIA_ORB     = $8800
VIA_DDRB    = $8802
VIA_T1CL    = $8804
VIA_T1CH    = $8805
VIA_T1LL    = $8806
VIA_T1LH    = $8807
VIA_ACR     = $880B
VIA_IER     = $880E

UART_DATA   = $8810         ; read = RX byte (clears RDRF), write = TX byte
UART_STATUS = $8811         ; bit 3 = RDRF (data available), bit 4 = TDRE

; ---- Screen row addresses ----
ROW2        = VIC_BASE + 2 * 40     ; $8050
ROW4        = VIC_BASE + 4 * 40     ; $80A0
ROW6        = VIC_BASE + 6 * 40     ; $80F0
ROW8        = VIC_BASE + 8 * 40     ; $8140

; Input area: rows 9-24
INPUT_ROW   = VIC_BASE + 9 * 40     ; $8168 - first input row
INPUT_END   = VIC_BASE + 25 * 40    ; $83E8 - first byte past row 24

; Column offsets in row 8 for the tick counter: "VIA-T1:  00"
VIA_HI      = ROW8 + 9             ; $8149  high nibble
VIA_LO      = ROW8 + 10            ; $814A  low nibble

; ---- Zero page ----
ZP_FAST     = $00   ; ISR fast divider (wraps every 256 ~ 330 ms)
ZP_TICK     = $01   ; display tick counter
ZP_CUR_LO   = $02   ; cursor: VRAM row-start address low
ZP_CUR_HI   = $03   ; cursor: VRAM row-start address high
ZP_COL      = $04   ; cursor: current column (0-39)

; ============================================================
.segment "CODE"

; ============================================================
;  RESET  ($F800)
; ============================================================
reset:
    sei
    cld
    ldx     #$FF
    txs

    ; clear ZP variables
    lda     #$00
    sta     ZP_FAST
    sta     ZP_TICK
    sta     ZP_COL

    ; cursor starts at row 9 ($8168)
    lda     #<INPUT_ROW
    sta     ZP_CUR_LO
    lda     #>INPUT_ROW
    sta     ZP_CUR_HI

    ; VIA Port B: all output, start at $00
    lda     #$FF
    sta     VIA_DDRB
    lda     #$00
    sta     VIA_ORB

    ; VIA Timer 1: free-running, period $FFFF
    lda     #$40
    sta     VIA_ACR
    lda     #$FF
    sta     VIA_T1LL
    sta     VIA_T1LH
    sta     VIA_T1CH

    ; enable VIA Timer 1 IRQ
    lda     #$C0
    sta     VIA_IER

    ; draw welcome screen
    jsr     draw_screen

    ; clear input area (rows 9-24) and reset cursor
    jsr     clear_input

    ; start CPU interrupts
    cli

; ============================================================
;  MAIN LOOP — poll UART for keyboard input
; ============================================================
main_loop:
    lda     UART_STATUS
    and     #$08            ; RDRF bit
    beq     main_loop       ; no data

    lda     UART_DATA       ; read byte (clears RDRF)
    jsr     put_char        ; display on VIC
    jmp     main_loop

; ============================================================
;  IRQ HANDLER  (VIA Timer 1, ~750 Hz)
; ============================================================
irq_handler:
    pha
    txa
    pha

    lda     VIA_T1CL        ; clear T1 IRQ flag

    inc     ZP_FAST
    bne     irq_done        ; only act every 256th IRQ

    ; --- slow tick (~330 ms) ---
    inc     ZP_TICK

    ; toggle Port B bit 0 (LED blink)
    lda     VIA_ORB
    eor     #$01
    sta     VIA_ORB

    ; write high nibble of tick to row 8
    lda     ZP_TICK
    lsr
    lsr
    lsr
    lsr
    tax
    lda     hex_table, x
    sta     VIA_HI

    ; write low nibble of tick to row 8
    lda     ZP_TICK
    and     #$0F
    tax
    lda     hex_table, x
    sta     VIA_LO

irq_done:
    pla
    tax
    pla
    rti

; ============================================================
;  put_char — write char in A to VIC at cursor position
;  Handles: printable chars, CR ($0D), LF ($0A), BS ($08), DEL ($7F)
;  Modifies: A, X, Y, ZP_CUR_LO, ZP_CUR_HI, ZP_COL
; ============================================================
put_char:
    cmp     #$0D            ; CR
    beq     pc_newline
    cmp     #$0A            ; LF
    beq     pc_newline
    cmp     #$08            ; backspace
    beq     pc_backspace
    cmp     #$7F            ; DEL (alternate backspace)
    beq     pc_backspace
    cmp     #$20            ; printable?
    bcc     pc_done         ; ignore other control chars

    ; ---- write character at (ZP_CUR_HI:ZP_CUR_LO) + ZP_COL ----
    ldy     ZP_COL
    sta     (ZP_CUR_LO),y
    iny
    sty     ZP_COL
    cpy     #40             ; column overflow?
    bcc     pc_done

    ; column reached 40 -> implicit newline
pc_newline:
    lda     #$00
    sta     ZP_COL
    clc
    lda     ZP_CUR_LO
    adc     #40
    sta     ZP_CUR_LO
    bcc     pc_check_end
    inc     ZP_CUR_HI

pc_check_end:
    ; wrap if cursor >= INPUT_END ($83E8)
    lda     ZP_CUR_HI
    cmp     #>INPUT_END     ; compare high byte
    bcc     pc_done         ; < $83: still in range
    bne     pc_wrap         ; > $83: past end
    lda     ZP_CUR_LO
    cmp     #<INPUT_END     ; compare low byte
    bcc     pc_done         ; still in row 24
pc_wrap:
    jsr     clear_input     ; clear input area and reset cursor
    jmp     pc_done

    ; ---- backspace ----
pc_backspace:
    lda     ZP_COL
    beq     pc_bs_prev_row
    ; step back within current row
    dec     ZP_COL
    ldy     ZP_COL
    lda     #$20
    sta     (ZP_CUR_LO),y
    jmp     pc_done

pc_bs_prev_row:
    ; can't go before row 9
    lda     ZP_CUR_LO
    cmp     #<INPUT_ROW
    bne     pc_bs_go
    lda     ZP_CUR_HI
    cmp     #>INPUT_ROW
    beq     pc_done         ; already at top-left

pc_bs_go:
    sec
    lda     ZP_CUR_LO
    sbc     #40
    sta     ZP_CUR_LO
    bcs     pc_bs_no_borrow
    dec     ZP_CUR_HI
pc_bs_no_borrow:
    lda     #39
    sta     ZP_COL
    ldy     #39
    lda     #$20
    sta     (ZP_CUR_LO),y

pc_done:
    rts

; ============================================================
;  clear_input — clear rows 9-24 with spaces; reset cursor
;  Modifies: A, X, Y, ZP_CUR_LO, ZP_CUR_HI, ZP_COL
; ============================================================
clear_input:
    lda     #<INPUT_ROW
    sta     ZP_CUR_LO
    lda     #>INPUT_ROW
    sta     ZP_CUR_HI
    ldx     #16             ; 16 rows (9..24)

ci_row:
    ldy     #0
ci_col:
    lda     #$20
    sta     (ZP_CUR_LO),y
    iny
    cpy     #40
    bne     ci_col
    clc
    lda     ZP_CUR_LO
    adc     #40
    sta     ZP_CUR_LO
    bcc     ci_no_carry
    inc     ZP_CUR_HI
ci_no_carry:
    dex
    bne     ci_row

    ; reset cursor to row 9
    lda     #<INPUT_ROW
    sta     ZP_CUR_LO
    lda     #>INPUT_ROW
    sta     ZP_CUR_HI
    lda     #$00
    sta     ZP_COL
    rts

; ============================================================
;  draw_screen — write welcome rows 2/4/6/8 to VRAM
; ============================================================
draw_screen:
    ldx     #$00
ds_l2:
    lda     str_line2,x
    beq     ds_l4
    sta     ROW2,x
    inx
    bne     ds_l2

ds_l4:
    ldx     #$00
ds_l4_lp:
    lda     str_line4,x
    beq     ds_l6
    sta     ROW4,x
    inx
    bne     ds_l4_lp

ds_l6:
    ldx     #$00
ds_l6_lp:
    lda     str_line6,x
    beq     ds_l8
    sta     ROW6,x
    inx
    bne     ds_l6_lp

ds_l8:
    ldx     #$00
ds_l8_lp:
    lda     str_line8,x
    beq     ds_done
    sta     ROW8,x
    inx
    bne     ds_l8_lp

ds_done:
    rts

; ============================================================
;  READ-ONLY DATA
; ============================================================
.segment "RODATA"

str_line2:
    .byte "  **** 6502 SINGLE BOARD COMPUTER ****  ", $00
str_line4:
    .byte " 4096 BYTES RAM     2048 BYTES ROM     ", $00
str_line6:
    .byte "BEREIT.", $00
str_line8:
    .byte "VIA-T1:  00", $00

hex_table:
    .byte "0123456789ABCDEF"

; ============================================================
;  INTERRUPT VECTORS  ($FFFA-$FFFF)
; ============================================================
.segment "VECTORS"
    .word   reset
    .word   reset
    .word   irq_handler
