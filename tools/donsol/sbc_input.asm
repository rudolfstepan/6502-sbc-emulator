; SBC Keyboard Input Handler for Donsol
; Reads ASCII from VIA Port A keyboard FIFO and converts to Donsol button codes

; Keyboard mapping:
; a/Left arrow     -> BUTTON_LEFT  ($02)
; d/Right arrow    -> BUTTON_RIGHT ($01)
; w/Up arrow       -> BUTTON_UP    ($08)
; s/Down arrow     -> BUTTON_DOWN  ($04)
; Space/Enter      -> BUTTON_A     ($80) - confirm
; Backspace/q      -> BUTTON_B     ($40) - cancel
; e                -> BUTTON_SELECT ($20)
; p/Return         -> BUTTON_START ($10)

; --- Initialize Keyboard ---
init_keyboard:
    lda #$00
    sta VIA_DDRA              ; Set Port A as input
    
    lda #$00
    sta down_input
    sta kbd_key_pressed
    sta kbd_last_key
    
    rts

; --- Read Keyboard and convert to button codes ---
readJoy_sbc:
    lda #$00
    sta down_input
    
    ; Check if key available (VIA_IFR bit 1 = CA1)
    lda VIA_IFR
    and #$02                  ; Check CA1 flag
    beq readjoy_no_key
    
    ; Key available, read from VIA_ORA
    lda VIA_ORA
    sta kbd_key_pressed
    
    ; Convert ASCII to button code
    jsr convert_key_to_button
    sta down_input
    
readjoy_no_key:
    rts

; --- Convert ASCII key to Donsol button code ---
; Input: A = ASCII key code
; Output: A = button code (0 if no match)
convert_key_to_button:
    sta kbd_key_pressed
    
    ; Check for movement keys (WASD)
    cmp #$61                  ; 'a'
    beq convert_key_left
    cmp #$64                  ; 'd'
    beq convert_key_right
    cmp #$77                  ; 'w'
    beq convert_key_up
    cmp #$73                  ; 's'
    beq convert_key_down
    
    ; Check for action keys
    cmp #$20                  ; Space
    beq convert_key_a
    cmp #$0d                  ; Enter/Return
    beq convert_key_a
    
    cmp #$08                  ; Backspace
    beq convert_key_b
    cmp #$71                  ; 'q'
    beq convert_key_b
    
    cmp #$65                  ; 'e'
    beq convert_key_select
    
    cmp #$70                  ; 'p'
    beq convert_key_start
    
    ; No match
    lda #$00
    rts
    
convert_key_left:
    lda #BUTTON_LEFT
    rts
convert_key_right:
    lda #BUTTON_RIGHT
    rts
convert_key_up:
    lda #BUTTON_UP
    rts
convert_key_down:
    lda #BUTTON_DOWN
    rts
convert_key_a:
    lda #BUTTON_A
    rts
convert_key_b:
    lda #BUTTON_B
    rts
convert_key_select:
    lda #BUTTON_SELECT
    rts
convert_key_start:
    lda #BUTTON_START
    rts

; --- Debounce and store input ---
saveJoy_sbc:
    lda down_input
    cmp kbd_last_key
    beq savejoy_done
    
    sta kbd_last_key
    
    cmp #$00
    beq savejoy_done
    
    sta next_input
    
savejoy_done:
    rts
