; ============================================================
; EhBASIC V2.22 ROM for SBC6502 - ca65 build entry
; ROM occupies $D000-$FFFF (12KB).
;
; Kernel jump table (kernel ROM at $C000-$CFFF):
;   $C003  CHROUT       - output char A to VIC screen
;   $C006  CHRIN        - blocking keyboard read + echo (returns A)
;   $C009  CHRIN_NB     - non-blocking keyboard read (A=char, C=1 ready)
;   $C00C  CLRSCR       - clear screen and home cursor
;
; EhBASIC page-2 I/O vectors (in SRAM - set by RESET_ENTRY):
;   $0205  VEC_IN   -> KERNAL_CHRIN_NB  (non-halting scan)
;   $0207  VEC_OUT  -> KERNAL_CHROUT    (character output)
;   $0209  VEC_LD   -> STUB_RTS         (load stub)
;   $020B  VEC_SV   -> STUB_RTS         (save stub)
;
; Note: EhBASIC's PG2_TABS only copies 5 bytes to $0200 ($0200-$0204),
; so our pre-set values at $0205-$020C are NOT overwritten by LAB_COLD.
; ============================================================

; Kernel addresses
KERNAL_CHROUT   = $C003
KERNAL_CHRIN    = $C006
KERNAL_CHRIN_NB = $C009
KERNAL_CLRSCR   = $C00C

; EhBASIC page-2 vector addresses (written to SRAM at startup)
VEC_IN_LO   = $0205
VEC_IN_HI   = $0206
VEC_OUT_LO  = $0207
VEC_OUT_HI  = $0208
VEC_LD_LO   = $0209
VEC_LD_HI   = $020A
VEC_SV_LO   = $020B
VEC_SV_HI   = $020C

; EhBASIC's minimal monitor places editable IRQ/NMI stubs in page 2.
IRQ_vec     = $020D
NMI_vec     = IRQ_vec+$0A
NMI_FLAG_ZP = $DC
IRQ_FLAG_ZP = $DF

.segment "EHBASIC"

; ============================================================
; RESET_ENTRY -- 6502 RESET vector points here
; Sets EhBASIC I/O vectors then jumps to EhBASIC cold start.
; ============================================================
RESET_ENTRY:
    sei                         ; disable interrupts
    ldx #$FF
    txs                         ; initialise stack pointer

    jsr KERNAL_CLRSCR           ; clear VIC screen

    ; Set EhBASIC I/O vectors in page-2 SRAM.
    ; LAB_COLD only copies 5 bytes (PG2_TABS: ccflag/ccbyte/ccnull/VEC_CC)
    ; to $0200-$0204, so $0205-$020C are OURS to set here.
    lda #<KERNAL_CHRIN_NB
    sta VEC_IN_LO
    lda #>KERNAL_CHRIN_NB
    sta VEC_IN_HI

    lda #<KERNAL_CHROUT
    sta VEC_OUT_LO
    lda #>KERNAL_CHROUT
    sta VEC_OUT_HI

    lda #<STUB_RTS
    sta VEC_LD_LO
    lda #>STUB_RTS
    sta VEC_LD_HI

    lda #<STUB_RTS
    sta VEC_SV_LO
    lda #>STUB_RTS
    sta VEC_SV_HI

    ldy #IRQ_NMI_CODE_END-IRQ_CODE-1
COPY_IRQ_NMI:
    lda IRQ_CODE,y
    sta IRQ_vec,y
    dey
    bpl COPY_IRQ_NMI

    jmp LAB_COLD                ; EhBASIC cold start (never returns)

; ============================================================
; STUB_RTS -- dummy handler for LOAD and SAVE
; ============================================================
STUB_RTS:
    rts

; ============================================================
; Page-2 IRQ/NMI stubs expected by EhBASIC's original monitor.
; RESET_ENTRY copies these bytes into IRQ_vec/NMI_vec in RAM.
; ============================================================
IRQ_CODE:
    pha
    lda IRQ_FLAG_ZP
    lsr a
    ora IRQ_FLAG_ZP
    sta IRQ_FLAG_ZP
    pla
    rti

NMI_CODE:
    pha
    lda NMI_FLAG_ZP
    lsr a
    ora NMI_FLAG_ZP
    sta NMI_FLAG_ZP
    pla
    rti

IRQ_NMI_CODE_END:

; ============================================================
; EhBASIC V2.22 source (patched by the build script)
; ============================================================
.include "basic.asm"

; ============================================================
; 6502 interrupt vectors at $FFFA-$FFFF
; ============================================================
.segment "VECTORS"
    .word   NMI_vec
    .word   RESET_ENTRY
    .word   IRQ_vec
