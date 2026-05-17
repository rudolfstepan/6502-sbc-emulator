; Standalone SBC6502 chess ROM.
; Derived from 6502 chess by Code Monkey King / Maksim Korzh
; https://github.com/maksimKorzh/6502-chess
; License signal from upstream repository: MIT

COLS             = 40
ROWS             = 25
SCREEN_BASE      = $8000
COLOR_BASE       = $8400
VIC_CURSOR_X     = $9001
VIC_CURSOR_Y     = $9002
VIC_TEXT_COLOR   = $9003
VIC_BG_COLOR     = $9004
VIA_ORA          = $8801
VIA_DDRA         = $8803
VIA_IFR          = $880D
CA1_BIT          = $02
UI_BG_ATTR       = $60
UI_TEXT_ATTR     = $6F
BORDER_ATTR      = $67
LIGHT_SQUARE_BG  = $70
DARK_SQUARE_BG   = $50
WHITE_PIECE_FG   = $01
BLACK_PIECE_FG   = $00

.segment "ZEROPAGE"
scrptr_lo:        .res 1
scrptr_hi:        .res 1
strptr_lo:        .res 1
strptr_hi:        .res 1
tmp1:             .res 1
tmp2:             .res 1
tmp3:             .res 1
tmp4:             .res 1
tmp5:             .res 1
tmp6:             .res 1
current_color:    .res 1

.segment "BSS"
board:            .res 128
mscore:           .res 1
pscore:           .res 1
score:            .res 1
bestsrc:          .res 1
bestdst:          .res 1
side:             .res 1
tsrc:             .res 1
tdst:             .res 1
player_src:       .res 1
player_dst:       .res 1
input_buf:        .res 4
input_len:        .res 1

.segment "RODATA"
board_init:
    .byte $16, $14, $15, $17, $13, $15, $14, $16, $00, $00, $00, $00, $00, $00, $00, $00
    .byte $12, $12, $12, $12, $12, $12, $12, $12, $00, $00, $00, $00, $00, $00, $00, $00
    .byte $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $01, $01, $01, $01, $00, $00
    .byte $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $01, $02, $02, $01, $00, $00
    .byte $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $01, $02, $02, $01, $00, $00
    .byte $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $01, $01, $01, $01, $00, $00
    .byte $09, $09, $09, $09, $09, $09, $09, $09, $00, $00, $00, $00, $00, $00, $00, $00
    .byte $0E, $0C, $0D, $0F, $0B, $0D, $0C, $0E, $00, $00, $00, $00, $00, $00, $00, $00

offsets:
    .byte $00, $0F, $10, $11, $00
    .byte $F1, $F0, $EF, $00
    .byte $01, $10, $FF, $F0, $00
    .byte $01, $10, $FF, $F0, $0F, $F1, $11, $EF, $00
    .byte $0E, $F2, $12, $EE, $1F, $E1, $21, $DF, $00
    .byte $04, $00, $0D, $16, $11, $08, $0D

weights:
    .byte $00, $00, $FD, $00, $F7, $F7, $F1, $E5, $00
    .byte $03, $00, $00, $09, $09, $0F, $1B

offboard_mask:
    .byte $88

white_side_mask:
    .byte $08

pieces:
    .byte $20, $00, $50, $4B, $4E, $42, $52, $51, $00
    .byte $50, $00, $4B, $4E, $42, $52, $51

row_offsets:
    .byte $00, $10, $20, $30, $40, $50, $60, $70

title_msg:
    .byte "SBC6502 CHESS", $00

move_msg:
    .byte "ENGINE MOVE ", $00

side_msg:
    .byte "SIDE TO MOVE ", $00

black_msg:
    .byte "BLACK", $00

white_msg:
    .byte "WHITE", $00

demo_msg:
    .byte "TYPE MOVE LIKE E7E5", $00

files_msg:
    .byte "    A   B   C   D   E   F   G   H", $00

sep_msg:
    .byte "  +---+---+---+---+---+---+---+---+", $00

footer_msg:
    .byte "MOVE> ", $00

status_ready_msg:
    .byte "BLACK TO PLAY           ", $00

status_invalid_msg:
    .byte "INVALID MOVE - TRY AGAIN", $00

.segment "CODE"
reset:
    cld
    ldx #$ff
    txs
    lda #$00
    sta VIA_DDRA
    lda #$0e
    sta VIC_TEXT_COLOR
    lda #$06
    sta VIC_BG_COLOR
    jsr clear_screen
    jsr init_position
    lda #$01
    jsr search
    jsr engine_move
game_loop:
    jsr render_screen
    jsr read_player_move
    lda #$01
    jsr search
    jsr engine_move
    jmp game_loop

halt:
    jmp halt

init_position:
    ldx #$00
copy_board:
    lda board_init,x
    sta board,x
    inx
    cpx #$80
    bne copy_board
    lda #$00
    sta mscore
    sta pscore
    sta score
    sta bestsrc
    sta bestdst
    sta tsrc
    sta tdst
    sta input_len
    lda #UI_TEXT_ATTR
    sta current_color
    lda #$08
    sta side
    rts

clear_screen:
    lda #<SCREEN_BASE
    sta scrptr_lo
    lda #>SCREEN_BASE
    sta scrptr_hi
    lda #$20
    ldy #$00
    ldx #$04
clear_loop:
    sta (scrptr_lo),y
    iny
    bne clear_loop
    inc scrptr_hi
    dex
    bne clear_loop
    lda #<COLOR_BASE
    sta scrptr_lo
    lda #>COLOR_BASE
    sta scrptr_hi
    lda #UI_TEXT_ATTR
    ldy #$00
    ldx #$04
clear_color_loop:
    sta (scrptr_lo),y
    iny
    bne clear_color_loop
    inc scrptr_hi
    dex
    bne clear_color_loop
    lda #$00
    sta VIC_CURSOR_X
    sta VIC_CURSOR_Y
    rts

putc:
    sta tmp5
    txa
    pha
    sty tmp4
    lda tmp5
    cmp #$0d
    beq putc_newline
    cmp #$0a
    beq putc_done
    jsr calc_ptr
    ldy #$00
    lda tmp5
    sta (scrptr_lo),y
    clc
    lda scrptr_hi
    adc #$04
        sta tmp6
        lda tmp6
    sta scrptr_hi
    lda current_color
    sta (scrptr_lo),y
    inc VIC_CURSOR_X
    lda VIC_CURSOR_X
    cmp #COLS
    bcc putc_done
putc_newline_from_wrap:
    lda #$00
    sta VIC_CURSOR_X
    inc VIC_CURSOR_Y
    lda VIC_CURSOR_Y
    cmp #ROWS
    bcc putc_done
    lda #(ROWS - 1)
    sta VIC_CURSOR_Y
putc_newline:
    jmp putc_newline_from_wrap
putc_done:
    ldy tmp4
    pla
    tax
    lda tmp5
    rts

calc_ptr:
    lda #<SCREEN_BASE
    sta scrptr_lo
    lda #>SCREEN_BASE
    sta scrptr_hi
    ldx VIC_CURSOR_Y
calc_row:
    cpx #$00
    beq calc_col
    clc
    lda scrptr_lo
    adc #COLS
    sta scrptr_lo
    lda scrptr_hi
    adc #$00
    sta scrptr_hi
    dex
    jmp calc_row
calc_col:
    clc
    lda scrptr_lo
    adc VIC_CURSOR_X
    sta scrptr_lo
    lda scrptr_hi
    adc #$00
    sta scrptr_hi
    rts

print_string:
    sta strptr_lo
    sty strptr_hi
print_string_loop:
    ldy #$00
    lda (strptr_lo),y
    beq print_string_done
    jsr putc
    inc strptr_lo
    bne print_string_loop
    inc strptr_hi
    jmp print_string_loop
print_string_done:
    rts

read_key:
read_key_loop:
    lda VIA_IFR
    and #CA1_BIT
    beq read_key_loop
    lda VIA_ORA
    cmp #'a'
    bcc read_key_done
    cmp #'z'+1
    bcs read_key_done
    and #$DF
read_key_done:
    rts

set_cursor:
    sta VIC_CURSOR_X
    sty VIC_CURSOR_Y
    rts

set_draw_color:
    ora #UI_BG_ATTR
    sta current_color
    rts

set_draw_attr:
    sta current_color
    rts

set_square_attr:
    lda tmp1
    eor tmp2
    and #$01
    beq light_square_attr
    lda #DARK_SQUARE_BG
    sta tmp6
    jmp square_piece_attr
light_square_attr:
    lda #LIGHT_SQUARE_BG
    sta tmp6
square_piece_attr:
    lda board,y
    beq square_empty_attr
    bit white_side_mask
    bne square_white_attr
    lda tmp6
    ora #BLACK_PIECE_FG
    jmp set_draw_attr
square_white_attr:
    lda tmp6
    ora #WHITE_PIECE_FG
    jmp set_draw_attr
square_empty_attr:
    lda tmp6
    jmp set_draw_attr

show_status:
    sta strptr_lo
    sty strptr_hi
    lda #$0f
    jsr set_draw_color
    lda #$00
    ldy #$17
    jsr set_cursor
    lda strptr_lo
    ldy strptr_hi
    jsr print_string
    rts

draw_move_prompt:
    lda #$00
    sta input_len
    lda #$0f
    jsr set_draw_color
    lda #$00
    ldy #$18
    jsr set_cursor
    lda #<footer_msg
    ldy #>footer_msg
    jsr print_string
    ldx #$00
draw_prompt_fill:
    lda #'_'
    jsr putc
    inx
    cpx #$04
    bne draw_prompt_fill
    rts

redraw_input:
    lda #$0f
    jsr set_draw_color
    lda #$00
    ldy #$18
    jsr set_cursor
    lda #<footer_msg
    ldy #>footer_msg
    jsr print_string
    ldx #$00
redraw_input_loop:
    cpx input_len
    bcs redraw_placeholder
    lda input_buf,x
    jsr putc
    inx
    cpx #$04
    bne redraw_input_loop
    jmp redraw_done
redraw_placeholder:
    lda #'_'
    jsr putc
    inx
    cpx #$04
    bne redraw_input_loop
redraw_done:
    rts

is_valid_input_char:
    ldx input_len
    cpx #$00
    beq need_file
    cpx #$02
    beq need_file
need_rank:
    cmp #'1'
    bcc invalid_input_char
    cmp #'8'+1
    bcs invalid_input_char
    sec
    rts
need_file:
    cmp #'A'
    bcc invalid_input_char
    cmp #'H'+1
    bcs invalid_input_char
    sec
    rts
invalid_input_char:
    clc
    rts

parse_square_at:
    lda input_buf,x
    sec
    sbc #'A'
    sta tmp1
    inx
    lda #'8'
    sec
    sbc input_buf,x
    asl a
    asl a
    asl a
    asl a
    ora tmp1
    rts

apply_player_move:
    ldx #$00
    jsr parse_square_at
    sta player_src
    ldx #$02
    jsr parse_square_at
    sta player_dst

    ldy player_src
    lda board,y
    beq player_move_invalid
    sta tmp3
    bit side
    beq player_move_invalid

    ldy player_dst
    lda board,y
    beq player_move_commit
    bit side
    bne player_move_invalid

player_move_commit:
    ldy player_dst
    lda tmp3
    sta board,y
    ldy player_src
    lda #$00
    sta board,y
    lda #$18
    sec
    sbc side
    sta side
    sec
    rts

player_move_invalid:
    clc
    rts

read_player_move:
    lda #<status_ready_msg
    ldy #>status_ready_msg
    jsr show_status
    jsr draw_move_prompt
read_move_loop:
    jsr read_key
    cmp #$08
    beq handle_backspace
    cmp #$0D
    beq handle_enter
    cmp #'-'
    beq read_move_loop
    cmp #' '
    beq read_move_loop
    jsr is_valid_input_char
    bcc read_move_loop
    ldx input_len
    cpx #$04
    bcs read_move_loop
    sta input_buf,x
    inc input_len
    jsr redraw_input
    jmp read_move_loop

handle_backspace:
    lda input_len
    beq read_move_loop
    dec input_len
    jsr redraw_input
    jmp read_move_loop

handle_enter:
    lda input_len
    cmp #$04
    bne read_move_loop
    jsr apply_player_move
    bcs player_move_done
    lda #<status_invalid_msg
    ldy #>status_invalid_msg
    jsr show_status
    jsr draw_move_prompt
    jmp read_move_loop

player_move_done:
    rts

print_square:
    pha
    and #$0f
    clc
    adc #'A'
    jsr putc
    pla
    lsr a
    lsr a
    lsr a
    lsr a
    sta tmp1
    lda #'8'
    sec
    sbc tmp1
    jmp putc

print_rank:
    lda #$07
    jsr set_draw_color
    lda #'8'
    sec
    sbc tmp1
    sta tmp3
    jsr putc
    lda #' '
    jsr putc
    lda #'|'
    jsr putc
    lda #$00
    sta tmp2
rank_file_loop:
    lda #' '
    jsr putc
    ldy tmp1
    lda row_offsets,y
    clc
    adc tmp2
    tay
    jsr set_square_attr
    lda board,y
    and #$0f
    tax
    lda pieces,x
    jsr putc
    lda #$07
    jsr set_draw_color
    lda #' '
    jsr putc
    lda #'|'
    jsr putc
    inc tmp2
    lda tmp2
    cmp #$08
    bne rank_file_loop
    lda #' '
    jsr putc
    lda tmp3
    jsr putc
    rts

render_screen:
    jsr clear_screen
    lda #$0f
    jsr set_draw_color
    lda #$0d
    ldy #$00
    jsr set_cursor
    lda #<title_msg
    ldy #>title_msg
    jsr print_string

    lda #$02
    ldy #$01
    jsr set_cursor
    lda #<move_msg
    ldy #>move_msg
    jsr print_string
    lda bestsrc
    jsr print_square
    lda #'-'
    jsr putc
    lda bestdst
    jsr print_square

    lda #$02
    ldy #$02
    jsr set_cursor
    lda #<side_msg
    ldy #>side_msg
    jsr print_string
    lda side
    bit white_side_mask
    bne render_white
    lda #<black_msg
    ldy #>black_msg
    jmp render_side
render_white:
    lda #<white_msg
    ldy #>white_msg
render_side:
    jsr print_string

    lda #$02
    ldy #$03
    jsr set_cursor
    lda #<demo_msg
    ldy #>demo_msg
    jsr print_string

    lda #$02
    ldy #$04
    jsr set_cursor
    lda #$07
    jsr set_draw_color
    lda #<files_msg
    ldy #>files_msg
    jsr print_string

    lda #$00
    sta tmp1
render_rank_loop:
    lda tmp1
    asl a
    clc
    adc #$05
    sta tmp2

    lda #$02
    ldy tmp2
    jsr set_cursor
    lda #$07
    jsr set_draw_color
    lda #<sep_msg
    ldy #>sep_msg
    jsr print_string

    lda tmp2
    clc
    adc #$01
    tay
    lda #$02
    jsr set_cursor
    jsr print_rank

    inc tmp1
    lda tmp1
    cmp #$08
    bne render_rank_loop

    lda #$02
    ldy #$15
    jsr set_cursor
    lda #$07
    jsr set_draw_color
    lda #<sep_msg
    ldy #>sep_msg
    jsr print_string

    lda #$02
    ldy #$16
    jsr set_cursor
    lda #$07
    jsr set_draw_color
    lda #<files_msg
    ldy #>files_msg
    jsr print_string

    lda #$00
    ldy #$17
    jsr set_cursor
    lda #$0f
    jsr set_draw_color
    lda #<status_ready_msg
    ldy #>status_ready_msg
    jsr print_string

    jsr draw_move_prompt
    rts

evaluator_bridge:
    jmp evaluate

search:
    pha
    tsx
    txa
    sec
    sbc #$0a
    tax
    txs
    lda #$81
    pha
    tsx
    txa
    clc
    adc #$0c
    tax
    lda $0100,x
    cmp #$00
    beq evaluator_bridge
    dex
    lda #$00
    sta $0100,x
    jmp sq_loop

evaluate:
    lda #$00
    sta mscore
    sta pscore
    ldy #$00
brd_loop:
    tya
    bit offboard_mask
    bne skip_sq
    tay
    lda board,y
    cmp #$00
    bne scr
    jmp skip_sq
scr:
    and #$0f
    tax
    lda mscore
    clc
    adc weights,x
    sta mscore
    lda board,y
    bit white_side_mask
    beq pos_b
pos_w:
    tya
    clc
    adc #$08
    tax
    lda pscore
    clc
    adc board,x
    sta pscore
    jmp skip_sq
pos_b:
    tya
    clc
    adc #$08
    tax
    lda pscore
    sec
    sbc board,x
    sta pscore
skip_sq:
    tya
    cmp #$80
    beq ret_eval
    tay
    iny
    jmp brd_loop
ret_eval:
    tsx
    inx
    inx
    lda side
    bit white_side_mask
    beq minus
plus:
    lda mscore
    clc
    adc pscore
    sta $0100,x
    jmp end_eval
minus:
    lda #$00
    sec
    sbc mscore
    sec
    sbc pscore
    sta $0100,x
end_eval:
    jmp return

engine_move:
    ldx bestsrc
    ldy bestdst
    lda board,x
    sta board,y
    lda #$00
    sta board,x
    lda #$18
    sec
    sbc side
    sta side
    rts

sq_loop:
    bit offboard_mask
    bne sq_bridge
    tay
    lda board,y
    dex
    dex
    sta $0100,x
    bit side
    beq sq_bridge
    and #$07
    dex
    sta $0100,x
    clc
    adc #$1f
    tay
    lda offsets,y
    dex
    dex
    sta $0100,x
offset_loop:
    tsx
    txa
    clc
    adc #$06
    tax
    inc $0100,x
    lda $0100,x
    tay
    lda offsets,y
    dex
    sta $0100,x
    cmp #$00
    beq sq_bridge
    txa
    clc
    adc #$06
    tax
    lda $0100,x
    dex
    sta $0100,x
    jmp slide_loop
sq_bridge:
    jmp next_square
slide_loop:
    tsx
    txa
    clc
    adc #$05
    tax
    ldy $0100,x
    txa
    clc
    adc #$05
    tax
    tya
    clc
    adc $0100,x
    sta $0100,x
    bit offboard_mask
    bne off_bridge
    tay
    tsx
    txa
    clc
    adc #$07
    tax
    tya
    lda board,y
    sta $0100,x
    bit side
    bne off_bridge
    inx
    lda $0100,x
    sec
    cmp #$03
    bcc is_pawn
    jmp check_king
off_bridge:
    jmp next_offset
is_pawn:
    dex
    lda $0100,x
    tay
    dex
    dex
    lda $0100,x
    and #$07
    cmp #$00
    beq pawn_push
    bne pawn_capture
pawn_push:
    tya
    cmp #$00
    bne off_bridge
    jmp check_king
pawn_capture:
    tya
    cmp #$00
    beq off_bridge
check_king:
    tsx
    txa
    clc
    adc #$07
    tax
    lda $0100,x
    and #$07
    cmp #$03
    beq is_king
    jmp make_move
is_king:
    tsx
    inx
    inx
    lda #$7f
    sta $0100,x
    jmp return
make_move:
    tsx
    txa
    clc
    adc #$0a
    tax
    ldy $0100,x
    dex
    lda $0100,x
    sta board,y
    inx
    inx
    ldy $0100,x
    lda #$00
    sta board,y
    lda #$18
    sec
    sbc side
    sta side
recursion:
    tsx
    txa
    clc
    adc #$0c
    tax
    lda $0100,x
    sec
    sbc #$01
    jsr search
    tsx
    txa
    sec
    sbc #$0c
    tax
    lda #$00
    sec
    sbc $0100,x
    sta score
take_back:
    tsx
    txa
    clc
    adc #$0a
    tax
    ldy $0100,x
    dex
    dex
    dex
    lda $0100,x
    sta board,y
    inx
    inx
    inx
    inx
    ldy $0100,x
    dex
    dex
    lda $0100,x
    sta board,y
    lda #$18
    sec
    sbc side
    sta side
compare_score:
    tsx
    inx
    lda $0100,x
    sec
    sbc score
    bvc done_cmp
    eor #$80
done_cmp:
    bmi update_score
    jmp cont
update_score:
    lda score
    sta $0100,x
    tsx
    txa
    clc
    adc #$0b
    tax
    lda $0100,x
    sta tsrc
    dex
    lda $0100,x
    sta tdst
    tsx
    inx
    inx
    inx
    lda tdst
    sta $0100,x
    inx
    lda tsrc
    sta $0100,x
cont:
    tsx
    txa
    clc
    adc #$07
    tax
    lda $0100,x
    tay
    inx
    lda $0100,x
    sec
    cmp #$03
    bcc is_double
    sec
    cmp #$05
    bcc next_offset
end_slide:
    tya
    cmp #$00
    bne next_offset
    jmp slide_loop
next_offset:
    jmp offset_loop
is_double:
    tsx
    txa
    clc
    adc #$0a
    tax
    lda $0100,x
    and #$70
    clc
    adc side
    adc side
    adc side
    adc side
    adc side
    adc side
    cmp #$80
    beq end_slide
    jmp next_offset
next_square:
    tsx
    txa
    clc
    adc #$0b
    tax
    inc $0100,x
    lda $0100,x
    cmp #$80
    bne rep_sq
    beq return_best
rep_sq:
    jmp sq_loop
return_best:
    tsx
    inx
    lda $0100,x
    inx
    sta $0100,x
    tsx
    inx
    inx
    inx
    lda $0100,x
    sta bestdst
    inx
    lda $0100,x
    sta bestsrc
return:
    tsx
    txa
    clc
    adc #$0c
    tax
    txs
    rts

.segment "VECTORS"
    .word halt
    .word reset
    .word halt