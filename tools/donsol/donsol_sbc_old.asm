; Donsol SBC - Main Loop
; Adapted for 6502 SBC with text mode display and keyboard input

.include "sbc_head.asm"

; --- Reset Vector (Entry Point) ---
.org $8000

reset:
    ; Initialize stack and CPU
    SEI                       ; Disable interrupts
    CLD                       ; Clear decimal mode
    LDX #$FF
    TXS                       ; Set stack pointer to $1FF
    
    ; Initialize game state
    JSR init_game_state
    JSR init_keyboard
    JSR init_video
    
    ; Main game loop
    JMP main_loop

; --- Initialize Game State ---
init_game_state:
    ; Set up player
    LDA #$03
    STA hp@player             ; Start with 3 HP
    LDA #$00
    STA sp@player             ; 0 shield
    STA xp@player             ; 0 XP
    STA difficulty@player
    
    ; Set up deck
    LDA #$52                  ; 82 cards in deck
    STA length@deck
    LDA #$00
    STA hand@deck
    
    ; Set view to splash screen
    LDA #$00
    STA view@game
    
    ; Initialize redraw flags
    LDA #$FF
    STA redraws@game
    
    RTS

; --- Main Game Loop ---
main_loop:
    ; 1. Handle timers
    JSR handle_timer
    
    ; 2. Read keyboard input
    JSR readJoy_sbc
    JSR saveJoy_sbc
    
    ; 3. Process input
    JSR check_joy
    
    ; 4. Update game logic
    JSR update_game_state
    
    ; 5. Render screen
    JSR render_screen
    
    ; 6. Loop
    JMP main_loop

; --- Handle Auto-Resolution Timer ---
handle_timer:
    LDA auto@room
    CMP #$01
    BNE @skip
    DEC auto@room
    ; Call post-flip actions if needed
@skip:
    RTS

; --- Check Joy and Route Input ---
check_joy:
    LDA next@input
    CMP #$00
    BEQ @skip
    
    ; Route based on current view
    LDX view@game
    CPX #$00
    BNE @game_view
    
    ; Splash screen input
    JSR handle_splash_input
    JMP @done
    
@game_view:
    ; Game input
    JSR handle_game_input
    
@done:
    LDA #$00
    STA next@input
@skip:
    RTS

; --- Handle Splash Screen Input ---
handle_splash_input:
    LDA next@input
    
    ; LEFT - cursor back
    CMP #BUTTON_LEFT
    BEQ @move_left
    
    ; RIGHT - cursor forward
    CMP #BUTTON_RIGHT
    BEQ @move_right
    
    ; A button - select
    CMP #BUTTON_A
    BEQ @select_option
    
    RTS
    
@move_left:
    DEC cursor@splash
    LDA cursor@splash
    CMP #$FF
    BNE @draw
    LDA #$02
    STA cursor@splash
@draw:
    LDA #$01
    STA reqdraw_splash
    RTS
    
@move_right:
    INC cursor@splash
    LDA cursor@splash
    CMP #$03
    BNE @draw
    LDA #$00
    STA cursor@splash
    JMP @draw
    
@select_option:
    ; Start game
    LDA #$01
    STA view@game
    LDA #$FF
    STA redraws@game
    RTS

; --- Handle Game Input ---
handle_game_input:
    LDA next@input
    
    CMP #BUTTON_LEFT
    BEQ @left_pressed
    
    CMP #BUTTON_RIGHT
    BEQ @right_pressed
    
    CMP #BUTTON_A
    BEQ @a_pressed
    
    CMP #BUTTON_B
    BEQ @b_pressed
    
    CMP #BUTTON_SELECT
    BEQ @select_pressed
    
    RTS
    
@left_pressed:
    ; Move cursor left or previous card
    RTS
    
@right_pressed:
    ; Move cursor right or next card
    RTS
    
@a_pressed:
    ; Execute action (flip card, use ability, etc)
    RTS
    
@b_pressed:
    ; Cancel/back
    RTS
    
@select_pressed:
    ; Toggle view or options
    RTS

; --- Update Game State ---
update_game_state:
    ; This would call the game logic from deck.asm, player.asm, room.asm, etc.
    ; For now, stub
    RTS

; --- Render Screen ---
render_screen:
    LDX view@game
    CPX #$00
    BNE @render_game
    
    ; Render splash screen
    JSR render_splash_screen
    JMP @done
    
@render_game:
    ; Render game screen
    JSR render_game_screen
    
@done:
    RTS

; --- Render Splash Screen ---
render_splash_screen:
    ; Check redraw flag
    LDA redraws@game
    AND #REQ_HP              ; Check if splash needs redraw
    BEQ @done
    
    ; Draw splash (title, menu)
    JSR draw_splash_screen
    
@done:
    RTS

; --- Render Game Screen ---
render_game_screen:
    ; Check redraw flags and update display
    LDA redraws@game
    AND #REQ_HP
    BEQ @skip_hp
    JSR update_hp_display
@skip_hp:
    
    LDA redraws@game
    AND #REQ_SP
    BEQ @skip_sp
    JSR update_sp_display
@skip_sp:
    
    LDA redraws@game
    AND #REQ_CARD1
    BEQ @skip_card1
    JSR update_card1_display
@skip_card1:
    
    ; ... similar for other cards ...
    
    RTS

; --- Placeholder stub routines ---
update_sp_display:
    RTS

update_card1_display:
    RTS

; --- Include other modules ---
.include "sbc_input.asm"
.include "sbc_video.asm"

; --- Interrupt vectors ---
.org $FFFA
.word $0000               ; NMI (unused for now)
.word reset               ; RESET
.word $0000               ; IRQ/BRK (unused for now)
