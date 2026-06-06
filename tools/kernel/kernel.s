; ============================================================
; 6502 SBC Kernel v1.0
; ROM: $C000-$CFFF  (4KB)
;
; Fixed jump table at $C000 (kernel API for BASIC and apps):
;   $C000  JMP INIT        System init / RESET entry
;   $C003  JMP CHROUT      Output char  (A = char)
;   $C006  JMP CHRIN       Input char, blocking + echo  (returns A)
;   $C009  JMP CHRIN_NB    Input char, non-blocking  (A=char, C=1 if ready)
;   $C00C  JMP CLRSCR      Clear screen, home cursor
;   $C00F  JMP STROUT      Print null-terminated string (STRPTR_LO/HI ptr)
;   $C012  JMP NEWLINE     Print CR  ($0D)
;   $C015  JMP BASIC       Start BASIC ROM at $D000
;   $C018  JMP SETCURS     Set cursor  (X=col, Y=row)
;   $C01B  JMP SCROLL      Scroll screen up one line
;
; Zero page (kernel uses $F2-$F7 -- MS BASIC uses only $00-$8B):
;   $F2  SCRPTR_LO  screen pointer, low byte
;   $F3  SCRPTR_HI  screen pointer, high byte
;   $F4  TMPPTR_LO  temp/scroll pointer, low byte
;   $F5  TMPPTR_HI  temp/scroll pointer, high byte
;   $F6  STRPTR_LO  string output pointer, low byte
;   $F7  STRPTR_HI  string output pointer, high byte
;
; Hardware:
;   VIC video RAM  $8000-$87FF  (40 x 25 = 1000 bytes)
;   VIA 6522       $8800-$880F  (keyboard on Port A / CA1)
; ============================================================

COLS        = 40
ROWS        = 25

VIC_BASE    = $8000
VIA_ORA     = $8801
VIA_DDRA    = $8803
VIA_IFR     = $880D
VIA_IER     = $880E
CA1_BIT     = $02

DISK_BASE   = $8820
DISK_CMD    = $8820
DISK_STATUS = $8821
DISK_ADDR_LO = $8822
DISK_ADDR_HI = $8823
DISK_LEN_LO = $8824
DISK_LEN_HI = $8825
DISK_ACT_LO = $8826
DISK_ACT_HI = $8827

VIC_GFX_MODE = $9000
VIC_CURSOR_X = $9001
VIC_CURSOR_Y = $9002

DISK_CMD_DIR = $03
DISK_ST_OK   = $02

CURSOR_X    = VIC_CURSOR_X
CURSOR_Y    = VIC_CURSOR_Y
SCRPTR_LO   = $F2
SCRPTR_HI   = $F3
TMPPTR_LO   = $F4
TMPPTR_HI   = $F5
STRPTR_LO   = $F6
STRPTR_HI   = $F7

CMD_BUF     = $0200     ; command line buffer in page 2 (64 bytes)
CMD_MAX     = 38        ; max usable chars per command line

BASIC_ENTRY = $D000     ; BASIC ROM entry point

; ============================================================
; JUMP TABLE  -- placed first so it lands exactly at $C000
; ============================================================
.segment "JUMPTAB"
    jmp INIT            ; $C000
    jmp CHROUT          ; $C003
    jmp CHRIN           ; $C006
    jmp CHRIN_NB        ; $C009
    jmp CLRSCR          ; $C00C
    jmp STROUT          ; $C00F
    jmp NEWLINE         ; $C012
    jmp BASIC           ; $C015
    jmp SETCURS         ; $C018
    jmp SCROLL          ; $C01B
NMI_HANDLER:
    rti                 ; $C01E - NMI: ignore
IRQ_HANDLER:
    rti                 ; $C01F - IRQ: ignore (kernel uses polling, not interrupts)

; ============================================================
; CODE
; ============================================================
.segment "CODE"

; ------------------------------------------------------------
; INIT -- system initialisation, entered on RESET
; ------------------------------------------------------------
.proc INIT
    ldx #$FF
    txs                     ; init stack pointer
    lda #$00
    sta VIA_DDRA            ; VIA Port A = all input (keyboard)
    ; VIA IER left at $00 -- all VIA interrupts disabled.
    ; The kernel polls IFR directly (CHRIN_NB), so no CPU IRQ is needed.
    ; Enabling CA1 in IER caused BASIC to crash: BASIC calls CLI in its
    ; float/time routines, which lets the pending keyboard IRQ fire and
    ; jump to the RESET vector ($C000 = INIT), resetting the system.
    jsr CLRSCR
    jsr show_welcome
    ; Auto-start BASIC (like C64)
    jmp BASIC               ; jump to BASIC ROM - never return
.endproc

; ------------------------------------------------------------
; CHROUT -- write character A to VIC screen at cursor position
; Preserves: X, Y registers (required for MS BASIC and kernel compatibility)
; ------------------------------------------------------------
.proc CHROUT
    ; Save registers at entry
    pha                     ; save A
    txa
    pha                     ; save X
    tya
    pha                     ; save Y
    
    ; Get A back for comparison
    tsx
    lda $0103,x             ; peek at saved A (3 bytes down from SP)
    
    cmp #$0D
    beq newline
    cmp #$0A
    beq done                ; ignore LF (0x0A) - only CR (0x0D) triggers newline
    cmp #$08
    beq backspace
    
    ; --- normal printable character ---
    jsr calc_ptr
    tsx
    lda $0103,x             ; get saved A
    ldy #0
    sta (SCRPTR_LO),y      ; write character
    inc CURSOR_X
    lda CURSOR_X
    cmp #COLS
    bcc done
    ; fall through to newline
newline:
    lda #0
    sta CURSOR_X
    inc CURSOR_Y
    lda CURSOR_Y
    cmp #ROWS
    bcc done
    jsr SCROLL
    lda #(ROWS-1)
    sta CURSOR_Y
    jmp done
    
backspace:
    lda CURSOR_X
    beq done
    dec CURSOR_X
    jsr calc_ptr
    lda #$20
    ldy #0
    sta (SCRPTR_LO),y
    jmp done
    
done:
    ; Restore registers (reverse order)
    pla
    tay
    pla
    tax
    pla                     ; restore A
    rts
.endproc

; ------------------------------------------------------------
; CHRIN -- blocking keyboard read with echo; returns char in A
;          Converts lowercase a-z to uppercase A-Z
; ------------------------------------------------------------
.proc CHRIN
loop:
    jsr CHRIN_NB
    bcc loop
    pha             ; save the character (CHROUT will clobber A)
    jsr CHROUT      ; echo
    pla             ; restore original character into A
    ; convert lowercase to uppercase (a-z -> A-Z)
    cmp #'a'
    bcc done
    cmp #'z'+1
    bcs done
    and #$DF        ; clear bit 5 -> uppercase
done:
    rts
.endproc

; ------------------------------------------------------------
; CHRIN_NB -- non-blocking keyboard read
;             A = char, C = 1 if a key was available
; ------------------------------------------------------------
.proc CHRIN_NB
    lda VIA_IFR
    and #CA1_BIT
    beq nothing
    lda VIA_ORA
    sec
    rts
nothing:
    clc
    rts
.endproc

; ------------------------------------------------------------
; CLRSCR -- fill VIC RAM with spaces, reset cursor to (0,0)
; ------------------------------------------------------------
.proc CLRSCR
    lda #<VIC_BASE
    sta SCRPTR_LO
    lda #>VIC_BASE
    sta SCRPTR_HI
    lda #$20                ; space character
    ldy #0
    ldx #8                  ; 8 x 256 = 2048 bytes
loop:
    sta (SCRPTR_LO),y
    iny
    bne loop
    inc SCRPTR_HI
    dex
    bne loop
    lda #0
    sta CURSOR_X
    sta CURSOR_Y
    rts
.endproc

; ------------------------------------------------------------
; STROUT -- print null-terminated string
;           A = string address low byte
;           Y = string address high byte
; Preserves: none
; Note: Compatible with MS BASIC calling convention
; ------------------------------------------------------------
.proc STROUT
    sta STRPTR_LO           ; store pointer
    sty STRPTR_HI
loop:
    ldy #0
    lda (STRPTR_LO),y       ; read current byte
    beq done
    jsr CHROUT
    inc STRPTR_LO           ; advance pointer
    bne loop
    inc STRPTR_HI
    jmp loop
done:
    rts
.endproc

; ------------------------------------------------------------
; NEWLINE -- print a carriage-return character
; ------------------------------------------------------------
.proc NEWLINE
    lda #$0D
    jmp CHROUT
.endproc

; ------------------------------------------------------------
; BASIC -- hand control to BASIC ROM at $D000
; ------------------------------------------------------------
.proc BASIC
    jsr BASIC_ENTRY         ; JSR so BYE can return to kernel
    rts
.endproc

; ------------------------------------------------------------
; SETCURS -- set cursor position  (X = column, Y = row)
; ------------------------------------------------------------
.proc SETCURS
    cpx #COLS
    bcs done
    cpy #ROWS
    bcs done
    stx CURSOR_X
    sty CURSOR_Y
done:
    rts
.endproc

; ------------------------------------------------------------
; SCROLL -- scroll the screen up one line, clear bottom row
; ------------------------------------------------------------
.proc SCROLL
    ; source: row 1  = VIC_BASE + COLS  = $8028
    lda #<(VIC_BASE + COLS)
    sta TMPPTR_LO
    lda #>(VIC_BASE + COLS)
    sta TMPPTR_HI
    ; dest:   row 0  = VIC_BASE         = $8000
    lda #<VIC_BASE
    sta SCRPTR_LO
    lda #>VIC_BASE
    sta SCRPTR_HI
    ; copy 24 * 40 = 960 ($03C0) bytes
    ldy #0
    ldx #0
loop:
    lda (TMPPTR_LO),y
    sta (SCRPTR_LO),y
    iny
    bne no_carry
    inc TMPPTR_HI
    inc SCRPTR_HI
    inx
no_carry:
    cpx #3
    bne loop
    cpy #192                ; $C0 = 960 - 3*256
    bne loop
    ; clear last row: VIC_BASE + 24*40 = $83C0
    lda #<(VIC_BASE + (ROWS-1)*COLS)
    sta SCRPTR_LO
    lda #>(VIC_BASE + (ROWS-1)*COLS)
    sta SCRPTR_HI
    lda #$20
    ldy #0
clr:
    sta (SCRPTR_LO),y
    iny
    cpy #COLS
    bne clr
    rts
.endproc

; ------------------------------------------------------------
; calc_ptr -- set SCRPTR = VIC_BASE + CURSOR_Y*COLS + CURSOR_X
;             (internal helper, not in jump table)
; ------------------------------------------------------------
.proc calc_ptr
    lda #<VIC_BASE
    sta SCRPTR_LO
    lda #>VIC_BASE
    sta SCRPTR_HI
    ldy CURSOR_Y
    beq add_x
mul_loop:
    clc
    lda SCRPTR_LO
    adc #COLS
    sta SCRPTR_LO
    bcc no_carry
    inc SCRPTR_HI
no_carry:
    dey
    bne mul_loop
add_x:
    clc
    lda SCRPTR_LO
    adc CURSOR_X
    sta SCRPTR_LO
    bcc done
    inc SCRPTR_HI
done:
    rts
.endproc

; ------------------------------------------------------------
; show_welcome -- print the startup banner
; ------------------------------------------------------------
.proc show_welcome
    lda #<welcome_str
    ldy #>welcome_str
    jsr STROUT
    rts
.endproc

; ------------------------------------------------------------
; cmd_loop -- main kernel command interpreter (infinite loop)
; ------------------------------------------------------------
.proc cmd_loop
loop:
    lda #<prompt_str
    ldy #>prompt_str
    jsr STROUT
    jsr read_line
    jsr exec_cmd
    jmp loop
.endproc

; ------------------------------------------------------------
; read_line -- read keyboard input into CMD_BUF
;              max CMD_MAX chars, converts to uppercase
;              null-terminates the buffer
; ------------------------------------------------------------
.proc read_line
    ldx #0
loop:
    jsr CHRIN               ; blocking read + echo
    cmp #$0D
    beq done
    cmp #$08                ; backspace?
    beq backspace
    cpx #CMD_MAX            ; buffer full?
    bcs loop
    ; convert lowercase to uppercase
    cmp #'a'
    bcc store
    cmp #'z'+1
    bcs store
    and #$DF                ; clear bit 5 -> uppercase
store:
    sta CMD_BUF,x
    inx
    jmp loop
backspace:
    cpx #0
    beq loop
    dex
    jmp loop
done:
    lda #0
    sta CMD_BUF,x           ; null-terminate
    ; no extra NEWLINE here -- CHRIN already echoed the CR
    rts
.endproc

; ------------------------------------------------------------
; exec_cmd -- parse CMD_BUF and execute the command
; ------------------------------------------------------------
.proc exec_cmd
    lda CMD_BUF
    beq done                ; empty input -> ignore

    ; ---- BASIC ----
    ldx #0
cmp_basic:
    lda cmd_basic_str,x
    beq basic_end
    cmp CMD_BUF,x
    bne try_help
    inx
    jmp cmp_basic
basic_end:
    lda CMD_BUF,x
    bne try_help
    jsr BASIC               ; hand off to MS BASIC
    jmp done

    ; ---- HELP ----
try_help:
    ldx #0
cmp_help:
    lda cmd_help_str,x
    beq help_end
    cmp CMD_BUF,x
    bne try_cls
    inx
    jmp cmp_help
help_end:
    lda CMD_BUF,x
    bne try_cls
    lda #<help_str
    ldy #>help_str
    jsr STROUT
    jmp done

    ; ---- CLS ----
try_cls:
    ldx #0
cmp_cls:
    lda cmd_cls_str,x
    beq cls_end
    cmp CMD_BUF,x
    bne try_dir
    inx
    jmp cmp_cls
cls_end:
    lda CMD_BUF,x
    bne try_dir
    jsr CLRSCR
    jmp done

    ; ---- DIR ----
try_dir:
    ldx #0
cmp_dir:
    lda cmd_dir_str,x
    beq dir_end
    cmp CMD_BUF,x
    bne try_unknown
    inx
    jmp cmp_dir
dir_end:
    lda CMD_BUF,x
    bne try_unknown
    jsr do_dir
    jmp done

    ; ---- unknown ----
try_unknown:
    lda #<unknown_str
    ldy #>unknown_str
    jsr STROUT
done:
    rts
.endproc

; ------------------------------------------------------------
; do_dir -- execute DIR command via disk device
; ------------------------------------------------------------
.proc do_dir
    ; Setup disk device to write directory listing to $0400
    lda #$00
    sta DISK_ADDR_LO
    lda #$04
    sta DISK_ADDR_HI
    
    ; Max 1024 bytes for directory listing
    lda #$00
    sta DISK_LEN_LO
    lda #$04
    sta DISK_LEN_HI
    
    ; Execute DIR command
    lda #DISK_CMD_DIR
    sta DISK_CMD
    
    ; Check status
    lda DISK_STATUS
    and #DISK_ST_OK
    beq dir_error
    
    ; Print directory listing from $0400
    lda #<dir_header
    ldy #>dir_header
    jsr STROUT
    
    ; Print files from $0400
    lda #$00
    ldy #$04
    jsr STROUT
    rts

dir_error:
    lda #<dir_err_str
    ldy #>dir_err_str
    jsr STROUT
    rts
.endproc

; ============================================================
; STRING DATA
; ============================================================
.segment "RODATA"

cmd_basic_str: .byte "BASIC", 0
cmd_help_str:  .byte "HELP",  0
cmd_cls_str:   .byte "CLS",   0
cmd_dir_str:   .byte "DIR",   0

dir_header:
    .byte $0D, " DIRECTORY:", $0D, 0

dir_err_str:
    .byte " DIR ERROR", $0D, 0

welcome_str:
    .byte $0D
    .byte " ***  6502 SBC - 32K RAM SYSTEM  ***", $0D
    .byte " KERNEL V1.0", $0D
    .byte $0D
    .byte 0

prompt_str:
    .byte "> ", 0

help_str:
    .byte $0D
    .byte " AVAILABLE COMMANDS:", $0D
    .byte "   BASIC  -  START BASIC ROM", $0D
    .byte "   DIR    -  SHOW DISK FILES", $0D
    .byte "   CLS    -  CLEAR SCREEN", $0D
    .byte "   HELP   -  SHOW THIS HELP", $0D
    .byte $0D
    .byte 0

unknown_str:
    .byte " ?UNKNOWN COMMAND", $0D
    .byte 0
