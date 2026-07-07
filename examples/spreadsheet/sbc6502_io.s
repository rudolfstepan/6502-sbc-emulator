.export _sbc_getch
.export _sbc_putch

KERNAL_CHROUT   = $C003         ; kernel jump table: JMP CHROUT
UART_DATA       = $8810         ; read = RX byte
UART_SR         = $8811         ; status: bit 3 = RDRF (RX data ready)
UART_RDRF       = $08
VIA_ORA         = $8801         ; Port A with handshake (reading clears CA1)
VIA_IFR         = $880D
CA1_BIT         = $02           ; keyboard latched a byte into ORA

.segment "CODE"

; unsigned char sbc_getch(void)
; Blocking raw key read.  Keys can arrive on either the serial UART (a PC
; terminal over the CH340 link) or the VIA keyboard port (a PS/2 keyboard),
; so we poll both the same way the FPGA kernel's CHRIN does.  We deliberately
; bypass the kernel's screen editor, which would swallow the cursor keys.
_sbc_getch:
@wait:
    lda UART_SR
    and #UART_RDRF
    bne @uart
    lda VIA_IFR
    and #CA1_BIT
    beq @wait
    lda VIA_ORA
    ldx #$00
    rts
@uart:
    lda UART_DATA               ; reading clears RDRF
    ldx #$00
    rts

; void __fastcall__ sbc_putch(unsigned char ch)
; Not used by the sheet UI (it writes VRAM directly), but handy for debugging.
_sbc_putch:
    jmp KERNAL_CHROUT
