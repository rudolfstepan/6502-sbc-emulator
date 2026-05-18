; Donsol SBC - Main Loop
; Adapted for 6502 SBC with text mode display and keyboard input

.include "sbc_head.asm"

; --- Reset Vector (Entry Point) ---
.org $8000

reset:
    sei                       ; Disable interrupts
    cld                       ; Clear decimal mode
    ldx #$ff
    txs                       ; Set stack pointer to $1FF
    
    jsr init_game_state
    jsr init_keyboard
    jsr init_video
    
    jmp main_loop

; --- Initialize Game State ---
init_game_state:
    lda #$03
    sta hp_player             ; Start with 3 HP
    lda #$00
    sta sp_player             ; 0 shield
    sta xp_player             ; 0 XP
    sta difficulty_player
    
    lda #$52                  ; 82 cards in deck
    sta length_deck
    lda #$00
    sta hand_deck
    
    lda #$00
    sta view_game
    
    lda #$ff
    sta redraws_game
    
    rts

; --- Main Game Loop ---
main_loop:
    jsr handle_timer
    
    jsr readJoy_sbc
    jsr saveJoy_sbc
    
    jsr check_joy
    
    jsr update_game_state
    
    jsr render_screen
    
    jmp main_loop

; --- Handle Auto-Resolution Timer ---
handle_timer:
    lda auto_room
    cmp #$01
    bne timer_skip
    dec auto_room
timer_skip:
    rts

; --- Check Joy and Route Input ---
check_joy:
    lda next_input
    cmp #$00
    beq check_joy_skip
    
    ldx view_game
    cpx #$00
    bne check_joy_game_view
    
    jsr handle_splash_input
    jmp check_joy_done
    
check_joy_game_view:
    jsr handle_game_input
    
check_joy_done:
    lda #$00
    sta next_input
check_joy_skip:
    rts

; --- Handle Splash Screen Input ---
handle_splash_input:
    lda next_input
    
    cmp #BUTTON_LEFT
    beq splash_move_left
    
    cmp #BUTTON_RIGHT
    beq splash_move_right
    
    cmp #BUTTON_A
    beq splash_select_option
    
    rts
    
splash_move_left:
    dec cursor_splash
    lda cursor_splash
    cmp #$ff
    bne splash_draw
    lda #$02
    sta cursor_splash
splash_draw:
    lda #$01
    sta reqdraw_splash
    rts
    
splash_move_right:
    inc cursor_splash
    lda cursor_splash
    cmp #$03
    bne splash_draw
    lda #$00
    sta cursor_splash
    jmp splash_draw
    
splash_select_option:
    lda #$01
    sta view_game
    lda #$ff
    sta redraws_game
    rts

; --- Handle Game Input ---
handle_game_input:
    lda next_input
    
    cmp #BUTTON_LEFT
    beq game_left_pressed
    
    cmp #BUTTON_RIGHT
    beq game_right_pressed
    
    cmp #BUTTON_A
    beq game_a_pressed
    
    cmp #BUTTON_B
    beq game_b_pressed
    
    cmp #BUTTON_SELECT
    beq game_select_pressed
    
    rts
    
game_left_pressed:
    rts
    
game_right_pressed:
    rts
    
game_a_pressed:
    rts
    
game_b_pressed:
    rts
    
game_select_pressed:
    rts

; --- Update Game State ---
update_game_state:
    rts

; --- Render Screen ---
render_screen:
    ldx view_game
    cpx #$00
    bne render_game
    
    jsr render_splash_screen
    jmp render_done
    
render_game:
    jsr render_game_screen
    
render_done:
    rts

; --- Render Splash Screen ---
render_splash_screen:
    lda redraws_game
    and #REQ_HP
    beq render_splash_done
    
    jsr draw_splash_screen
    
render_splash_done:
    rts

; --- Render Game Screen ---
render_game_screen:
    lda redraws_game
    and #REQ_HP
    beq render_skip_hp
    jsr update_hp_display
render_skip_hp:
    
    lda redraws_game
    and #REQ_SP
    beq render_skip_sp
    jsr update_sp_display
render_skip_sp:
    
    lda redraws_game
    and #REQ_CARD1
    beq render_skip_card1
    jsr update_card1_display
render_skip_card1:
    
    rts

; --- Update placeholders ---

update_card1_display:
    rts

; --- Include I/O modules ---
.include "sbc_input.asm"
.include "sbc_video.asm"

; --- Interrupt vectors at $FFFA ---
.segment "VECTORS"
.addr $0000               ; NMI at $FFFA
.addr reset               ; RESET at $FFFC
.addr $0000               ; IRQ/BRK at $FFFE
