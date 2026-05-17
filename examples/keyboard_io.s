; ========================================
; Keyboard & VIC I/O Routines for 6502
; ========================================
; This file provides basic I/O routines for reading from
; the keyboard (via VIA6522) and writing to the VIC screen
;
; Hardware addresses:
;   VIA_BASE  = $8800  (VIA 6522)
;   VIC_RAM   = $8000  (Video RAM 40x25)
;
; VIA Registers (relative to VIA_BASE):
;   VIA_ORA   = $01    ; Port A data (keyboard input)
;   VIA_DDRA  = $03    ; Port A direction (0=input)
;   VIA_IFR   = $0D    ; Interrupt Flag Register
;   VIA_IER   = $0E    ; Interrupt Enable Register
;
; ========================================

VIA_BASE   = $8800
VIA_ORB    = VIA_BASE + $00
VIA_ORA    = VIA_BASE + $01
VIA_DDRB   = VIA_BASE + $02
VIA_DDRA   = VIA_BASE + $03
VIA_IFR    = VIA_BASE + $0D
VIA_IER    = VIA_BASE + $0E

VIC_RAM    = $8000
SCREEN_WIDTH  = 40
SCREEN_HEIGHT = 25

; Variables
CURSOR_POS = $20    ; 2 bytes: screen position (0-999)
CURSOR_X   = $22    ; cursor column (0-39)
CURSOR_Y   = $23    ; cursor row (0-24)

; ========================================
; INIT_IO - Initialize keyboard and video
; ========================================
init_io:
    ; Configure VIA Port A as input for keyboard
    lda #$00
    sta VIA_DDRA        ; All bits input
    
    ; Enable CA1 interrupt for keyboard
    lda #$82            ; Set bit 7 (enable) + bit 1 (CA1)
    sta VIA_IER
    
    ; Clear screen
    jsr clear_screen
    
    ; Initialize cursor
    lda #$00
    sta CURSOR_X
    sta CURSOR_Y
    sta CURSOR_POS
    sta CURSOR_POS+1
    
    rts

; ========================================
; CLEAR_SCREEN - Fill VIC RAM with spaces
; ========================================
clear_screen:
    lda #$20            ; Space character
    ldx #$00
    ldy #$00
.loop:
    sta VIC_RAM,x
    inx
    bne .loop
    iny
    sta VIC_RAM+$100,x
    inx
    bne .loop+3
    cpy #$08            ; 2KB = 8 x 256
    bne .loop
    rts

; ========================================
; GETCHAR - Read character from keyboard
; ========================================
; Returns: A = ASCII character (0 if none)
;          Carry set if character available
; ========================================
getchar:
    lda VIA_IFR         ; Check if CA1 interrupt flag set
    and #$02            ; Bit 1 = CA1
    beq .no_char        ; No character available
    
    lda VIA_ORA         ; Read character from Port A
    sec                 ; Set carry (character available)
    rts
    
.no_char:
    lda #$00
    clc                 ; Clear carry (no character)
    rts

; ========================================
; PUTCHAR - Write character to VIC screen
; ========================================
; Input: A = ASCII character
; ========================================
putchar:
    cmp #$0D            ; Carriage return?
    beq .newline
    cmp #$0A            ; Line feed?
    beq .newline
    cmp #$08            ; Backspace?
    beq .backspace
    
    ; Normal character - write to screen
    pha                 ; Save character
    
    ; Calculate screen address
    lda CURSOR_Y
    ldx #SCREEN_WIDTH
    jsr multiply        ; A = Y * 40
    clc
    adc CURSOR_X
    sta CURSOR_POS
    lda #$00
    adc #$00
    sta CURSOR_POS+1
    
    ; Write character
    pla                 ; Restore character
    ldy #$00
    sta (CURSOR_POS),y
    
    ; Advance cursor
    inc CURSOR_X
    lda CURSOR_X
    cmp #SCREEN_WIDTH
    bcc .done
    
.newline:
    lda #$00
    sta CURSOR_X
    inc CURSOR_Y
    lda CURSOR_Y
    cmp #SCREEN_HEIGHT
    bcc .done
    jsr scroll_up
    lda #SCREEN_HEIGHT-1
    sta CURSOR_Y
    
.done:
    rts

.backspace:
    lda CURSOR_X
    beq .done           ; At start of line, ignore
    dec CURSOR_X
    lda #$20            ; Write space
    jsr putchar
    dec CURSOR_X        ; Back to position
    rts

; ========================================
; PRINT_STRING - Print null-terminated string
; ========================================
; Input: X,Y = pointer to string (low, high)
; ========================================
print_string:
    stx CURSOR_POS
    sty CURSOR_POS+1
    ldy #$00
.loop:
    lda (CURSOR_POS),y
    beq .done
    jsr putchar
    iny
    bne .loop
.done:
    rts

; ========================================
; SCROLL_UP - Scroll screen up one line
; ========================================
scroll_up:
    ldx #$00
.loop:
    lda VIC_RAM+SCREEN_WIDTH,x
    sta VIC_RAM,x
    inx
    cpx #(SCREEN_WIDTH*24)
    bne .loop
    
    ; Clear last line
    lda #$20
    ldx #$00
.clear:
    sta VIC_RAM+(SCREEN_WIDTH*24),x
    inx
    cpx #SCREEN_WIDTH
    bne .clear
    rts

; ========================================
; MULTIPLY - Simple 8-bit multiplication
; ========================================
; Input: A = multiplicand, X = multiplier
; Output: A = result (low byte only)
; ========================================
multiply:
    sta CURSOR_POS      ; Temporary storage
    lda #$00
.loop:
    dex
    bmi .done
    clc
    adc CURSOR_POS
    jmp .loop
.done:
    rts

; ========================================
; Example: Simple keyboard echo loop
; ========================================
; This demonstrates how to use the I/O routines
; ========================================
keyboard_echo:
    jsr init_io
    
.loop:
    jsr getchar
    bcc .loop           ; No character, keep waiting
    
    jsr putchar         ; Echo to screen
    
    cmp #$1B            ; ESC key?
    bne .loop
    
    rts                 ; Return on ESC

; ========================================
; End of I/O routines
; ========================================
