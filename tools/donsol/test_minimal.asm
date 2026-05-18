; Absolut Minimal: Direct screen memory write test
.include "sbc_head.asm"

.segment "CODE"

reset:
    sei
    cld
    ldx #$ff
    txs
    
    ; Direct write to screen buffer
    lda #$48                    ; 'H'
    sta $8000
    
    lda #$45                    ; 'E'
    sta $8001
    
    lda #$4c                    ; 'L'
    sta $8002
    
    lda #$4c                    ; 'L'
    sta $8003
    
    lda #$4f                    ; 'O'
    sta $8004
    
    loop:
    jmp loop

; --- Interrupt vectors ---
.segment "VECTORS"
.addr reset               ; NMI
.addr reset               ; RESET  
.addr reset               ; IRQ/BRK
