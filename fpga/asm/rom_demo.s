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
UART_RDRF   = $08
UART_TDRE   = $10

; ---- Screen row addresses ----
ROW0        = VIC_BASE + 0 * 40     ; $8000
ROW1        = VIC_BASE + 1 * 40     ; $8028
ROW2        = VIC_BASE + 2 * 40     ; $8050
ROW3        = VIC_BASE + 3 * 40     ; $8078
ROW4        = VIC_BASE + 4 * 40     ; $80A0
ROW5        = VIC_BASE + 5 * 40     ; $80C8
ROW6        = VIC_BASE + 6 * 40     ; $80F0
ROW7        = VIC_BASE + 7 * 40     ; $8118
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
ZP_STR_LO   = $05   ; print_str source pointer low
ZP_STR_HI   = $06   ; print_str source pointer high
ZP_TMP      = $07   ; self-test scratch/save byte

; ---- Self-test probe addresses ----
RAM_PROBE   = $0200
STK_PROBE   = $0180
VRAM_PROBE  = INPUT_ROW

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

    ; send reset/debug state to host console before interrupts start
    jsr     print_debug
    jsr     system_check

    ; start CPU interrupts
    cli

; ============================================================
;  MAIN LOOP — poll UART for keyboard input
; ============================================================
main_loop:
    lda     UART_STATUS
    and     #UART_RDRF
    beq     main_loop       ; no data

    lda     UART_DATA       ; read byte (clears RDRF)
    jsr     put_char        ; display on VIC
    jmp     main_loop

; ============================================================
;  UART DEBUG OUTPUT
; ============================================================

print_char:
    pha
pd_tdre:
    lda     UART_STATUS
    and     #UART_TDRE
    beq     pd_tdre
    pla
    sta     UART_DATA
    rts

print_crlf:
    lda     #$0D
    jsr     print_char
    lda     #$0A
    jmp     print_char

print_str:
    ldy     #$00
ps_loop:
    lda     (ZP_STR_LO),y
    beq     ps_done
    jsr     print_char
    iny
    bne     ps_loop
ps_done:
    rts

print_hex:
    pha
    lsr
    lsr
    lsr
    lsr
    tax
    lda     hex_table,x
    jsr     print_char
    pla
    and     #$0F
    tax
    lda     hex_table,x
    jmp     print_char

print_msg:
    sta     ZP_STR_LO
    stx     ZP_STR_HI
    jmp     print_str

print_debug:
    lda     UART_STATUS
    pha

    lda     #<str_dbg_reset
    ldx     #>str_dbg_reset
    jsr     print_msg

    lda     #<str_dbg_map
    ldx     #>str_dbg_map
    jsr     print_msg

    lda     #<str_dbg_uart
    ldx     #>str_dbg_uart
    jsr     print_msg
    pla
    jsr     print_hex
    jsr     print_crlf

    lda     #<str_dbg_via
    ldx     #>str_dbg_via
    jsr     print_msg
    lda     VIA_ACR
    jsr     print_hex
    lda     #<str_dbg_ier
    ldx     #>str_dbg_ier
    jsr     print_msg
    lda     VIA_IER
    jsr     print_hex
    lda     #<str_dbg_t1
    ldx     #>str_dbg_t1
    jsr     print_msg

    lda     #<str_dbg_zp
    ldx     #>str_dbg_zp
    jsr     print_msg
    lda     ZP_FAST
    jsr     print_hex
    lda     #$20
    jsr     print_char
    lda     ZP_TICK
    jsr     print_hex
    lda     #$20
    jsr     print_char
    lda     ZP_CUR_HI
    jsr     print_hex
    lda     ZP_CUR_LO
    jsr     print_hex
    lda     #$20
    jsr     print_char
    lda     ZP_COL
    jsr     print_hex
    jsr     print_crlf

    lda     #<str_dbg_ready
    ldx     #>str_dbg_ready
    jmp     print_msg

; ============================================================
;  RESET SYSTEM CHECK
; ============================================================

system_check:
    lda     #<str_chk_head
    ldx     #>str_chk_head
    jsr     print_msg
    jsr     check_zp
    jsr     check_stack
    jsr     check_ram
    jsr     check_vram
    jsr     check_via
    jsr     check_uart
    lda     #<str_chk_done
    ldx     #>str_chk_done
    jmp     print_msg

print_ok:
    lda     #<str_ok
    ldx     #>str_ok
    jmp     print_msg

print_fail:
    lda     #<str_fail
    ldx     #>str_fail
    jmp     print_msg

check_zp:
    lda     #<str_chk_zp
    ldx     #>str_chk_zp
    jsr     print_msg
    ldx     ZP_TMP
    lda     #$AA
    sta     ZP_TMP
    cmp     ZP_TMP
    bne     chk_zp_fail
    lda     #$55
    sta     ZP_TMP
    cmp     ZP_TMP
    bne     chk_zp_fail
    stx     ZP_TMP
    jmp     print_ok
chk_zp_fail:
    stx     ZP_TMP
    jmp     print_fail

check_stack:
    lda     #<str_chk_stack
    ldx     #>str_chk_stack
    jsr     print_msg
    ldx     STK_PROBE
    lda     #$AA
    sta     STK_PROBE
    cmp     STK_PROBE
    bne     chk_stack_fail
    lda     #$55
    sta     STK_PROBE
    cmp     STK_PROBE
    bne     chk_stack_fail
    stx     STK_PROBE
    jmp     print_ok
chk_stack_fail:
    stx     STK_PROBE
    jmp     print_fail

check_ram:
    lda     #<str_chk_ram
    ldx     #>str_chk_ram
    jsr     print_msg
    ldx     RAM_PROBE
    lda     #$AA
    sta     RAM_PROBE
    cmp     RAM_PROBE
    bne     chk_ram_fail
    lda     #$55
    sta     RAM_PROBE
    cmp     RAM_PROBE
    bne     chk_ram_fail
    stx     RAM_PROBE
    jmp     print_ok
chk_ram_fail:
    stx     RAM_PROBE
    jmp     print_fail

check_vram:
    lda     #<str_chk_vram
    ldx     #>str_chk_vram
    jsr     print_msg
    ldx     VRAM_PROBE
    lda     #$AA
    sta     VRAM_PROBE
    cmp     VRAM_PROBE
    bne     chk_vram_fail
    lda     #$55
    sta     VRAM_PROBE
    cmp     VRAM_PROBE
    bne     chk_vram_fail
    stx     VRAM_PROBE
    jmp     print_ok
chk_vram_fail:
    stx     VRAM_PROBE
    jmp     print_fail

check_via:
    lda     #<str_chk_via
    ldx     #>str_chk_via
    jsr     print_msg
    lda     VIA_ACR
    cmp     #$40
    bne     chk_via_fail
    lda     VIA_IER
    cmp     #$C0
    bne     chk_via_fail
    lda     VIA_DDRB
    cmp     #$FF
    bne     chk_via_fail
    jmp     print_ok
chk_via_fail:
    jmp     print_fail

check_uart:
    lda     #<str_chk_uart
    ldx     #>str_chk_uart
    jsr     print_msg
    lda     UART_STATUS
    and     #$80
    bne     chk_uart_fail
    jmp     print_ok
chk_uart_fail:
    jmp     print_fail

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
;  draw_screen — write welcome rows to VRAM
;  Row 0, 3, 5, 7: cleared to spaces (no stray '@' from uninit VRAM)
;  Row 1: PETSCII block-graphics demo, codes $60-$7F at cols 4-35
;  Row 2, 4, 6, 8: text strings
; ============================================================
draw_screen:
    ; --- clear all header rows 0-8 with spaces so no 0x00/@-artefacts remain ---
    ldx     #39
    lda     #$20
ds_clr:
    sta     ROW0,x
    sta     ROW1,x
    sta     ROW2,x
    sta     ROW3,x
    sta     ROW4,x
    sta     ROW5,x
    sta     ROW6,x
    sta     ROW7,x
    sta     ROW8,x
    dex
    bpl     ds_clr

    ; --- PETSCII graphics: codes $60-$7F at row 1, cols 4-35 ---
    lda     #$60
    ldx     #4
ds_gfx:
    sta     ROW1,x
    inx
    clc
    adc     #1
    cmp     #$80
    bne     ds_gfx

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

str_dbg_reset:
    .byte $0D,$0A,"[RESET] 6502 SBC DEBUG",$0D,$0A
    .byte "CPU=T65  MODE=6502  IRQ=OFF",$0D,$0A
    .byte "CLK=50MHz  ROM=F800-FFFF",$0D,$0A,$00
str_dbg_map:
    .byte "MAP ZP/STK=0000-01FF RAM=0200+",$0D,$0A
    .byte "    VRAM=8000-87FF VIA=8800 UART=8810",$0D,$0A,$00
str_dbg_uart:
    .byte "UART ST=$",$00
str_dbg_via:
    .byte "VIA  ACR=$",$00
str_dbg_ier:
    .byte " IER=$",$00
str_dbg_t1:
    .byte " T1=$FFFF",$0D,$0A,$00
str_dbg_zp:
    .byte "ZP FAST TICK CUR COL = $",$00
str_dbg_ready:
    .byte "DEBUG DONE",$0D,$0A,$00

str_chk_head:
    .byte "SYS CHECK",$0D,$0A,$00
str_chk_zp:
    .byte "  ZP   ",$00
str_chk_stack:
    .byte "  STK  ",$00
str_chk_ram:
    .byte "  RAM  ",$00
str_chk_vram:
    .byte "  VRAM ",$00
str_chk_via:
    .byte "  VIA  ",$00
str_chk_uart:
    .byte "  UART ",$00
str_ok:
    .byte "OK",$0D,$0A,$00
str_fail:
    .byte "FAIL",$0D,$0A,$00
str_chk_done:
    .byte "CHECK DONE, CLI NEXT",$0D,$0A,$0D,$0A,$00

hex_table:
    .byte "0123456789ABCDEF"

; ============================================================
;  INTERRUPT VECTORS  ($FFFA-$FFFF)
; ============================================================
.segment "VECTORS"
    .word   reset
    .word   reset
    .word   irq_handler
