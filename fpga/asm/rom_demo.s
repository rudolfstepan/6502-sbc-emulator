; ============================================================
; rom_demo.s  -  6502 SBC Minimal ROM with VIA + UART demo
;
; ROM: 2 KB at $F800-$FFFF (cpu_addr[10:0] indexing in FPGA)
; Reset entry:  $F800
; IRQ handler:  irq_handler (label, placed by linker)
;
; Hardware:
;   VIC text RAM  $8000-$87FF  (40x25 chars)
;   VIA 6522      $8800-$880F  (Timer 1 + Port B)
;   UART 6551     $8810-$8813  (TX only for demo)
;
; VIA Timer 1 is configured for free-running mode with period
; $FFFF (~1.3 ms at 50 MHz).  Every 256 IRQs (~330 ms) the ISR:
;   - increments the display tick counter
;   - writes two hex digits to VIC row 8
;   - sends the tick byte via UART TX
;   - toggles VIA Port B bit 0  (LED on PIX16 board)
;
; Build:
;   ca65 --cpu 6502 -t none -l rom_demo.lst rom_demo.s -o rom_demo.o
;   ld65 -C rom_demo.cfg -o rom_demo.bin rom_demo.o -m rom_demo.map
;   python bin_to_fpga_hex.py rom_demo.bin 0xF800 0x0800 ../sim/rom_welcome.hex
; ============================================================

; ---- Hardware addresses ----
VIC_BASE    = $8000

VIA_ORB     = $8800         ; Output Register B
VIA_DDRB    = $8802         ; Data Direction Register B
VIA_T1CL    = $8804         ; Timer 1 Counter Low  (read clears T1 IRQ flag)
VIA_T1CH    = $8805         ; Timer 1 Counter High (write loads latches & starts)
VIA_T1LL    = $8806         ; Timer 1 Latch Low
VIA_T1LH    = $8807         ; Timer 1 Latch High
VIA_ACR     = $880B         ; Auxiliary Control Register
VIA_IER     = $880E         ; Interrupt Enable Register

UART_DATA   = $8810         ; UART data register (write = TX)

; ---- Screen positions (VIC text RAM) ----
ROW2        = VIC_BASE + 2 * 40     ; $8050
ROW4        = VIC_BASE + 4 * 40     ; $80A0
ROW6        = VIC_BASE + 6 * 40     ; $80F0
ROW8        = VIC_BASE + 8 * 40     ; $8140

; Column offsets within row 8 for the live counters:
;   "VIA-T1:  00    UART:  00"
;              ^^ col 9-10       ^^ col 22-23
VIA_HI      = ROW8 + 9             ; $8149
VIA_LO      = ROW8 + 10            ; $814A
UART_HI     = ROW8 + 22            ; $8156
UART_LO     = ROW8 + 23            ; $8157

; ---- Zero page ----
ZP_FAST     = $00   ; fast ISR divider (wraps every 256 = ~330 ms trigger)
ZP_TICK     = $01   ; display / UART tick counter, incremented every ~330 ms

; ============================================================
.segment "CODE"

; ============================================================
;  RESET  ($F800)
; ============================================================
reset:
    sei
    cld
    ldx     #$FF
    txs                         ; initialise stack pointer

    ; clear zero-page counters
    lda     #$00
    sta     ZP_FAST
    sta     ZP_TICK

    ; VIA Port B: all pins output, start at $00
    lda     #$FF
    sta     VIA_DDRB
    lda     #$00
    sta     VIA_ORB

    ; VIA Timer 1: free-running mode, period = $FFFF
    ;   ACR bit 6 = 1  ->  T1 continuous free-running
    lda     #$40
    sta     VIA_ACR
    lda     #$FF
    sta     VIA_T1LL            ; latch low  = $FF
    sta     VIA_T1LH            ; latch high = $FF
    sta     VIA_T1CH            ; write T1CH -> load latches and start timer

    ; enable VIA Timer 1 interrupt  (IER bit 7 = set, bit 6 = T1)
    lda     #$C0
    sta     VIA_IER

    ; draw welcome screen
    jsr     draw_screen

    ; enable CPU interrupts and idle
    cli
halt:
    jmp     halt

; ============================================================
;  IRQ HANDLER  (VIA Timer 1, ~750 Hz at 50 MHz)
; ============================================================
irq_handler:
    pha                         ; save A
    txa
    pha                         ; save X (as A on stack)

    ; Reading T1CL clears the Timer 1 interrupt flag in IFR
    lda     VIA_T1CL

    ; increment fast divider; only act every 256th IRQ (~330 ms)
    inc     ZP_FAST
    bne     irq_done

    ; --- slow tick ---
    inc     ZP_TICK

    ; send tick byte via UART TX
    lda     ZP_TICK
    sta     UART_DATA

    ; toggle Port B bit 0 (LED blink on PIX16)
    lda     VIA_ORB
    eor     #$01
    sta     VIA_ORB

    ; write high nibble of tick to VIC (VIA column)
    lda     ZP_TICK
    lsr
    lsr
    lsr
    lsr
    tax
    lda     hex_table, x
    sta     VIA_HI              ; $8149

    ; write low nibble of tick to VIC (VIA column)
    lda     ZP_TICK
    and     #$0F
    tax
    lda     hex_table, x
    sta     VIA_LO              ; $814A

    ; mirror same value in the UART column of row 8
    lda     VIA_HI
    sta     UART_HI             ; $8156
    lda     VIA_LO
    sta     UART_LO             ; $8157

irq_done:
    pla
    tax                         ; restore X
    pla                         ; restore A
    rti

; ============================================================
;  SUBROUTINE: draw_screen
;  Writes four null-terminated strings to VIC VRAM rows 2/4/6/8
; ============================================================
draw_screen:
    ldx     #$00
draw_l2:
    lda     str_line2, x
    beq     draw_l4
    sta     ROW2, x
    inx
    bne     draw_l2

draw_l4:
    ldx     #$00
draw_l4_loop:
    lda     str_line4, x
    beq     draw_l6
    sta     ROW4, x
    inx
    bne     draw_l4_loop

draw_l6:
    ldx     #$00
draw_l6_loop:
    lda     str_line6, x
    beq     draw_l8
    sta     ROW6, x
    inx
    bne     draw_l6_loop

draw_l8:
    ldx     #$00
draw_l8_loop:
    lda     str_line8, x
    beq     draw_done
    sta     ROW8, x
    inx
    bne     draw_l8_loop

draw_done:
    rts

; ============================================================
;  READ-ONLY DATA
; ============================================================
.segment "RODATA"

; Screen text (null-terminated, 40 cols max)
str_line2:
    .byte "  **** 6502 SINGLE BOARD COMPUTER ****  ", $00
str_line4:
    .byte " 4096 BYTES RAM     2048 BYTES ROM     ", $00
str_line6:
    .byte "BEREIT.", $00

; Row 8: live counters at columns 9-10 (VIA) and 22-23 (UART)
;         0         1         2
;         0123456789012345678901234
str_line8:
    .byte "VIA-T1:  00    UART:  00", $00

; Hex digit lookup  (index 0-15 -> ASCII '0'-'F')
hex_table:
    .byte "0123456789ABCDEF"

; ============================================================
;  INTERRUPT VECTORS  ($FFFA-$FFFF)
; ============================================================
.segment "VECTORS"
    .word   reset           ; $FFFA  NMI  -> restart
    .word   reset           ; $FFFC  RESET
    .word   irq_handler     ; $FFFE  IRQ  -> timer ISR
