; VIC Test Program for 6502
; 
; This program demonstrates how to use the VIC (Video Interface Controller)
; from 6502 assembly language.
;
; VIC Video RAM: $8000-$87FF (2KB)
; Screen: 40 columns x 25 rows
;
; Assemble with:
;   ca65 vic_test.s -o vic_test.o
;   ld65 vic_test.o -o vic_test.bin

.org $1000              ; Start at $1000

; Constants
VIC_BASE   = $8000      ; Video RAM base address
SCREEN_WIDTH = 40       ; Characters per row

start:
    ; Clear screen (fill with spaces)
    LDX #$00
    LDA #$20            ; Space character
clear_loop:
    STA VIC_BASE,X
    STA VIC_BASE+$100,X
    STA VIC_BASE+$200,X
    STA VIC_BASE+$300,X
    INX
    BNE clear_loop
    
    ; Write "HELLO, VIC!" at position (0,0)
    LDX #$00
    LDA #'H'
    STA VIC_BASE,X
    INX
    LDA #'E'
    STA VIC_BASE,X
    INX
    LDA #'L'
    STA VIC_BASE,X
    INX
    LDA #'L'
    STA VIC_BASE,X
    INX
    LDA #'O'
    STA VIC_BASE,X
    INX
    LDA #','
    STA VIC_BASE,X
    INX
    LDA #' '
    STA VIC_BASE,X
    INX
    LDA #'V'
    STA VIC_BASE,X
    INX
    LDA #'I'
    STA VIC_BASE,X
    INX
    LDA #'C'
    STA VIC_BASE,X
    INX
    LDA #'!'
    STA VIC_BASE,X
    
    ; Write "6502 RULES" at row 2 (offset = 2 * 40 = 80 = $50)
    LDX #$00
write_row2:
    LDA msg_6502,X
    BEQ done_row2       ; Stop at null terminator
    STA VIC_BASE+$50,X
    INX
    BNE write_row2
done_row2:
    
    ; Draw a horizontal line at row 5
    LDX #$00
draw_line:
    LDA #'-'
    STA VIC_BASE+(5*40),X
    INX
    CPX #40
    BNE draw_line
    
    ; Write centered message at row 10
    ; "*** VIC INITIALIZED ***"
    LDX #$00
write_center:
    LDA msg_center,X
    BEQ done_center
    STA VIC_BASE+(10*40)+8,X  ; Offset 8 for centering
    INX
    BNE write_center
done_center:
    
    ; Fill row 24 with character codes
    LDX #$00
fill_chars:
    TXA
    CLC
    ADC #$41            ; Start with 'A'
    STA VIC_BASE+(24*40),X
    INX
    CPX #26             ; 26 letters
    BNE fill_chars
    
    ; Infinite loop
loop:
    JMP loop

; Data
msg_6502:
    .byte "6502 RULES", 0

msg_center:
    .byte "*** VIC INITIALIZED ***", 0
