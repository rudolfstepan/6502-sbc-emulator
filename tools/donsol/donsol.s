; Donsol ROM for SBC Emulator

.segment "CODE"

; Entry point
.org $8000
reset:
    jsr init
main_loop:
    jsr update
    jsr render
    jmp main_loop

; Initialize game state
init:
    rts

; Update game logic
update:
    rts

; Render screen
render:
    rts

; Interrupt vectors
.org $FFFA
.word 0          ; NMI vector
.word reset      ; Reset vector
.word 0          ; IRQ/BRK vector