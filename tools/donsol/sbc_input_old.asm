; SBC Keyboard Input Handler for Donsol
; Reads ASCII from VIA Port A keyboard FIFO and converts to Donsol button codes
; 
; Keyboard mapping:
; A/Left arrow     -> BUTTON_LEFT  ($02)
; D/Right arrow    -> BUTTON_RIGHT ($01)
; W/Up arrow       -> BUTTON_UP    ($08)
; S/Down arrow     -> BUTTON_DOWN  ($04)
; Space/Enter      -> BUTTON_A     ($80) - confirm
; Backspace/Q      -> BUTTON_B     ($40) - cancel
; E                -> BUTTON_SELECT ($20)
; Return/P         -> BUTTON_START ($10)

; --- Initialize Keyboard ---
init_keyboard:
    ; Configure VIA Port A as input (0x00 = all bits input)
    LDA #$00
    STA VIA_DDRA
    
    ; Clear key state
    LDA #$00
    STA down@input
    STA kbd_key_pressed
    STA kbd_last_key
    
    RTS

; --- Read Keyboard and convert to Donsol buttons ---
; Checks VIA IFR bit 1 (CA1) for key available, reads from ORA
readJoy_sbc:
    LDA #$00
    STA down@input
    
    ; Check if key is available (VIA_IFR bit 1 = CA1)
    LDA VIA_IFR
    AND #$02                 ; Check CA1 flag
    BEQ @no_key
    
    ; Key available, read from VIA_ORA
    LDA VIA_ORA
    STA kbd_key_pressed
    
    ; Convert ASCII to button code
    JSR convert_key_to_button
    STA down@input
    
@no_key:
    RTS

; --- Convert ASCII key to Donsol button code ---
; Input: A = ASCII key code
; Output: A = button code (0 if no match)
convert_key_to_button:
    ; Save original key
    STA kbd_key_pressed
    
    ; Check for movement keys (WASD or arrows)
    CMP #$61                 ; 'a'
    BEQ @key_left
    CMP #$64                 ; 'd'
    BEQ @key_right
    CMP #$77                 ; 'w'
    BEQ @key_up
    CMP #$73                 ; 's'
    BEQ @key_down
    
    ; Check for action keys
    CMP #$20                 ; Space
    BEQ @key_a
    CMP #$0D                 ; Enter/Return
    BEQ @key_a
    
    CMP #$08                 ; Backspace
    BEQ @key_b
    CMP #$71                 ; 'q'
    BEQ @key_b
    
    CMP #$65                 ; 'e'
    BEQ @key_select
    
    CMP #$70                 ; 'p'
    BEQ @key_start
    
    ; No match
    LDA #$00
    RTS
    
@key_left:
    LDA #BUTTON_LEFT
    RTS
@key_right:
    LDA #BUTTON_RIGHT
    RTS
@key_up:
    LDA #BUTTON_UP
    RTS
@key_down:
    LDA #BUTTON_DOWN
    RTS
@key_a:
    LDA #BUTTON_A
    RTS
@key_b:
    LDA #BUTTON_B
    RTS
@key_select:
    LDA #BUTTON_SELECT
    RTS
@key_start:
    LDA #BUTTON_START
    RTS

; --- Debounce and store input ---
saveJoy_sbc:
    LDA down@input
    CMP kbd_last_key
    BEQ @done
    
    ; Key state changed
    STA kbd_last_key
    
    CMP #$00
    BEQ @done
    
    ; Non-zero key press - store for game logic
    STA next@input
    
@done:
    RTS
