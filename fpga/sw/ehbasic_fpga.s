; ============================================================
; EhBASIC V2.22 — FPGA UART port
; ROM segment: $D000-$FFFF (12 KB), placed inside the 16 KB
; shadow ROM ($C000-$FFFF) that the UART monitor loads.
;
; I/O model:
;   VEC_IN  ($E2 ZP BRAM) -> KERNAL_CHRIN_NB ($C009)
;                            reads UART RDRF first, falls back to VIA CA1
;   VEC_OUT ($E4 ZP BRAM) -> KERNAL_CHROUT ($C003)
;                            writes to VIC VRAM (VGA) AND mirrors to UART
;                            preserves X, Y; handles $0D->newline, drops $0A
;
; Vectors are in ZP BRAM, NOT page-2 SDRAM.  JMP (VEC_OUT) reads from
; ZP BRAM (single-cycle, no wait states) — avoids SDRAM timing window.
;
; RAM available to BASIC: $0200-$7FFF (~31.5 KB)
;   Ram_top is patched to $8000 by build_fpga_ehbasic.py
;   (above $7FFF: VIC VRAM $8000, VIA $8800, UART $8810, etc.)
;
; Disk commands LOAD/SAVE are stubbed — disk device not wired
; to the FPGA monitor path in this build.
;
; Diagnostic sequence on UART at startup (visible in terminal):
;   *     kernel CLRSCR alive
;   A     CLRSCR returned
;   R     all ZP BRAM vectors written
;   S     vector setup complete, about to enter final boot checks
;   H     final boot check reached
;   U     entering EhBASIC LAB_COLD
;
; Build:
;   python tools/build_fpga_ehbasic.py
; Upload + run:
;   python tools/upload_monitor_hex.py tools/roms/fpga_ehbasic_16kb.rom \
;       --port COM15 --baud 230400 --address 0xC000 --run --verbose
; ============================================================

; Kernel jump table (kernel ROM at $C000-$CFFF)
KERNAL_CHROUT   = $C003     ; write char A to VIC + mirror to UART
KERNAL_CHRIN    = $C006     ; blocking read + echo (uppercase)
KERNAL_CHRIN_NB = $C009     ; non-blocking: A=char, C=1 ready
KERNAL_CLRSCR   = $C00C     ; clear VIC screen, home cursor

; UART hardware registers
UART_DATA   = $8810         ; write = TX byte, read = RX byte
UART_SR     = $8811         ; bit4 = TDRE (TX ready), bit3 = RDRF (RX data)
UART_TDRE   = $10
UART_RDRF   = $08

; EhBASIC I/O vectors — defined in basic.asm (patched by build_fpga_ehbasic.py
; to ZP BRAM instead of page-2 SDRAM, to avoid T65 JMP-indirect timing bug).
; EhBASIC marks $E2-$EE as "unused"; kernel uses only $F2-$F7.
; VEC_CC=$EA  VEC_IN=$E2  VEC_OUT=$E4  VEC_LD=$E6  VEC_SV=$E8  (after patch)

; IRQ_vec stays at $020D so basic.asm's Ibuffs=IRQ_vec+$14=$0221 (SDRAM
; input buffer) stays correct.  The actual interrupt VECTORS point to
; IRQ_CODE / NMI_CODE which live in ROM — no SDRAM copy needed.
IRQ_vec     = $020D
NMI_FLAG_ZP = $DC
IRQ_FLAG_ZP = $DF

; ============================================================
.segment "EHBASIC"

; ============================================================
; RESET_ENTRY — CPU reset vector lands here (via kernel INIT
; at $C000 which sets up VIA/VIC then JSRs to $D000).
; ============================================================
RESET_ENTRY:
    sei
    ldx #$FF
    txs                         ; re-init stack (harmless if kernel did it)

    jsr KERNAL_CLRSCR           ; clear VIC screen, sends '*' on UART

    ; Diag A: CLRSCR returned
    lda #'A'
    jsr EHB_UART_CHROUT

    ; Install EhBASIC I/O vectors in ZP BRAM ($E2-$E9).
    ; ZP writes go to FPGA BRAM — single cycle, no wait states.
    ; LAB_COLD only touches $0200-$0204 (PG2_TABS), so these survive
    ; across EhBASIC cold/warm starts.
    lda #<KERNAL_CHRIN_NB
    sta VEC_IN
    lda #>KERNAL_CHRIN_NB
    sta VEC_IN+1

    lda #<KERNAL_CHROUT
    sta VEC_OUT
    lda #>KERNAL_CHROUT
    sta VEC_OUT+1

    lda #<EHB_DISK_STUB
    sta VEC_LD
    lda #>EHB_DISK_STUB
    sta VEC_LD+1

    lda #<EHB_DISK_STUB
    sta VEC_SV
    lda #>EHB_DISK_STUB
    sta VEC_SV+1

    ; VEC_CC ($EA ZP BRAM) — CTRL-C check called from BASIC inner loop.
    ; Same T65 JMP-indirect timing fix as VEC_IN/OUT/LD/SV.
    ; CTRLC is the default ctrl-c handler defined in basic.asm.
    lda #<CTRLC
    sta VEC_CC
    lda #>CTRLC
    sta VEC_CC+1

    ; Diag R: all ZP vector writes done
    lda #'R'
    jsr EHB_UART_CHROUT

    ; Diag S+H: UART-only startup markers. Keep these off VEC_OUT so the
    ; first visible EhBASIC screen starts cleanly at the home position.
    lda #'S'
    jsr EHB_UART_CHROUT
    lda #'H'
    jsr EHB_UART_CHROUT
    lda #'U'
    jsr EHB_UART_CHROUT

    jmp LAB_COLD                ; EhBASIC cold start (never returns)

; ============================================================
; IRQ / NMI handlers — live in ROM (shadow BRAM), not SDRAM.
; $FFFE points here directly; no SDRAM copy needed.
; Update IrqBase/NmiBase (ZP $DF/$DC) flags for EhBASIC's ON IRQ/NMI.
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
IRQ_NMI_CODE_END:   ; (kept for size reference only)

; ============================================================
; EHB_DISK_STUB — replaces LOAD and SAVE on FPGA.
; No disk device is mapped through the UART monitor path.
; ============================================================
EHB_DISK_STUB:
    ldx #0
disk_stub_loop:
    lda msg_no_disk,x
    beq disk_stub_done
    jsr EHB_UART_CHROUT
    inx
    bne disk_stub_loop
disk_stub_done:
    rts

msg_no_disk:
    .byte $0D, $0A, "?DISK NOT AVAILABLE", $0D, $0A, $00

; ============================================================
; EHB_UART_CHROUT — direct UART TX, used as EhBASIC VEC_OUT.
; A = character.  $0D -> CR+LF;  $0A -> ignored.
; Polls TDRE (bit4 of UART_SR) before each byte.
; ============================================================
EHB_UART_CHROUT:
    cmp #$0A
    beq uc_done                 ; drop bare LF (CR already sends CR+LF)
    pha
    cmp #$0D
    bne uc_char
uc_cr_wait:
    lda UART_SR
    and #UART_TDRE
    beq uc_cr_wait
    lda #$0D
    sta UART_DATA
uc_lf_wait:
    lda UART_SR
    and #UART_TDRE
    beq uc_lf_wait
    lda #$0A
    sta UART_DATA
    pla
    rts
uc_char:
uc_char_wait:
    lda UART_SR
    and #UART_TDRE
    beq uc_char_wait
    pla
    sta UART_DATA
uc_done:
    rts

; ============================================================
; EhBASIC V2.22 source (patched by build_fpga_ehbasic.py)
; ============================================================
.include "basic.asm"

; ============================================================
; 6502 interrupt vectors — must land at $FFFA-$FFFF.
; Both handlers live in ROM (shadow BRAM) — no SDRAM, no wait states.
; ============================================================
.segment "VECTORS"
    .word   NMI_CODE            ; $FFFA NMI vector -> ROM handler
    .word   RESET_ENTRY         ; $FFFC RESET vector
    .word   IRQ_CODE            ; $FFFE IRQ vector -> ROM handler
