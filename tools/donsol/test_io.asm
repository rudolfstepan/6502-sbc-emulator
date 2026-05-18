; Test: Keyboard Input to Screen Display
; Simple feedback loop to verify I/O working

.include "sbc_head.asm"
.include "sbc_input.asm"
.include "sbc_video.asm"

.segment "CODE"

; --- Entry point ---
reset:
    sei
    cld
    ldx #$ff
    txs
    
    jsr init_keyboard
    jsr init_video
    
    ; Draw test message
    jsr draw_test_screen
    
    jmp input_loop

; --- Main input loop ---
input_loop:
    jsr readJoy_sbc
    jsr saveJoy_sbc
    
    lda next_input
    cmp #$00
    beq input_loop              ; No input, continue
    
    ; Show what key was pressed
    ldx #$01
    ldy #$05
    jsr print_char
    
    jmp input_loop

; --- Draw test screen ---
draw_test_screen:
    jsr clear_screen
    
    ; Print title
    lda #$54                    ; 'T'
    ldx #$00
    ldy #$00
    jsr print_char
    
    lda #$45                    ; 'E'
    ldx #$01
    ldy #$00
    jsr print_char
    
    lda #$53                    ; 'S'
    ldx #$02
    ldy #$00
    jsr print_char
    
    lda #$54                    ; 'T'
    ldx #$03
    ldy #$00
    jsr print_char
    
    ; Print instructions
    lda #$50                    ; 'P'
    ldx #$00
    ldy #$02
    jsr print_char
    
    lda #$72                    ; 'r'
    ldx #$01
    ldy #$02
    jsr print_char
    
    lda #$65                    ; 'e'
    ldx #$02
    ldy #$02
    jsr print_char
    
    lda #$73                    ; 's'
    ldx #$03
    ldy #$02
    jsr print_char
    
    lda #$73                    ; 's'
    ldx #$04
    ldy #$02
    jsr print_char
    
    lda #$20                    ; ' '
    ldx #$05
    ldy #$02
    jsr print_char
    
    lda #$41                    ; 'A'
    ldx #$06
    ldy #$02
    jsr print_char
    
    lda #$20                    ; ' '
    ldx #$07
    ldy #$02
    jsr print_char
    
    lda #$4b                    ; 'K'
    ldx #$08
    ldy #$02
    jsr print_char
    
    lda #$65                    ; 'e'
    ldx #$09
    ldy #$02
    jsr print_char
    
    lda #$79                    ; 'y'
    ldx #$0a
    ldy #$02
    jsr print_char
    
    rts

; --- Interrupt vectors ---
.segment "VECTORS"
.addr $0000               ; NMI
.addr reset               ; RESET
.addr $0000               ; IRQ
