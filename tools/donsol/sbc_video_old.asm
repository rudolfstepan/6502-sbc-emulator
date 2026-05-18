; SBC Video Output Handler for Donsol
; Uses text mode ($8000, 40x25) for display

; --- Initialize Video ---
init_video:
    ; For SBC, text mode is the default
    ; Just clear the screen to start
    JSR clear_screen
    RTS

; --- Clear Screen (fill with spaces) ---
clear_screen:
    LDA #$20                  ; Space character (ASCII 32)
    LDX #$00
    LDY #$00
    
@clear_page1:
    ; Clear first 256 bytes
    STA VIC_SCREEN_BASE,X
    INX
    BNE @clear_page1
    
    ; Clear remaining pages (40*25 = 1000 bytes = ~4 pages)
    ; VIC_SCREEN_BASE + $0100 through $03E8
    LDA #$20
    LDX #$00
    
@clear_page2:
    STA VIC_SCREEN_BASE+$100,X
    INX
    BNE @clear_page2
    
    LDA #$20
    LDX #$00
    
@clear_page3:
    STA VIC_SCREEN_BASE+$200,X
    INX
    BNE @clear_page3
    
    LDA #$20
    LDX #$00
    
@clear_page4:
    CMP #$E8                  ; Stop at 1000 bytes (0x3E8)
    BCS @done
    STA VIC_SCREEN_BASE+$300,X
    INX
    BNE @clear_page4
    
@done:
    RTS

; --- Print character at screen position ---
; Input: A = character code
;        X = column (0-39)
;        Y = row (0-24)
; Clobbers: A, X, Y
print_char:
    ; Calculate offset: offset = row * 40 + col
    ; Y * 40 + X
    
    ; Save A (char), X (col)
    PHA
    TXA
    PHA
    
    ; offset = Y * 40
    TYA
    ASL A                     ; Y * 2
    ASL A                     ; Y * 4
    ASL A                     ; Y * 8
    ASL A                     ; Y * 16
    ASL A                     ; Y * 32
    
    ; Add Y * 8 to get Y * 40
    TAX
    TYA
    ASL A
    ASL A
    ASL A
    TAY
    TXA
    CLC
    ADC #$00                  ; Will use indexed addressing
    
    ; Restore column
    PLA
    TAX
    
    ; Calculate full address
    TAX
    CLC
    ADC #$00
    TAX
    
    ; Restore character
    PLA
    
    ; Write to screen
    STA VIC_SCREEN_BASE,X
    RTS

; --- Print hex digit as character ---
; Input: A = value 0-15
; Output: A = ASCII character ('0'-'9' or 'A'-'F')
hex_to_ascii:
    CMP #$0A
    BCS @letter
    
    ; Digit 0-9
    CLC
    ADC #$30                  ; Add '0' ($30)
    RTS
    
@letter:
    ; Letter A-F
    CLC
    ADC #$37                  ; $0A->$41 ('A'), etc
    RTS

; --- Print decimal number (0-99) ---
; Input: A = value (0-99)
;        X = column (0-39)
;        Y = row (0-24)
print_decimal_2digit:
    PHA
    
    ; Divide by 10 for tens digit
    LDA #$00
    LDX #$0A
    
@divide_loop:
    SEC
    SBC #$0A
    CMP #$0A
    BCS @divide_loop
    
    ; ... incomplete, need proper BCD conversion
    PLA
    RTS

; --- Draw splash screen (title/menu) ---
draw_splash_screen:
    ; Clear screen first
    JSR clear_screen
    
    ; Display title: "DONSOL"
    ; Row 2, col 17 (center-ish)
    LDA #$44                  ; 'D'
    LDX #$11
    LDY #$02
    JSR print_char
    
    LDA #$4F                  ; 'O'
    LDX #$12
    LDY #$02
    JSR print_char
    
    LDA #$4E                  ; 'N'
    LDX #$13
    LDY #$02
    JSR print_char
    
    LDA #$53                  ; 'S'
    LDX #$14
    LDY #$02
    JSR print_char
    
    LDA #$4F                  ; 'O'
    LDX #$15
    LDY #$02
    JSR print_char
    
    LDA #$4C                  ; 'L'
    LDX #$16
    LDY #$02
    JSR print_char
    
    ; Display menu options
    ; > START
    LDA #$3E                  ; '>'
    LDX #$08
    LDY #$12
    JSR print_char
    
    LDA #$53                  ; 'S'
    LDX #$0A
    LDY #$12
    JSR print_char
    
    LDA #$54                  ; 'T'
    LDX #$0B
    LDY #$12
    JSR print_char
    
    LDA #$41                  ; 'A'
    LDX #$0C
    LDY #$12
    JSR print_char
    
    LDA #$52                  ; 'R'
    LDX #$0D
    LDY #$12
    JSR print_char
    
    LDA #$54                  ; 'T'
    LDX #$0E
    LDY #$12
    JSR print_char
    
    RTS

; --- Draw game screen (during gameplay) ---
draw_game_screen:
    ; Display player stats at top
    ; HP: 3/3  SP: 0/0  XP: 0/100
    
    ; Display card slots
    ; [A] [B] [C] [D]
    
    RTS

; --- Update HP Display ---
update_hp_display:
    ; Display HP at a fixed location
    ; Format: "HP: X/3"
    
    RTS

; --- Update SP Display ---
update_sp_display:
    ; Display SP at a fixed location
    ; Format: "SP: X/X"
    
    RTS

; --- Update XP Display ---
update_xp_display:
    ; Display XP at a fixed location
    ; Format: "XP: XXX"
    
    RTS

; --- Update card display ---
update_card_display:
    ; Show the 4 card slots with their values
    RTS
