; ============================================================
; 6502 SBC Kernel interface for MS BASIC
; All I/O is delegated to the kernel via the jump table at $C000
; ============================================================
.segment "EXTRA"
.export MONRDKEY_NB, MONRDKEY, MONCOUT, CLS

; Kernel jump table (fixed addresses in kernel ROM)
KERNAL_CHROUT   = $C003     ; output character (A = char)
KERNAL_CHRIN    = $C006     ; input character, blocking + echo (returns A)
KERNAL_CHRIN_NB = $C009     ; input character, non-blocking (A=char, C=ready)
KERNAL_CLRSCR   = $C00C     ; clear screen and home cursor

; MONCOUT -- output character to screen via kernel
MONCOUT:
        jmp KERNAL_CHROUT

; MONRDKEY -- blocking keyboard read with echo via kernel
MONRDKEY:
        jmp KERNAL_CHRIN

; MONRDKEY_NB -- non-blocking keyboard read via kernel
MONRDKEY_NB:
        jmp KERNAL_CHRIN_NB

; CLS -- clear screen and home cursor
CLS:
        jmp KERNAL_CLRSCR

; Screen/keyboard init and I/O routines live entirely in the kernel.
