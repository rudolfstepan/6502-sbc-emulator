; SBC Video Output Handler for Donsol
; Uses text mode ($8000, 40x25) for display

; --- Initialize Video ---
init_video:
    jsr clear_screen
    rts

; --- Clear Screen (fill with spaces) ---
clear_screen:
    lda #$20                  ; Space character
    ldx #$00
    ldy #$00
    
clear_page1:
    sta VIC_SCREEN_BASE,x
    inx
    bne clear_page1
    
    lda #$20
    ldx #$00
    
clear_page2:
    sta VIC_SCREEN_BASE+$100,x
    inx
    bne clear_page2
    
    lda #$20
    ldx #$00
    
clear_page3:
    sta VIC_SCREEN_BASE+$200,x
    inx
    bne clear_page3
    
    lda #$20
    ldx #$00
    
clear_page4:
    cpx #$e8
    bcs clear_done
    sta VIC_SCREEN_BASE+$300,x
    inx
    bne clear_page4
    
clear_done:
    rts

; --- Print character at screen position ---
; Input: A = character code
;        X = column (0-39)
;        Y = row (0-24)
print_char:
    sta lb_temp
    stx hb_temp

    tya
    asl a
    asl a
    asl a
    asl a
    asl a
    sta id_temp             ; row * 32

    tya
    asl a
    asl a
    asl a
    sta damages_player      ; row * 8

    lda id_temp
    clc
    adc damages_player      ; row * 36
    clc
    adc hb_temp             ; + column
    tax

    lda lb_temp
    sta VIC_SCREEN_BASE,x
    rts

; --- Print string at screen position ---
; Input: X = column, Y = row, hb_temp points to string, A preserved by caller if needed
print_string:
    ldy #$00
print_string_loop:
    lda (lb_temp),y
    beq print_string_done
    pha
    txa
    pha
    tya
    pha
    lda (lb_temp),y
    tax
    pla
    tay
    pla
    tax
    pla
    jsr print_char
    iny
    inx
    jmp print_string_loop
print_string_done:
    rts

; --- Print hex digit as ASCII ---
; Input: A = value 0-15
; Output: A = ASCII character ('0'-'9' or 'A'-'F')
hex_to_ascii:
    cmp #$0a
    bcs hex_letter
    
    clc
    adc #$30                  ; Add '0'
    rts
    
hex_letter:
    clc
    adc #$37                  ; $0A->$41 ('A')
    rts

; --- Print hex byte as two ASCII digits ---
; Input: A = byte value
;        X = column
;        Y = row
print_hex_byte:
    pha
    lsr a
    lsr a
    lsr a
    lsr a
    jsr hex_to_ascii
    jsr print_char

    pla
    and #$0f
    jsr hex_to_ascii
    inx
    jsr print_char
    rts

; --- Print card symbol ---
; Input: A = card value (0 damage, 1 hp, 2 shield, 3 xp)
;        X = column
;        Y = row
print_card_symbol:
    cmp #$00
    beq print_card_damage
    cmp #$01
    beq print_card_hp
    cmp #$02
    beq print_card_sp
    cmp #$03
    beq print_card_xp
    lda #$3f                  ; ?
    jsr print_char
    rts

print_card_damage:
    lda #$44                  ; D
    jsr print_char
    rts

print_card_hp:
    lda #$48                  ; H
    jsr print_char
    rts

print_card_sp:
    lda #$53                  ; S
    jsr print_char
    rts

print_card_xp:
    lda #$58                  ; X
    jsr print_char
    rts

; --- Draw splash screen (title/menu) ---
draw_splash_screen:
    jsr clear_screen
    
    ; Display title: "DONSOL"
    lda #$44                  ; 'D'
    ldx #$11
    ldy #$02
    jsr print_char
    
    lda #$4f                  ; 'O'
    ldx #$12
    ldy #$02
    jsr print_char
    
    lda #$4e                  ; 'N'
    ldx #$13
    ldy #$02
    jsr print_char
    
    lda #$53                  ; 'S'
    ldx #$14
    ldy #$02
    jsr print_char
    
    lda #$4f                  ; 'O'
    ldx #$15
    ldy #$02
    jsr print_char
    
    lda #$4c                  ; 'L'
    ldx #$16
    ldy #$02
    jsr print_char
    
    ; Display menu
    lda #$3e                  ; '>'
    ldx #$08
    ldy #$12
    jsr print_char
    
    lda #$53                  ; 'S'
    ldx #$0a
    ldy #$12
    jsr print_char
    
    lda #$54                  ; 'T'
    ldx #$0b
    ldy #$12
    jsr print_char
    
    lda #$41                  ; 'A'
    ldx #$0c
    ldy #$12
    jsr print_char
    
    lda #$52                  ; 'R'
    ldx #$0d
    ldy #$12
    jsr print_char
    
    lda #$54                  ; 'T'
    ldx #$0e
    ldy #$12
    jsr print_char

    lda #$20                  ; ' '
    ldx #$00
    ldy #$14
    jsr print_char

    lda #$41                  ; 'A'
    ldx #$01
    ldy #$14
    jsr print_char

    lda #$20                  ; ' '
    ldx #$02
    ldy #$14
    jsr print_char

    lda #$53                  ; 'S'
    ldx #$03
    ldy #$14
    jsr print_char

    lda #$54                  ; 'T'
    ldx #$04
    ldy #$14
    jsr print_char

    lda #$41                  ; 'A'
    ldx #$05
    ldy #$14
    jsr print_char

    lda #$52                  ; 'R'
    ldx #$06
    ldy #$14
    jsr print_char

    lda #$54                  ; 'T'
    ldx #$07
    ldy #$14
    jsr print_char
    
    rts

; --- Draw game screen ---
draw_game_screen:
    jsr clear_screen

    lda #$44                  ; D
    ldx #$11
    ldy #$00
    jsr print_char
    lda #$4f                  ; O
    ldx #$12
    ldy #$00
    jsr print_char
    lda #$4e                  ; N
    ldx #$13
    ldy #$00
    jsr print_char
    lda #$53                  ; S
    ldx #$14
    ldy #$00
    jsr print_char
    lda #$4f                  ; O
    ldx #$15
    ldy #$00
    jsr print_char
    lda #$4c                  ; L
    ldx #$16
    ldy #$00
    jsr print_char

    lda #$48                  ; H
    ldx #$00
    ldy #$02
    jsr print_char
    lda #$50                  ; P
    ldx #$01
    ldy #$02
    jsr print_char
    lda #$3a                  ; :
    ldx #$02
    ldy #$02
    jsr print_char
    lda hp_player
    ldx #$04
    ldy #$02
    jsr print_hex_byte

    lda #$53                  ; S
    ldx #$00
    ldy #$03
    jsr print_char
    lda #$50                  ; P
    ldx #$01
    ldy #$03
    jsr print_char
    lda #$3a                  ; :
    ldx #$02
    ldy #$03
    jsr print_char
    lda sp_player
    ldx #$04
    ldy #$03
    jsr print_hex_byte

    lda #$58                  ; X
    ldx #$00
    ldy #$04
    jsr print_char
    lda #$50                  ; P
    ldx #$01
    ldy #$04
    jsr print_char
    lda #$3a                  ; :
    ldx #$02
    ldy #$04
    jsr print_char
    lda xp_player
    ldx #$04
    ldy #$04
    jsr print_hex_byte

    lda #$44                  ; D
    ldx #$00
    ldy #$05
    jsr print_char
    lda #$4b                  ; K
    ldx #$01
    ldy #$05
    jsr print_char
    lda #$3a                  ; :
    ldx #$02
    ldy #$05
    jsr print_char
    lda length_deck
    ldx #$04
    ldy #$05
    jsr print_hex_byte

    lda #$45                  ; E
    ldx #$00
    ldy #$06
    jsr print_char
    lda #$4e                  ; N
    ldx #$01
    ldy #$06
    jsr print_char
    lda #$3a                  ; :
    ldx #$02
    ldy #$06
    jsr print_char
    lda enemy_hp_game
    ldx #$04
    ldy #$06
    jsr print_hex_byte

    lda #$54                  ; T
    ldx #$08
    ldy #$06
    jsr print_char
    lda #$52                  ; R
    ldx #$09
    ldy #$06
    jsr print_char
    lda #$3a                  ; :
    ldx #$0a
    ldy #$06
    jsr print_char
    lda turn_game
    ldx #$0c
    ldy #$06
    jsr print_hex_byte

    lda #$52                  ; R
    ldx #$12
    ldy #$06
    jsr print_char
    lda #$4d                  ; M
    ldx #$13
    ldy #$06
    jsr print_char
    lda #$3a                  ; :
    ldx #$14
    ldy #$06
    jsr print_char
    lda room_game
    ldx #$16
    ldy #$06
    jsr print_hex_byte

    lda #$4c                  ; L
    ldx #$00
    ldy #$07
    jsr print_char
    lda #$41                  ; A
    ldx #$01
    ldy #$07
    jsr print_char
    lda #$53                  ; S
    ldx #$02
    ldy #$07
    jsr print_char
    lda #$54                  ; T
    ldx #$03
    ldy #$07
    jsr print_char
    lda #$3a                  ; :
    ldx #$04
    ldy #$07
    jsr print_char
    lda card_last
    ldx #$06
    ldy #$07
    jsr print_card_symbol

    lda #$43                  ; C
    ldx #$00
    ldy #$09
    jsr print_char
    lda #$41                  ; A
    ldx #$01
    ldy #$09
    jsr print_char
    lda #$52                  ; R
    ldx #$02
    ldy #$09
    jsr print_char
    lda #$44                  ; D
    ldx #$03
    ldy #$09
    jsr print_char
    lda #$53                  ; S
    ldx #$04
    ldy #$09
    jsr print_char
    lda #$3a                  ; :
    ldx #$05
    ldy #$09
    jsr print_char
    lda card1_room
    ldx #$07
    ldy #$09
    jsr print_card_symbol
    lda card2_room
    ldx #$0a
    ldy #$09
    jsr print_card_symbol
    lda card3_room
    ldx #$0d
    ldy #$09
    jsr print_card_symbol
    lda card4_room
    ldx #$10
    ldy #$09
    jsr print_card_symbol

    lda #$41                  ; A
    ldx #$00
    ldy #$0b
    jsr print_char
    lda #$43                  ; C
    ldx #$01
    ldy #$0b
    jsr print_char
    lda #$54                  ; T
    ldx #$02
    ldy #$0b
    jsr print_char
    lda #$3a                  ; :
    ldx #$03
    ldy #$0b
    jsr print_char

    lda card_last_type
    cmp #$01
    beq draw_action_damage_selected
    cmp #$02
    beq draw_action_hp_selected
    cmp #$03
    beq draw_action_sp_selected
    cmp #$04
    beq draw_action_xp_selected
    jmp draw_action_none_selected

draw_action_damage_selected:
    jsr draw_action_damage
    jmp draw_action_done

draw_action_hp_selected:
    jsr draw_action_hp
    jmp draw_action_done

draw_action_sp_selected:
    jsr draw_action_sp
    jmp draw_action_done

draw_action_xp_selected:
    jsr draw_action_xp
    jmp draw_action_done

draw_action_none_selected:
    jsr draw_action_none
    jmp draw_action_done

draw_action_damage:
    lda #$44                  ; D
    ldx #$05
    ldy #$0b
    jsr print_char
    lda #$4d                  ; M
    ldx #$06
    ldy #$0b
    jsr print_char
    lda #$47                  ; G
    ldx #$07
    ldy #$0b
    jsr print_char
    jmp draw_action_done

draw_action_hp:
    lda #$48                  ; H
    ldx #$05
    ldy #$0b
    jsr print_char
    lda #$45                  ; E
    ldx #$06
    ldy #$0b
    jsr print_char
    lda #$41                  ; A
    ldx #$07
    ldy #$0b
    jsr print_char
    lda #$4c                  ; L
    ldx #$08
    ldy #$0b
    jsr print_char
    lda #$20                  ; space
    ldx #$09
    ldy #$0b
    jsr print_char
    lda #$48                  ; H
    ldx #$0a
    ldy #$0b
    jsr print_char
    lda #$50                  ; P
    ldx #$0b
    ldy #$0b
    jsr print_char
    jmp draw_action_done

draw_action_sp:
    lda #$53                  ; S
    ldx #$05
    ldy #$0b
    jsr print_char
    lda #$48                  ; H
    ldx #$06
    ldy #$0b
    jsr print_char
    lda #$49                  ; I
    ldx #$07
    ldy #$0b
    jsr print_char
    lda #$45                  ; E
    ldx #$08
    ldy #$0b
    jsr print_char
    lda #$4c                  ; L
    ldx #$09
    ldy #$0b
    jsr print_char
    lda #$44                  ; D
    ldx #$0a
    ldy #$0b
    jsr print_char
    jmp draw_action_done

draw_action_xp:
    lda #$58                  ; X
    ldx #$05
    ldy #$0b
    jsr print_char
    lda #$50                  ; P
    ldx #$06
    ldy #$0b
    jsr print_char
    lda #$20                  ; space
    ldx #$07
    ldy #$0b
    jsr print_char
    lda #$2b                  ; +
    ldx #$08
    ldy #$0b
    jsr print_char
    jmp draw_action_done

draw_action_none:
    lda #$4e                  ; N
    ldx #$05
    ldy #$0b
    jsr print_char
    lda #$4f                  ; O
    ldx #$06
    ldy #$0b
    jsr print_char
    lda #$20                  ; space
    ldx #$07
    ldy #$0b
    jsr print_char
    lda #$43                  ; C
    ldx #$08
    ldy #$0b
    jsr print_char
    lda #$41                  ; A
    ldx #$09
    ldy #$0b
    jsr print_char
    lda #$52                  ; R
    ldx #$0a
    ldy #$0b
    jsr print_char
    lda #$44                  ; D
    ldx #$0b
    ldy #$0b
    jsr print_char

draw_action_done:
    lda #$44                  ; D
    ldx #$00
    ldy #$0d
    jsr print_char
    lda #$45                  ; E
    ldx #$01
    ldy #$0d
    jsr print_char
    lda #$43                  ; C
    ldx #$02
    ldy #$0d
    jsr print_char
    lda #$4b                  ; K
    ldx #$03
    ldy #$0d
    jsr print_char
    lda #$3a                  ; :
    ldx #$04
    ldy #$0d
    jsr print_char
    lda #$20                  ; space
    ldx #$05
    ldy #$0d
    jsr print_char
    lda #$41                  ; A
    ldx #$06
    ldy #$0d
    jsr print_char
    lda #$3d                  ; =
    ldx #$07
    ldy #$0d
    jsr print_char
    lda #$44                  ; D
    ldx #$08
    ldy #$0d
    jsr print_char
    lda #$52                  ; R
    ldx #$09
    ldy #$0d
    jsr print_char
    lda #$41                  ; A
    ldx #$0a
    ldy #$0d
    jsr print_char
    lda #$57                  ; W
    ldx #$0b
    ldy #$0d
    jsr print_char

    rts

; --- Update HP Display ---
update_hp_display:
    rts

; --- Update SP Display ---
update_sp_display:
    rts

; --- Update XP Display ---
update_xp_display:
    rts

; --- Update card display ---
update_card_display:
    rts

; --- Update individual card displays ---
update_card1_display:
    rts

update_card2_display:
    rts

update_card3_display:
    rts

update_card4_display:
    rts
