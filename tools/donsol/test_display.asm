; Einfacher Test: Nur Bildschirm-Clear und Text
.include "sbc_head.asm"
.include "sbc_video.asm"

.segment "CODE"

reset:
    sei
    cld
    ldx #$ff
    txs
    
    jsr init_video
    
    ; Write "HELLO" at position 10,5
    lda #$48                    ; 'H'
    ldx #$0a
    ldy #$05
    jsr print_char
    
    lda #$45                    ; 'E'
    ldx #$0b
    ldy #$05
    jsr print_char
    
    lda #$4c                    ; 'L'
    ldx #$0c
    ldy #$05
    jsr print_char
    
    lda #$4c                    ; 'L'
    ldx #$0d
    ldy #$05
    jsr print_char
    
    lda #$4f                    ; 'O'
    ldx #$0e
    ldy #$05
    jsr print_char
    
    ; Infinite loop
    loop: jmp loop

; --- Interrupt vectors ---
.segment "VECTORS"
.addr reset               ; NMI at $FFFA
.addr reset               ; RESET at $FFFC  
.addr reset               ; IRQ/BRK at $FFFE
