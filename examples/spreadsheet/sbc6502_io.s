.export _sbc_getch
.export _sbc_putch
.export _sbc_basic

KERNAL_CHROUT   = $C003         ; kernel jump table: JMP CHROUT
KERNAL_BASIC    = $F015         ; FPGA kernel jump table: start EhBASIC
KBD_STATUS      = $8820         ; FPGA PS/2 keyboard status, bit 0 = key_ready
KBD_ASCII       = $8823         ; FPGA PS/2 ASCII byte, read clears key_ready
KBD_READY       = $01
VIA_ORA         = $8801         ; Port A with handshake (reading clears CA1)
VIA_IFR         = $880D
CA1_BIT         = $02           ; keyboard latched a byte into ORA

.segment "CODE"

; unsigned char sbc_getch(void)
; Blocking raw key read from the FPGA PS/2 register path, with VIA fallback for
; the emulator.  We deliberately bypass the kernel's screen editor, which would
; swallow the cursor keys.
_sbc_getch:
@wait:
    lda KBD_STATUS
    and #KBD_READY
    beq @try_via
    lda KBD_ASCII
    beq @wait
    ldx #$00
    rts
@try_via:
    lda VIA_IFR
    and #CA1_BIT
    beq @wait
    lda VIA_ORA
    ldx #$00
    rts

; void __fastcall__ sbc_putch(unsigned char ch)
; Not used by the sheet UI (it writes VRAM directly), but handy for debugging.
_sbc_putch:
    jmp KERNAL_CHROUT

; void sbc_basic(void)
; Leave the application and restart EhBASIC.  This is used instead of simply
; returning from main so UART-monitor launches (G $1000) have a valid exit too.
_sbc_basic:
    jmp KERNAL_BASIC
