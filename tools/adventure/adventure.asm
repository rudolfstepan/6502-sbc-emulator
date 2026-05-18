; Simple Text Adventure for 6502 SBC
; A minimal adventure game with rooms, items, and simple commands

.segment "ZEROPAGE"
current_room:    .res 1    ; Current room ID
inventory:       .res 4    ; Up to 4 items
inv_count:       .res 1    ; Number of items in inventory
cursor_x:        .res 1    ; Text cursor position
cursor_y:        .res 1    ; Text cursor row
str_ptr_lo:      .res 1    ; String pointer low byte
str_ptr_hi:      .res 1    ; String pointer high byte
scr_ptr_lo:      .res 1    ; Screen pointer low byte
scr_ptr_hi:      .res 1    ; Screen pointer high byte
temp:            .res 1    ; Temporary variable
last_key:        .res 1    ; Last key pressed
save_x:          .res 1    ; Saved X for print_char
save_y:          .res 1    ; Saved Y for print_char
blink_counter:   .res 1    ; Blink timing divider
cursor_blink_on: .res 1    ; 1 when '_' cursor is currently visible
cmd_len:         .res 1    ; Length of typed command
cmd_buf:         .res 16   ; Command input buffer
player_hp:       .res 1    ; Player hit points
cave_enemy_hp:   .res 1    ; Cave enemy hit points
cave_enemy_alive: .res 1   ; 1 while cave enemy blocks passage

; Hardware addresses
VIC_SCREEN      = $8000    ; Screen memory
VIA_BASE        = $8800    ; VIA base address
VIA_ORA         = $8801    ; VIA Port A (keyboard)
VIA_IFR         = $880D    ; Interrupt flags

; Room IDs
ROOM_START      = 0
ROOM_FOREST     = 1
ROOM_CAVE       = 2
ROOM_TREASURE   = 3

; Item IDs
ITEM_NONE       = 0
ITEM_TORCH      = 1
ITEM_KEY        = 2
ITEM_SWORD      = 3
ITEM_GOLD       = 4

; Room item flags (which items are in which room)
room_items:     .res 4    ; Items in each room

; Game state flags
has_torch:      .res 1
has_key:        .res 1
has_sword:      .res 1
treasure_open:  .res 1
game_won:       .res 1

.segment "CODE"

reset:
    sei
    cld
    ldx #$ff
    txs
    
    jsr init_game
    jsr clear_screen
    jsr show_intro
    jsr game_loop
    
    ; Should never reach here
    jmp reset

; Initialize game state
init_game:
    lda #ROOM_START
    sta current_room
    
    lda #0
    sta inv_count
    sta cursor_x
    sta cursor_y
    sta last_key
    sta has_torch
    sta has_key
    sta has_sword
    sta treasure_open
    sta game_won
    lda #5
    sta player_hp
    lda #3
    sta cave_enemy_hp
    lda #1
    sta cave_enemy_alive
    lda #0
    sta cmd_len

    jsr flush_keyboard
    
    ; Clear inventory
    ldx #0
:   sta inventory,x
    inx
    cpx #4
    bne :-
    
    ; Place items in rooms
    ; Room 0 (START): nothing
    lda #ITEM_NONE
    sta room_items+0
    
    ; Room 1 (FOREST): torch
    lda #ITEM_TORCH
    sta room_items+1
    
    ; Room 2 (CAVE): key
    lda #ITEM_KEY
    sta room_items+2
    
    ; Room 3 (TREASURE): gold
    lda #ITEM_GOLD
    sta room_items+3
    
    rts

; Clear screen with spaces
clear_screen:
    lda #$20
    ldx #0
clear_loop1:
    sta VIC_SCREEN,x
    sta VIC_SCREEN+$100,x
    sta VIC_SCREEN+$200,x
    inx
    bne clear_loop1
    
    ldx #0
clear_loop2:
    cpx #$e8
    bcs clear_done
    sta VIC_SCREEN+$300,x
    inx
    jmp clear_loop2
    
clear_done:
    lda #0
    sta cursor_x
    sta cursor_y
    rts

; Print string at current cursor
; Input: X/Y = pointer to string (low/high)
print_string:
    stx str_ptr_lo
    sty str_ptr_hi
    ldy #0
    
print_loop:
    lda (str_ptr_lo),y
    beq print_done
    cmp #$0A        ; Newline?
    beq print_newline
    
    jsr print_char
    iny
    jmp print_loop
    
print_newline:
    lda #0
    sta cursor_x
    inc cursor_y
    iny
    jmp print_loop
    
print_done:
    rts

; Print single character at cursor
print_char:
    pha

    jsr calc_screen_ptr

    pla
    jsr plot_char_at_cursor
    
    inc cursor_x
    lda cursor_x
    cmp #40
    bcc :+
    lda #0
    sta cursor_x
    inc cursor_y
:   rts

; Compute scr_ptr_lo/scr_ptr_hi for current cursor_x/cursor_y.
calc_screen_ptr:

    ; Build 16-bit screen pointer: VIC_SCREEN + (cursor_y * 40) + cursor_x
    lda #<VIC_SCREEN
    sta scr_ptr_lo
    lda #>VIC_SCREEN
    sta scr_ptr_hi

    lda cursor_y
    sta temp

row_add_loop:
    lda temp
    beq row_add_done

    clc
    lda scr_ptr_lo
    adc #40
    sta scr_ptr_lo
    lda scr_ptr_hi
    adc #0
    sta scr_ptr_hi

    dec temp
    jmp row_add_loop

row_add_done:
    clc
    lda scr_ptr_lo
    adc cursor_x
    sta scr_ptr_lo
    lda scr_ptr_hi
    adc #0
    sta scr_ptr_hi

    rts

; Plot A at cursor position without moving cursor_x/cursor_y.
plot_char_at_cursor:
    pha
    jsr calc_screen_ptr
    pla

    ; Preserve caller's X/Y, use Y=0 for store, then restore.
    stx save_x
    sty save_y
    ldy #0
    sta (scr_ptr_lo),y
    ldy save_y
    ldx save_x
    rts

; Show intro text
show_intro:
    jsr show_room
    rts

; Main game loop
game_loop:
game_loop_top:
    lda game_won
    bne game_loop_win
    lda player_hp
    bne game_loop_alive
    jmp show_game_over

game_loop_win:
    jmp show_victory

game_loop_alive:
    jsr read_command_line

    lda cmd_len
    bne cmd_not_empty
    jmp game_loop_top

cmd_not_empty:
    lda cmd_buf
    cmp #'n'
    bne :+
    jmp cmd_north
:   cmp #'s'
    bne :+
    jmp cmd_south
:   cmp #'e'
    bne :+
    jmp cmd_east
:   cmp #'w'
    bne :+
    jmp cmd_west
:   cmp #'l'
    bne :+
    jmp cmd_look
:   cmp #'i'
    bne :+
    jmp cmd_inventory
:   cmp #'t'
    bne :+
    jmp cmd_take
:   cmp #'u'
    bne :+
    jmp cmd_use
:   cmp #'a'
    bne :+
    jmp cmd_attack
:   cmp #'q'
    bne :+
    jmp cmd_quit
:   cmp #'g'
    bne cmd_unknown
    lda cmd_buf+1
    cmp #'o'
    bne cmd_unknown
    lda cmd_buf+2
    cmp #' '
    bne cmd_unknown
    lda cmd_buf+3
    cmp #'n'
    bne :+
    jmp cmd_north
:   cmp #'s'
    bne :+
    jmp cmd_south
:   cmp #'e'
    bne :+
    jmp cmd_east
:   cmp #'w'
    bne cmd_unknown
    jmp cmd_west

cmd_unknown:
    ldx #<msg_unknown
    ldy #>msg_unknown
    jsr print_string
    jmp game_loop_top

; Wait for key press
wait_key:
    lda last_key
wait_loop:
    lda VIA_IFR
    and #$02
    beq wait_loop
    
    lda VIA_ORA
    cmp last_key
    beq wait_loop
    sta last_key
    rts

; Wait for key press without de-duplication
wait_key_raw:
wait_raw_loop:
    lda VIA_IFR
    and #$02
    beq wait_raw_loop
    lda VIA_ORA
    rts

wait_key_blink:
wait_blink_loop:
    lda VIA_IFR
    and #$02
    bne wait_blink_key

    inc blink_counter
    lda blink_counter
    cmp #$60
    bcc wait_blink_loop
    lda #0
    sta blink_counter
    jsr toggle_input_cursor
    jmp wait_blink_loop

wait_blink_key:
    lda VIA_ORA
    rts

toggle_input_cursor:
    lda cursor_blink_on
    beq cursor_draw

    lda #' '
    jsr plot_char_at_cursor
    lda #0
    sta cursor_blink_on
    rts

cursor_draw:
    lda #'_'
    jsr plot_char_at_cursor
    lda #1
    sta cursor_blink_on
    rts

flush_keyboard:
flush_kb_loop:
    lda VIA_IFR
    and #$02
    beq flush_kb_done
    lda VIA_ORA
    sta last_key
    jmp flush_kb_loop
flush_kb_done:
    rts

; Read one command line into cmd_buf (max 15 chars), lowercased.
read_command_line:
    lda #0
    sta cmd_len

    ; Use a dedicated input line near the bottom.
    lda #23
    sta cursor_y
    lda #0
    sta cursor_x
    jsr clear_input_line
    lda #23
    sta cursor_y
    lda #0
    sta cursor_x

    ldx #<msg_prompt_cmd
    ldy #>msg_prompt_cmd
    jsr print_string

read_cmd_loop:
    jsr wait_key_raw

    cmp #$07        ; Bell
    beq read_cmd_loop

    cmp #$0D        ; Enter
    beq read_cmd_done
    cmp #$0A        ; LF as Enter fallback
    beq read_cmd_done
    cmp #$08        ; Backspace
    beq read_cmd_backspace
    cmp #$7F        ; Delete
    beq read_cmd_backspace

    cmp #$20        ; Skip non-printable
    bcc read_cmd_loop
    cmp #$7F
    bcs read_cmd_loop

    ; Normalize uppercase to lowercase
    cmp #'A'
    bcc read_cmd_store
    cmp #'Z'+1
    bcs read_cmd_store
    ora #$20

read_cmd_store:
    ldx cmd_len
    cpx #15
    bcs read_cmd_loop

    sta cmd_buf,x
    inc cmd_len
    jsr print_char
    jmp read_cmd_loop

read_cmd_backspace:
    lda cmd_len
    beq read_cmd_loop

    dec cmd_len

    lda cursor_x
    bne :+
    lda #39
    sta cursor_x
    lda cursor_y
    beq read_cmd_loop
    dec cursor_y
    jmp read_cmd_erase

:   dec cursor_x

read_cmd_erase:
    lda #' '
    jsr print_char
    dec cursor_x
    jmp read_cmd_loop

read_cmd_done:
    ldx cmd_len
    lda #0
    sta cmd_buf,x
    lda #0
    sta cursor_x
    inc cursor_y
    rts

clear_input_line:
    lda #0
    sta cursor_x
    ldx #40
clear_input_loop:
    lda #' '
    jsr print_char
    dex
    bne clear_input_loop
    lda #23
    sta cursor_y
    lda #0
    sta cursor_x
    rts

; Commands
cmd_north:
    lda current_room
    cmp #ROOM_START
    bne cmd_north_fail
    lda #ROOM_FOREST
    sta current_room
    jsr clear_screen
    jsr show_room
    jmp game_loop
cmd_north_fail:
    jmp cant_go

cmd_south:
    lda current_room
    cmp #ROOM_FOREST
    bne cmd_south_2
    lda #ROOM_START
    sta current_room
    jsr clear_screen
    jsr show_room
    jmp game_loop
cmd_south_2:
    cmp #ROOM_CAVE
    bne cmd_south_3
    lda #ROOM_FOREST
    sta current_room
    jsr clear_screen
    jsr show_room
    jmp game_loop
cmd_south_3:
    cmp #ROOM_TREASURE
    bne cmd_south_fail
    lda #ROOM_CAVE
    sta current_room
    jsr clear_screen
    jsr show_room
    jmp game_loop
cmd_south_fail:
    jmp cant_go

cmd_east:
    lda current_room
    cmp #ROOM_FOREST
    bne cmd_east_2
    lda #ROOM_CAVE
    sta current_room
    jsr clear_screen
    jsr show_room
    jmp game_loop
cmd_east_2:
    cmp #ROOM_CAVE
    bne cmd_east_fail
    ; Need torch to go deeper
    lda has_torch
    beq cmd_east_dark
    ; Enemy must be defeated before entering treasure room
    lda cave_enemy_alive
    beq :+
    ldx #<msg_enemy_blocks
    ldy #>msg_enemy_blocks
    jsr print_string
    jmp game_loop
: 
    lda #ROOM_TREASURE
    sta current_room
    jsr clear_screen
    jsr show_room
    jmp game_loop
cmd_east_dark:
    ldx #<msg_too_dark
    ldy #>msg_too_dark
    jsr print_string
    jmp game_loop
cmd_east_fail:
    jmp cant_go

cmd_west:
    lda current_room
    cmp #ROOM_CAVE
    bne cmd_west_2
    lda #ROOM_FOREST
    sta current_room
    jsr clear_screen
    jsr show_room
    jmp game_loop
cmd_west_2:
    cmp #ROOM_TREASURE
    bne cmd_west_fail
    lda #ROOM_CAVE
    sta current_room
    jsr clear_screen
    jsr show_room
    jmp game_loop
cmd_west_fail:
    jmp cant_go

cmd_look:
    jsr clear_screen
    jsr show_room
    jmp game_loop

cmd_take:
    ; Check if there's an item in this room
    ldx current_room
    lda room_items,x
    beq take_nothing
    
    ; Check inventory space
    lda inv_count
    cmp #4
    bcs take_full
    
    ; Take the item
    ldx current_room
    lda room_items,x
    
    ; Add to inventory
    ldx inv_count
    sta inventory,x
    inc inv_count
    
    ; Set flags
    cmp #ITEM_TORCH
    bne :+
    lda #1
    sta has_torch
    jmp take_done
    
:   cmp #ITEM_KEY
    bne :+
    lda #1
    sta has_key
    jmp take_done
    
:   cmp #ITEM_SWORD
    bne take_done
    lda #1
    sta has_sword
    
take_done:
    ; Remove from room
    lda #ITEM_NONE
    ldx current_room
    sta room_items,x
    
    ldx #<msg_taken
    ldy #>msg_taken
    jsr print_string
    jmp game_loop
    
take_nothing:
    ldx #<msg_nothing
    ldy #>msg_nothing
    jsr print_string
    jmp game_loop
    
take_full:
    ldx #<msg_inv_full
    ldy #>msg_inv_full
    jsr print_string
    jmp game_loop

cmd_use:
    ; Check if in treasure room
    lda current_room
    cmp #ROOM_TREASURE
    bne use_nothing
    
    ; Check if has key
    lda has_key
    beq use_no_key
    
    ; Check if already open
    lda treasure_open
    bne use_already_open
    
    ; Open treasure!
    lda #1
    sta treasure_open
    sta game_won
    
    ldx #<msg_opened
    ldy #>msg_opened
    jsr print_string
    jmp game_loop
    
use_nothing:
    ldx #<msg_use_nothing
    ldy #>msg_use_nothing
    jsr print_string
    jmp game_loop
    
use_no_key:
    ldx #<msg_need_key
    ldy #>msg_need_key
    jsr print_string
    jmp game_loop
    
use_already_open:
    ldx #<msg_already_open
    ldy #>msg_already_open
    jsr print_string
    jmp game_loop

cmd_attack:
    lda current_room
    cmp #ROOM_CAVE
    bne attack_no_target

    lda cave_enemy_alive
    bne attack_enemy_alive
    ldx #<msg_enemy_down_already
    ldy #>msg_enemy_down_already
    jsr print_string
    jmp game_loop

attack_enemy_alive:
    lda has_sword
    beq attack_no_sword

    ; Sword hit: 2 damage
    lda cave_enemy_hp
    beq attack_enemy_dead
    dec cave_enemy_hp
    lda cave_enemy_hp
    beq attack_enemy_dead
    dec cave_enemy_hp
    jmp attack_enemy_after_hit

attack_no_sword:
    ; Bare-hand hit: 1 damage
    lda cave_enemy_hp
    beq attack_enemy_dead
    dec cave_enemy_hp

attack_enemy_after_hit:
    lda cave_enemy_hp
    beq attack_enemy_dead

    ldx #<msg_enemy_hit
    ldy #>msg_enemy_hit
    jsr print_string

    ; Enemy retaliates for 1 HP
    lda player_hp
    beq attack_player_down
    dec player_hp
    lda player_hp
    beq attack_player_down
    ldx #<msg_enemy_retaliates
    ldy #>msg_enemy_retaliates
    jsr print_string
    jmp game_loop

attack_player_down:
    ldx #<msg_enemy_retaliates
    ldy #>msg_enemy_retaliates
    jsr print_string
    jmp game_loop

attack_enemy_dead:
    lda #0
    sta cave_enemy_alive
    ldx #<msg_enemy_defeated
    ldy #>msg_enemy_defeated
    jsr print_string
    jmp game_loop

attack_no_target:
    ldx #<msg_attack_air
    ldy #>msg_attack_air
    jsr print_string
    jmp game_loop

cmd_inventory:
    ldx #<msg_inv
    ldy #>msg_inv
    jsr print_string
    
    lda inv_count
    beq inv_empty
    
    ; Show items
    ldy #0
inv_loop:
    cpy inv_count
    bcs inv_done
    
    lda inventory,y
    pha
    tya
    pha
    
    pla
    tay
    pla
    
    cmp #ITEM_TORCH
    bne :+
    ldx #<item_torch_name
    ldy #>item_torch_name
    jsr print_string
    jmp inv_next
    
:   cmp #ITEM_KEY
    bne :+
    ldx #<item_key_name
    ldy #>item_key_name
    jsr print_string
    jmp inv_next
    
:   cmp #ITEM_SWORD
    bne inv_next
    ldx #<item_sword_name
    ldy #>item_sword_name
    jsr print_string
    
inv_next:
    iny
    jmp inv_loop
    
inv_done:
    jmp game_loop
    
inv_empty:
    ldx #<msg_inv_empty
    ldy #>msg_inv_empty
    jsr print_string
    jmp game_loop

cmd_quit:
    jsr clear_screen
    ldx #<msg_bye
    ldy #>msg_bye
    jsr print_string
quit_loop:
    jmp quit_loop

show_victory:
    jsr clear_screen
    ldx #<msg_victory
    ldy #>msg_victory
    jsr print_string
victory_loop:
    jmp victory_loop

show_game_over:
    jsr clear_screen
    ldx #<msg_game_over
    ldy #>msg_game_over
    jsr print_string
game_over_loop:
    jmp game_over_loop

cant_go:
    ldx #<msg_cant_go
    ldy #>msg_cant_go
    jsr print_string
    jmp game_loop

draw_hud:
    lda #0
    sta cursor_x
    sta cursor_y

    ldx #<hud_hp
    ldy #>hud_hp
    jsr print_string
    lda player_hp
    jsr print_digit

    ldx #<hud_enemy
    ldy #>hud_enemy
    jsr print_string
    lda cave_enemy_alive
    beq hud_enemy_dash
    lda cave_enemy_hp
    jsr print_digit
    jmp hud_after_enemy

hud_enemy_dash:
    lda #'-'
    jsr print_char

hud_after_enemy:
    ldx #<hud_key
    ldy #>hud_key
    jsr print_string
    lda has_key
    beq hud_key_n
    lda #'Y'
    jsr print_char
    jmp hud_after_key

hud_key_n:
    lda #'N'
    jsr print_char

hud_after_key:
    ldx #<hud_nl
    ldy #>hud_nl
    jsr print_string
    rts

print_digit:
    clc
    adc #'0'
    jsr print_char
    rts

; Show current room description
show_room:
    jsr draw_hud

    lda current_room
    cmp #ROOM_START
    bne :+
    ldx #<room_start_text
    ldy #>room_start_text
    jsr print_string
    jmp show_room_items
    
:   cmp #ROOM_FOREST
    bne :+
    ldx #<room_forest_text
    ldy #>room_forest_text
    jsr print_string
    jmp show_room_items
    
:   cmp #ROOM_CAVE
    bne :+
    ldx #<room_cave_text
    ldy #>room_cave_text
    jsr print_string
    lda cave_enemy_alive
    beq cave_room_done
    ldx #<msg_enemy_seen
    ldy #>msg_enemy_seen
    jsr print_string
cave_room_done:
    jmp show_room_items
    
:   cmp #ROOM_TREASURE
    bne :+
    ldx #<room_treasure_text
    ldy #>room_treasure_text
    jsr print_string
    jmp show_room_items
    
:   ldx #<msg_unknown_room
    ldy #>msg_unknown_room
    jsr print_string
    
show_room_items:
    ; Show items in room
    ldx current_room
    lda room_items,x
    beq show_room_prompt
    
    cmp #ITEM_TORCH
    bne :+
    ldx #<msg_see_torch
    ldy #>msg_see_torch
    jsr print_string
    jmp show_room_prompt
    
:   cmp #ITEM_KEY
    bne :+
    ldx #<msg_see_key
    ldy #>msg_see_key
    jsr print_string
    jmp show_room_prompt
    
:   cmp #ITEM_GOLD
    bne show_room_prompt
    ldx #<msg_see_gold
    ldy #>msg_see_gold
    jsr print_string

show_room_prompt:
    rts
    

; Text data
intro_text:
    .byte "CAVE ADVENTURE", $0A
    .byte "=============", $0A, $0A
    .byte "Find the treasure!", $0A
    .byte "Commands:", $0A
    .byte "n/s/e/w or go north", $0A
    .byte "look, inventory", $0A
    .byte "take, use, attack", $0A
    .byte "Q - Quit", $0A, $0A, 0

room_start_text:
    .byte "FOREST CLEARING", $0A
    .byte "[____________________]", $0A
    .byte "|        *YOU*       |", $0A
    .byte "|       MEADOW       |", $0A
    .byte "|                    |", $0A
    .byte "`________|N|_________{", $0A, 0

room_forest_text:
    .byte "DARK FOREST", $0A
    .byte "[____________________]", $0A
    .byte "| T   T  *P* T T     |", $0A
    .byte "|  T T    T    T     |", $0A
    .byte "| T  T  T T  T       |", $0A
    .byte "|_S_____^_____E_____>{", $0A, 0

room_cave_text:
    .byte "CAVE ENTRANCE", $0A
    .byte "[____________________]", $0A
    .byte "|  *P*    .  o  .    |", $0A
    .byte "| .  *  .  *  .  .   |", $0A
    .byte "|   Water drips...   |", $0A
    .byte "`____________________{" , $0A, 0

msg_enemy_seen:
    .byte " [__________________]", $0A
    .byte " |  ^-^   ^-^  ^-^  |", $0A
    .byte " |(o_o) (o_o) (o_o) |", $0A
    .byte " | B E A S T S !!!  |", $0A
    .byte " `__________________{" , $0A, 0

room_treasure_text:
    .byte "TREASURE CHAMBER", $0A
    .byte "[____________________]", $0A
    .byte "|   *$$$$ CHEST*     |", $0A
    .byte "|    $$$$$$$$$$$$$$$ |", $0A
    .byte "|    GOLD RICHES!    |", $0A
    .byte "`__ANCIENT_WEALTH____{", $0A, 0

msg_unknown:
    .byte "Unknown command.", $0A, 0

msg_cant_go:
    .byte "You can't go that way.", $0A, 0

msg_too_dark:
    .byte "Too dark! Need light.", $0A, 0

msg_enemy_blocks:
    .byte "The beast blocks EAST!", $0A, 0

msg_enemy_hit:
    .byte "You hit the beast.", $0A, 0

msg_enemy_retaliates:
    .byte "It claws you back!", $0A, 0

msg_enemy_defeated:
    .byte "Beast defeated.", $0A, 0

msg_enemy_down_already:
    .byte "Nothing left to attack.", $0A, 0

msg_attack_air:
    .byte "You swing at air.", $0A, 0

msg_prompt:
    .byte $0A, "> ", 0

msg_prompt_cmd:
    .byte "> ", 0

msg_inv:
    .byte "INVENTORY:", $0A, 0

msg_inv_empty:
    .byte "  Empty", $0A, 0

msg_inv_full:
    .byte "Inventory full!", $0A, 0

msg_taken:
    .byte "Taken.", $0A, 0

msg_nothing:
    .byte "Nothing to take.", $0A, 0

msg_see_torch:
    .byte "    o*o", $0A
    .byte "   o***o", $0A
    .byte "    |||", $0A
    .byte "  [TORCH] glows bright!", $0A, 0

msg_see_key:
    .byte "   +---+", $0A
    .byte "   | o |", $0A
    .byte "   +---+", $0A
    .byte "  [RUSTY KEY] awaits!", $0A, 0

msg_see_gold:
    .byte "  ***  ***  ***", $0A
    .byte "  GOLD TREASURE!!", $0A, 0

msg_use_nothing:
    .byte "Use what where?", $0A, 0

msg_need_key:
    .byte "The chest is locked.", $0A, 0

msg_opened:
    .byte "You unlock the chest!", $0A, 0

msg_already_open:
    .byte "Already opened.", $0A, 0

msg_victory:
    .byte "*** YOU WIN! ***", $0A
    .byte $0A
    .byte "The chest contains gold!", $0A
    .byte "You are rich!", $0A
    .byte $0A
    .byte "Thanks for playing!", $0A, 0

msg_game_over:
    .byte "*** GAME OVER ***", $0A
    .byte "The cave wins this time.", $0A, 0

msg_bye:
    .byte "Goodbye!", $0A, 0

msg_unknown_room:
    .byte "ERROR: Unknown room", $0A, 0

item_torch_name:
    .byte "  Torch", $0A, 0

item_key_name:
    .byte "  Rusty Key", $0A, 0

item_sword_name:
    .byte "  Sword", $0A, 0

hud_hp:
    .byte "HP:", 0

hud_enemy:
    .byte "  EN:", 0

hud_key:
    .byte "  KEY:", 0

hud_nl:
    .byte $0A, $0A, 0

.segment "VECTORS"
.addr reset     ; NMI
.addr reset     ; RESET
.addr reset     ; IRQ/BRK
