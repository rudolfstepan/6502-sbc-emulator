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
;   $0209  VEC_LD   -> EHB_LOAD         (load BASIC program)
;   $020B  VEC_SV   -> EHB_SAVE         (save BASIC program)
;
; Note: EhBASIC's PG2_TABS only copies 5 bytes to $0200 ($0200-$0204),
; so our pre-set values at $0205-$020C are NOT overwritten by LAB_COLD.
; ============================================================

; Kernel addresses
KERNAL_CHROUT   = $C003
KERNAL_CHRIN    = $C006
KERNAL_CHRIN_NB = $C009
KERNAL_CLRSCR   = $C00C

; UART hardware registers
UART_DATA   = $8810
UART_SR     = $8811
UART_TDRE   = $10
UART_RDRF   = $08

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

; ============================================================
; Disk device registers (same as MS BASIC port)
; ============================================================
DISK_CMD       = $8820
DISK_STATUS    = $8821
DISK_ADDR_LO   = $8822
DISK_ADDR_HI   = $8823
DISK_LEN_LO    = $8824
DISK_LEN_HI    = $8825
DISK_ACT_LO    = $8826
DISK_ACT_HI    = $8827
DISK_FNAME_IDX = $8829
DISK_FNAME_CHR = $882A

DISK_CMD_SAVE  = $01
DISK_CMD_LOAD  = $02
DISK_CMD_DIR   = $03
DISK_ST_OK     = $02

; ============================================================
; EhBASIC zero-page variables and routines are defined in basic.asm
; (included below).  Key addresses for reference only:
;   ut1_pl=$71, ut1_ph=$72   utility ptr (set by LAB_22B6)
;   Smeml=$79  Smemh=$7A     start of BASIC program
;   Svarl=$7B  Svarh=$7C     start of variables
;   Sstorl=$81 Sstorh=$82    string storage bottom
;   Ememl=$85  Ememh=$86     end of memory
;   str_ln=$AC               string length scratch (FAC1_e)
;   LAB_IGBY=$BC             CHRGET (advance+get byte)
;   LAB_GBYT=$C2             CHRGOT (get current byte)
; ============================================================

; Filename buffer in page 2 SRAM (safe: after input buffer which ends ~$0268)
FNAME_BUF  = $0280
FNAME_MAX  = 31

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

    ; Diagnostic A: CLRSCR returned, about to start SDRAM writes
    lda #'A'
    jsr EHB_UART_CHROUT

    ; Set EhBASIC I/O vectors in page-2 SRAM.
    ; LAB_COLD only copies 5 bytes (PG2_TABS: ccflag/ccbyte/ccnull/VEC_CC)
    ; to $0200-$0204, so $0205-$020C are OURS to set here.
    lda #<KERNAL_CHRIN_NB
    sta VEC_IN_LO
    lda #>KERNAL_CHRIN_NB
    sta VEC_IN_HI

    lda #<EHB_UART_CHROUT
    sta VEC_OUT_LO
    lda #>EHB_UART_CHROUT
    sta VEC_OUT_HI

    lda #<EHB_LOAD
    sta VEC_LD_LO
    lda #>EHB_LOAD
    sta VEC_LD_HI

    lda #<EHB_SAVE
    sta VEC_SV_LO
    lda #>EHB_SAVE
    sta VEC_SV_HI

    ldy #IRQ_NMI_CODE_END-IRQ_CODE-1
COPY_IRQ_NMI:
    lda IRQ_CODE,y
    sta IRQ_vec,y
    dey
    bpl COPY_IRQ_NMI

    ; Diagnostic R: all SDRAM vector writes done
    lda #'R'
    jsr EHB_UART_CHROUT

    ; Diagnostic S: test indirect call via JMP ($0207) = same as EhBASIC V_OUTP
    lda #'S'
    jsr EHB_UART_CHROUT
    lda #'H'                    ; char to output via indirect path
    jsr diag_v_outp             ; JSR pushes return addr, then JMP ($0207)
    ; If 'H' printed: indirect jump + EHB_UART_CHROUT both work
    lda #'U'                    ; U = survived indirect test, about to jmp LAB_COLD
    jsr EHB_UART_CHROUT

    jmp LAB_COLD                ; EhBASIC cold start (never returns)

diag_v_outp:
    jmp (VEC_OUT_LO)            ; JMP ($0207) - reads both $0207 and $0208 from SDRAM

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
; EHB_LOAD -- handler for EhBASIC LOAD command (via VEC_LD)
;
; Called by EhBASIC's V_LOAD: JMP (VEC_LD)
; At entry, Bpntrl/Bpntrh ($C3/$C4) points to first char after
; the LOAD token (spaces already skipped by dispatch mechanism).
;
; Supports:
;   LOAD          - load "basic.prg" (default)
;   LOAD "NAME"   - load "name.prg"
;   LOAD "$"      - directory listing
; ============================================================
EHB_LOAD:
    jsr LAB_GBYT            ; get current char (after LOAD token)
    beq ehb_load_noname     ; EOL - use default filename
    cmp #':'
    beq ehb_load_noname     ; statement separator - use default

    ; Evaluate the string argument
    jsr LAB_EVEX            ; evaluate expression (backs up Bpntrl by 1, then evaluates)
    jsr LAB_22B6            ; pop string: A=length, ut1_pl=$71=ptr_lo, ut1_ph=$72=ptr_hi

    ; Check for empty string
    tax                     ; X = length
    beq ehb_load_noname

    ; Check for directory: single non-alphanumeric char (e.g. "$")
    cpx #1
    bne ehb_load_copy_fname
    ldy #0
    lda (ut1_pl),y          ; get the single character
    cmp #'A'
    bcc ehb_dir             ; < 'A' -> special / dir
    cmp #'Z'+1
    bcs ehb_dir             ; > 'Z' -> special / dir

ehb_load_copy_fname:
    ; Copy string (A=length on entry here, X=length from above)
    txa                     ; A = length
    cmp #FNAME_MAX
    bcc :+
    lda #FNAME_MAX-1
:   sta str_ln              ; save clamped length as loop counter
    ldy #0
@copy:
    lda (ut1_pl),y
    sta FNAME_BUF,y
    iny
    dec str_ln
    bne @copy
    ; Y = bytes copied
    jsr ehb_add_prg_ext     ; ensure .prg extension, returns Y = total length
    jsr ehb_lowercase       ; convert FNAME_BUF (Y bytes) to lowercase
    jsr ehb_null_term       ; null-terminate at Y
    jsr ehb_write_fname
    jmp ehb_do_load

ehb_dir:
    ; Directory listing: write "dir" or empty name to trigger disk DIR command
    lda #'$'
    sta FNAME_BUF
    lda #0
    sta FNAME_BUF+1
    ldy #1
    jsr ehb_write_fname
    jmp ehb_do_dir

ehb_load_noname:
    jsr ehb_set_default_fname

ehb_do_load:
    lda Smeml
    sta DISK_ADDR_LO
    lda Smemh
    sta DISK_ADDR_HI

    sec
    lda Ememl
    sbc Smeml
    sta DISK_LEN_LO
    lda Ememh
    sbc Smemh
    sta DISK_LEN_HI

    lda #DISK_CMD_LOAD
    sta DISK_CMD

    lda DISK_STATUS
    and #DISK_ST_OK
    beq ehb_load_err

    ; Update BASIC memory pointers: end of program = start + actual bytes loaded
    clc
    lda Smeml
    adc DISK_ACT_LO
    sta Svarl
    sta Sarryl
    sta Earryl
    lda Smemh
    adc DISK_ACT_HI
    sta Svarh
    sta Sarryh
    sta Earryh

    ; Reset string storage to top of memory
    lda Ememl
    sta Sstorl
    lda Ememh
    sta Sstorh

    lda #<MSG_LOADED
    ldy #>MSG_LOADED
    jsr LAB_18C3
    rts

ehb_load_err:
    lda #<MSG_IOERR
    ldy #>MSG_IOERR
    jsr LAB_18C3
    rts

ehb_do_dir:
    lda Smeml
    sta DISK_ADDR_LO
    lda Smemh
    sta DISK_ADDR_HI

    sec
    lda Ememl
    sbc Smeml
    sta DISK_LEN_LO
    lda Ememh
    sbc Smemh
    sta DISK_LEN_HI

    lda #DISK_CMD_DIR
    sta DISK_CMD

    lda DISK_STATUS
    and #DISK_ST_OK
    beq ehb_load_err

    clc
    lda Smeml
    adc DISK_ACT_LO
    sta Svarl
    sta Sarryl
    sta Earryl
    lda Smemh
    adc DISK_ACT_HI
    sta Svarh
    sta Sarryh
    sta Earryh

    lda Ememl
    sta Sstorl
    lda Ememh
    sta Sstorh

    lda #<MSG_LOADED
    ldy #>MSG_LOADED
    jsr LAB_18C3
    rts

; ============================================================
; EHB_SAVE -- handler for EhBASIC SAVE command (via VEC_SV)
;
; Called by EhBASIC's V_SAVE: JMP (VEC_SV)
; At entry, Bpntrl/Bpntrh points to first char after SAVE token.
;
; Supports:
;   SAVE          - save to "basic.prg" (default)
;   SAVE "NAME"   - save to "name.prg"
; ============================================================
EHB_SAVE:
    jsr LAB_GBYT            ; get current char
    beq ehb_save_noname     ; EOL - use default
    cmp #':'
    beq ehb_save_noname

    jsr LAB_EVEX            ; evaluate expression (backs up Bpntrl by 1, then evaluates)
    jsr LAB_22B6            ; A=length, ut1_pl=ptr_lo, ut1_ph=ptr_hi

    tax
    beq ehb_save_noname

    txa                     ; A = length
    cmp #FNAME_MAX
    bcc :+
    lda #FNAME_MAX-1
:   sta str_ln
    ldy #0
@copy:
    lda (ut1_pl),y
    sta FNAME_BUF,y
    iny
    dec str_ln
    bne @copy
    jsr ehb_add_prg_ext
    jsr ehb_lowercase
    jsr ehb_null_term
    jsr ehb_write_fname
    jmp ehb_do_save

ehb_save_noname:
    jsr ehb_set_default_fname

ehb_do_save:
    lda Smeml
    sta DISK_ADDR_LO
    lda Smemh
    sta DISK_ADDR_HI

    sec
    lda Svarl
    sbc Smeml
    sta DISK_LEN_LO
    lda Svarh
    sbc Smemh
    sta DISK_LEN_HI

    lda #DISK_CMD_SAVE
    sta DISK_CMD

    lda DISK_STATUS
    and #DISK_ST_OK
    beq ehb_save_err

    lda #<MSG_SAVED
    ldy #>MSG_SAVED
    jsr LAB_18C3
    rts

ehb_save_err:
    lda #<MSG_IOERR
    ldy #>MSG_IOERR
    jsr LAB_18C3
    rts

; ============================================================
; Shared helper routines
; ============================================================

; ehb_add_prg_ext: append ".prg" to FNAME_BUF if not already present
; Entry: FNAME_BUF contains the filename string, Y = string length
; Exit:  FNAME_BUF has .prg appended if needed, Y = new total length
ehb_add_prg_ext:
    ; Need at least 4 chars to have an extension
    cpy #4
    bcs @check_ext
    jmp @append

@check_ext:
    ; Check last 4 chars for ".prg" (case-insensitive)
    ; Save original length in X
    tya
    tax                     ; X = original length
    dey
    lda FNAME_BUF,y         ; last char = 'G' or 'g'?
    cmp #'G'
    beq @cg
    cmp #'g'
    beq @cg
    bne @append_restore
@cg:
    dey
    lda FNAME_BUF,y         ; = 'R' or 'r'?
    cmp #'R'
    beq @cr
    cmp #'r'
    beq @cr
    bne @append_restore
@cr:
    dey
    lda FNAME_BUF,y         ; = 'P' or 'p'?
    cmp #'P'
    beq @cp
    cmp #'p'
    beq @cp
    bne @append_restore
@cp:
    dey
    lda FNAME_BUF,y         ; = '.'?
    cmp #'.'
    bne @append_restore
    ; Already has .prg - restore Y to original length
    txa                     ; X = original length
    tay
    rts

@append_restore:
    txa                     ; restore original length
    tay

@append:
    lda #'.'
    sta FNAME_BUF,y
    iny
    lda #'p'
    sta FNAME_BUF,y
    iny
    lda #'r'
    sta FNAME_BUF,y
    iny
    lda #'g'
    sta FNAME_BUF,y
    iny
    rts

; ehb_lowercase: convert FNAME_BUF[0..Y-1] to lowercase
; Entry: Y = length  Exit: Y preserved, FNAME_BUF converted
ehb_lowercase:
    sty str_ln              ; save length
    ldx #0
@lc_loop:
    lda FNAME_BUF,x
    cmp #'A'
    bcc @lc_next
    cmp #'Z'+1
    bcs @lc_next
    ora #$20                ; set bit 5 -> lowercase
    sta FNAME_BUF,x
@lc_next:
    inx
    cpx str_ln
    bcc @lc_loop
    ldy str_ln              ; restore Y
    rts

; ehb_null_term: null-terminate FNAME_BUF at position Y
ehb_null_term:
    lda #0
    sta FNAME_BUF,y
    rts

; ehb_write_fname: write FNAME_BUF to disk device registers
ehb_write_fname:
    ldx #0
@wf_loop:
    lda FNAME_BUF,x
    beq @wf_done
    stx DISK_FNAME_IDX
    sta DISK_FNAME_CHR
    inx
    cpx #FNAME_MAX
    bcc @wf_loop
@wf_done:
    stx DISK_FNAME_IDX
    lda #0
    sta DISK_FNAME_CHR
    rts

; ehb_set_default_fname: set filename to "basic.prg" and write to disk
ehb_set_default_fname:
    ldx #0
@sdf_loop:
    lda default_fname,x
    sta FNAME_BUF,x
    beq @sdf_done
    inx
    bne @sdf_loop
@sdf_done:
    jsr ehb_write_fname
    rts

; ============================================================
; Data: messages and default filename
; ============================================================
default_fname:
    .byte "basic.prg", 0

MSG_SAVED:
    .byte $0D, $0A
    .byte "SAVED"
    .byte $0D, $0A, 0

MSG_LOADED:
    .byte $0D, $0A
    .byte "LOADED"
    .byte $0D, $0A, 0

MSG_IOERR:
    .byte $0D, $0A
    .byte "I/O ERROR"
    .byte $0D, $0A, 0

; ============================================================
; EHB_UART_CHROUT -- direct UART character output
; Called via JMP ($0207) from EhBASIC's output dispatch.
; A = character on entry.  $0D -> CR+LF;  $0A -> ignored.
; ============================================================
EHB_UART_CHROUT:
    cmp #$0A
    beq uc_done
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
