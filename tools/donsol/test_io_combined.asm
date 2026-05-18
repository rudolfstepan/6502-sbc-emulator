; I/O Test: Display + Keyboard Together
.include "sbc_head.asm"
.include "sbc_input.asm"
.include "sbc_video.asm"

.segment "CODE"

reset:
    sei
    cld
    ldx #$ff
    txs
    
    jsr init_keyboard
    jsr init_video
    
    ; Draw "PRESS KEY"
    lda #$50                    ; 'P'
    ldx #$08
    ldy #$05
    jsr print_char
    
    lda #$52                    ; 'R'
    ldx #$09
    ldy #$05
    jsr print_char
    
    lda #$45                    ; 'E'
    ldx #$0a
    ldy #$05
    jsr print_char
    
    lda #$53                    ; 'S'
    ldx #$0b
    ldy #$05
    jsr print_char
    
    lda #$53                    ; 'S'
    ldx #$0c
    ldy #$05
    jsr print_char
    
    lda #$20                    ; ' '
    ldx #$0d
    ldy #$05
    jsr print_char
    
    lda #$4b                    ; 'K'
    ldx #$0e
    ldy #$05
    jsr print_char
    
    lda #$45                    ; 'E'
    ldx #$0f
    ldy #$05
    jsr print_char
    
    lda #$59                    ; 'Y'
    ldx #$10
    ldy #$05
    jsr print_char

loop:
    jsr readJoy_sbc
    jsr saveJoy_sbc
    
    lda next_input
    cmp #$00
    beq loop
    
    ; Display the button code that was pressed
    lda #$42                    ; 'B'
    ldx #$00
    ldy #$10
    jsr print_char
    
    lda #$55                    ; 'U'
    ldx #$01
    ldy #$10
    jsr print_char
    
    lda #$54                    ; 'T'
    ldx #$02
    ldy #$10
    jsr print_char
    
    lda #$3d                    ; '='
    ldx #$03
    ldy #$10
    jsr print_char
    
    lda next_input
    jsr hex_to_ascii
    ldx #$04
    ldy #$10
    jsr print_char
    
    lda #$00
    sta next_input
    
    jmp loop

.segment "VECTORS"
.addr reset
.addr reset
.addr reset
