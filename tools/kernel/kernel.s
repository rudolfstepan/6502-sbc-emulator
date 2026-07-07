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
; EhBASIC owns almost all of zero page up to $FF. It marks $EB-$EE as unused.
;   $EB  STRPTR_LO  STROUT temporary pointer, low byte  (saved/restored)
;   $EC  CURSOR_X at rest; temporary screen pointer low byte inside CHROUT
;   $ED  CURSOR_Y at rest; temporary screen pointer high byte inside CHROUT
;   $EE  STRPTR_HI  STROUT temporary pointer, high byte (saved/restored)
;   $EF+ EhBASIC Decss (number-to-decimal buffer) — DO NOT USE in kernel
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

UART_DATA   = $8810         ; write = TX byte, read = RX byte
UART_SR     = $8811         ; bit 4 = TDRE (TX ready), bit 3 = RDRF (RX data)
UART_TDRE   = $10
UART_RDRF   = $08

DISK_CMD_DIR = $03
DISK_ST_OK   = $02

; Cursor position is tracked in ZP BRAM and mirrored to the VIC cursor
; registers ($9001/$9002), where the text VIC draws a blinking cursor cell.
CURSOR_X    = $EC
CURSOR_Y    = $ED
SCRPTR_LO   = $EC
SCRPTR_HI   = $ED
; $EE is free (EhBASIC marks unused); $EF = EhBASIC Decss (number-to-string
; buffer) — DO NOT USE $EF or above for kernel vars: PRINT I writes $EF..$F4.
STRPTR_LO   = $EB
STRPTR_HI   = $EE

CMD_BUF     = $0200     ; command line buffer in page 2 (64 bytes)
CMD_MAX     = 38        ; max usable chars per command line

; Screen editor replay buffer.  Used by FPGA keyboard cursor editing: when
; Enter is pressed after moving the hardware cursor, the full screen line
; is read (C64-style), trailing spaces trimmed, and replayed to BASIC one
; character per CHRIN call.  CHROUT suppresses echo while POS < LEN so the
; line is not duplicated on screen.
SCREEN_REPLAY_BUF  = $02C0
SCREEN_EDIT_ACTIVE = $02F0
SCREEN_REPLAY_POS  = $02F1
SCREEN_REPLAY_LEN  = $02F2
SCREEN_REPLAY_CHAR = $02F3
SCREEN_SAVED_X     = $02F4
SCREEN_SAVED_Y     = $02F5
SCREEN_RETURN_CHAR = $02F6
SCREEN_PENDING_CHAR = $02F7
SCREEN_PENDING_FLAG = $02F8

VIC_TEXT_COLOR = $9003          ; foreground color register (0-15)
VIC_BG_COLOR   = $9004          ; background color register (0-15)
VIC_COLOR_BASE = $8400          ; color RAM: per-cell bg[7:4] | fg[3:0]

KEY_CRSR_DOWN  = $11
KEY_HOME       = $13
KEY_CRSR_RIGHT = $1D
KEY_CRSR_UP    = $91
KEY_CLEAR      = $93
KEY_CRSR_LEFT  = $9D
KEY_BACKSPACE  = $08

BASIC_ENTRY = $A000     ; BASIC ROM entry point (EhBASIC relocated to $A000-$CFFF)

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
    lda #$01                ; white
    sta VIC_TEXT_COLOR
    lda #$00                ; black
    sta VIC_BG_COLOR
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
    ; Suppress echo while screen replay is active (POS < LEN).
    ; The final CR has POS == LEN so it passes through normally.
    pha
    lda SCREEN_REPLAY_POS
    cmp SCREEN_REPLAY_LEN
    pla
    bcs no_suppress
    rts
no_suppress:
    ; Save registers at entry
    pha                     ; save A
    txa
    pha                     ; save X
    tya
    pha                     ; save Y

    ; Get A back for comparison
    tsx
    lda $0103,x             ; peek at saved A (3 bytes down from SP)
    jsr uart_put            ; mirror to UART (preserves A, $0D -> CR+LF)

    cmp #$0D
    beq newline_cr
    cmp #$0A
    beq restore             ; ignore LF (0x0A) - only CR (0x0D) triggers newline
    cmp #$08
    beq backspace

    ; --- normal printable character ---
    ldx CURSOR_X
    ldy CURSOR_Y
    tya
    pha
    txa
    pha
    jsr calc_ptr_xy
    tsx
    lda $0105,x             ; get saved A below cursor scratch bytes
    jsr to_upper            ; lowercase ASCII overlaps PETSCII graphics
    ldy #0
    sta (SCRPTR_LO),y      ; write character
    jsr write_color_attr   ; write color to $8400+offset
    pla
    tax
    pla
    tay
    inx
    cpx #COLS
    bcc done
    ; fall through to newline
newline:
    ldx #0
    iny
    jmp newline_check
newline_cr:
    ldx #0
    ldy CURSOR_Y
    iny
newline_check:
    cpy #ROWS
    bcc done
    jsr SCROLL
    ldy #(ROWS-1)
    jmp done

backspace:
    ldx CURSOR_X
    beq restore
    dex
    ldy CURSOR_Y
    tya
    pha
    txa
    pha
    jsr calc_ptr_xy
    lda #$20
    ldy #0
    sta (SCRPTR_LO),y
    jsr write_color_attr
    pla
    tax
    pla
    tay

done:
    stx CURSOR_X
    sty CURSOR_Y
    stx VIC_CURSOR_X
    sty VIC_CURSOR_Y
restore:
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
    pha
    lda SCREEN_REPLAY_CHAR
    beq echo
    lda #0
    sta SCREEN_REPLAY_CHAR
    pla
    jmp convert
echo:
    pla
    pha             ; save the character (CHROUT will clobber A)
    jsr CHROUT      ; echo
    pla             ; restore original character into A
convert:
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
    txa
    pha
    tya
    pha

    lda SCREEN_PENDING_FLAG
    beq no_pending
    lda #0
    sta SCREEN_PENDING_FLAG
    lda SCREEN_PENDING_CHAR
    jmp got_char

no_pending:
    jsr replay_next
    bcs got_char

    lda UART_SR             ; check UART RX first
    and #UART_RDRF
    beq try_via
    lda UART_DATA           ; read byte (clears RDRF)
    jsr handle_screen_key
    bcc nothing
    jsr to_upper
    jmp got_char
try_via:
    lda VIA_IFR
    and #CA1_BIT
    beq nothing
    lda VIA_ORA
    jsr handle_screen_key
    bcc nothing
    jsr to_upper
got_char:
    sta SCREEN_RETURN_CHAR
    pla
    tay
    pla
    tax
    lda SCREEN_RETURN_CHAR
    sec
    rts
nothing:
    pla
    tay
    pla
    tax
    clc
    rts
.endproc

; ------------------------------------------------------------
; replay_next -- return the next queued screen-editor character
;                C=1 and A=char if available, C=0 otherwise
; ------------------------------------------------------------
.proc replay_next
    ldx SCREEN_REPLAY_POS
    cpx SCREEN_REPLAY_LEN
    bcc have
    clc
    rts
have:
    lda SCREEN_REPLAY_BUF,x
    inx
    stx SCREEN_REPLAY_POS
    ldx #1
    stx SCREEN_REPLAY_CHAR
    sec
    rts
.endproc

; ------------------------------------------------------------
; handle_screen_key -- consume PETSCII-style screen editor keys
;                      C=0 consumed, C=1 pass A through to BASIC
; ------------------------------------------------------------
.proc handle_screen_key
    cmp #KEY_CRSR_LEFT
    beq cursor_left
    cmp #KEY_CRSR_RIGHT
    bne :+
    jmp cursor_right
:
    cmp #KEY_CRSR_UP
    bne :+
    jmp cursor_up
:
    cmp #KEY_CRSR_DOWN
    bne :+
    jmp cursor_down
:
    cmp #KEY_HOME
    bne :+
    jmp home
:
    cmp #KEY_CLEAR
    bne :+
    jmp clear
:
    cmp #KEY_BACKSPACE
    bne :+
    jmp edit_backspace
:
    cmp #$0D
    bne pass_key
    jmp enter
pass_key:
    ldx SCREEN_EDIT_ACTIVE
    bne edit_printable
    sec
    rts

edit_printable:
    cmp #$20
    bcc pass_printable
    jsr to_upper
    sta SCREEN_RETURN_CHAR
    ldx CURSOR_X
    ldy CURSOR_Y
    stx SCREEN_SAVED_X
    sty SCREEN_SAVED_Y
    jsr calc_ptr_xy
    lda SCREEN_RETURN_CHAR
    ldy #0
    sta (SCRPTR_LO),y
    jsr write_color_attr
    ldx SCREEN_SAVED_X
    ldy SCREEN_SAVED_Y
    inx
    cpx #COLS
    bcc edit_printable_moved
    ldx #0
    iny
    cpy #ROWS
    bcc edit_printable_moved
    ldx #(COLS-1)
    ldy #(ROWS-1)
edit_printable_moved:
    jsr SETCURS
    clc
    rts
pass_printable:
    sec
    rts

cursor_left:
    ldx CURSOR_X
    ldy CURSOR_Y
    cpx #0
    bne left_dec
    cpy #0
    bne left_wrap
    jmp moved
left_wrap:
    ldx #(COLS-1)
    dey
    jmp moved
left_dec:
    dex
    jmp moved

cursor_right:
    ldx CURSOR_X
    ldy CURSOR_Y
    inx
    cpx #COLS
    bcc moved
    ldx #0
    iny
    cpy #ROWS
    bcc moved
    ldx #(COLS-1)
    ldy #(ROWS-1)
    jmp moved

cursor_up:
    ldx CURSOR_X
    ldy CURSOR_Y
    cpy #0
    beq moved
    dey
    jmp moved

cursor_down:
    ldx CURSOR_X
    ldy CURSOR_Y
    iny
    cpy #ROWS
    bcc moved
    ldy #(ROWS-1)
    jmp moved

home:
    ldx #0
    ldy #0
    jmp moved

clear:
    jsr CLRSCR
    clc
    rts

edit_backspace:
    ldx CURSOR_X
    ldy CURSOR_Y
    cpx #0
    bne backspace_left
    cpy #0
    beq edit_backspace_done
    ldx #(COLS-1)
    dey
    jmp backspace_erase
backspace_left:
    dex
backspace_erase:
    stx SCREEN_SAVED_X
    sty SCREEN_SAVED_Y
    jsr SETCURS
    ldx SCREEN_SAVED_X
    ldy SCREEN_SAVED_Y
    jsr calc_ptr_xy
    lda #$20
    ldy #0
    sta (SCRPTR_LO),y
    jsr write_color_attr
    ldx SCREEN_SAVED_X
    ldy SCREEN_SAVED_Y
    jsr SETCURS
    lda #1
    sta SCREEN_EDIT_ACTIVE
edit_backspace_done:
    clc
    rts

moved:
    jsr SETCURS
    lda #1
    sta SCREEN_EDIT_ACTIVE
    clc
    rts

enter:
    lda SCREEN_EDIT_ACTIVE
    bne replay_line
    lda #$0D
    sec
    rts
replay_line:
    jsr build_screen_replay
    rts
.endproc

; ------------------------------------------------------------
; build_screen_replay -- read full screen line, trim trailing spaces, add CR
;                        returns first queued char with C=1
; ------------------------------------------------------------
.proc build_screen_replay
    lda CURSOR_X
    sta SCREEN_SAVED_X
    lda CURSOR_Y
    sta SCREEN_SAVED_Y

    ldx #0
    ldy SCREEN_SAVED_Y
    jsr calc_ptr_xy

    ldy #0
copy:
    cpy #COLS
    beq copied
    lda (SCRPTR_LO),y
    sta SCREEN_REPLAY_BUF,y
    iny
    jmp copy
copied:
    sty SCREEN_REPLAY_LEN

trim:
    lda SCREEN_REPLAY_LEN
    beq add_cr
    tax
    dex
    lda SCREEN_REPLAY_BUF,x
    cmp #$20
    bne add_cr
    dec SCREEN_REPLAY_LEN
    jmp trim

add_cr:
    ldx SCREEN_REPLAY_LEN
    lda #$0D
    sta SCREEN_REPLAY_BUF,x
    inx
    stx SCREEN_REPLAY_LEN
    lda #0
    sta SCREEN_REPLAY_POS
    sta SCREEN_EDIT_ACTIVE

    ldx #0
    ldy SCREEN_SAVED_Y
    jsr SETCURS
    jsr replay_next
    rts
.endproc

; to_upper -- convert a-z to A-Z in A, leave everything else unchanged
.proc to_upper
    cmp #'a'
    bcc done
    cmp #'z'+1
    bcs done
    and #$DF
done:
    rts
.endproc

; ------------------------------------------------------------
; CLRSCR -- fill VIC RAM with spaces, reset cursor to (0,0)
; ------------------------------------------------------------
.proc CLRSCR
    ; Diagnostic: busy-wait for TDRE then send '*' to confirm kernel alive
    pha
clrscr_diag:
    lda UART_SR
    and #UART_TDRE
    beq clrscr_diag
    lda #'*'
    sta UART_DATA
    pla
    ; Fill character area ($8000-$83FF) with spaces
    lda #<VIC_BASE
    sta SCRPTR_LO
    lda #>VIC_BASE
    sta SCRPTR_HI
    lda #$20                ; space character
    ldy #0
    ldx #4                  ; 4 x 256 = 1024 bytes
char_loop:
    sta (SCRPTR_LO),y
    iny
    bne char_loop
    inc SCRPTR_HI
    dex
    bne char_loop
    ; SCRPTR_HI is now $84 (start of color area)
    ; Fill color area ($8400-$87FF) with composed color byte
    lda VIC_BG_COLOR
    asl a
    asl a
    asl a
    asl a
    ora VIC_TEXT_COLOR
    ldy #0
    ldx #4                  ; 4 x 256 = 1024 bytes
color_loop:
    sta (SCRPTR_LO),y
    iny
    bne color_loop
    inc SCRPTR_HI
    dex
    bne color_loop
    lda #0
    sta CURSOR_X
    sta CURSOR_Y
    sta VIC_CURSOR_X
    sta VIC_CURSOR_Y
    sta SCREEN_EDIT_ACTIVE
    sta SCREEN_REPLAY_POS
    sta SCREEN_REPLAY_LEN
    sta SCREEN_REPLAY_CHAR
    sta SCREEN_RETURN_CHAR
    sta SCREEN_PENDING_CHAR
    sta SCREEN_PENDING_FLAG
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
    pha                     ; save argument low byte while preserving temp ptr
    lda STRPTR_LO
    pha
    lda STRPTR_HI
    pha
    tsx
    lda $0103,x             ; original A argument
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
    pla
    sta STRPTR_HI
    pla
    sta STRPTR_LO
    pla                     ; discard saved argument low byte
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
    stx VIC_CURSOR_X
    sty VIC_CURSOR_Y
done:
    rts
.endproc

; ------------------------------------------------------------
; SCROLL -- scroll the screen up one line, clear bottom row
; Preserves: A, X, Y (required by CHROUT compatibility)
; ------------------------------------------------------------
.proc SCROLL
    ; Save registers: SCROLL is in the public jump table ($C01B) so callers
    ; beyond CHROUT expect A/X/Y to be preserved. Without this, the clr loop
    ; exits with X=COLS=40, which CHROUT then stores into CURSOR_X, causing
    ; every subsequent character to immediately trigger another scroll.
    pha                     ; save A
    txa
    pha                     ; save X
    tya
    pha                     ; save Y

    ; Copy 24 * 40 = 960 bytes from row 1 to row 0 (character codes)
    ldx #0
copy0:
    lda VIC_BASE + COLS,x
    sta VIC_BASE,x
    inx
    bne copy0

copy1:
    lda VIC_BASE + COLS + $100,x
    sta VIC_BASE + $100,x
    inx
    bne copy1

copy2:
    lda VIC_BASE + COLS + $200,x
    sta VIC_BASE + $200,x
    inx
    bne copy2

copy3:
    lda VIC_BASE + COLS + $300,x
    sta VIC_BASE + $300,x
    inx
    cpx #192
    bne copy3

    ; clear last character row
    lda #$20
    ldx #0
clr:
    sta VIC_BASE + (ROWS-1)*COLS,x
    inx
    cpx #COLS
    bne clr

    ; Scroll color RAM ($8400-$87C0) — same pattern as character scroll
    ldx #0
ccopy0:
    lda VIC_COLOR_BASE + COLS,x
    sta VIC_COLOR_BASE,x
    inx
    bne ccopy0

ccopy1:
    lda VIC_COLOR_BASE + COLS + $100,x
    sta VIC_COLOR_BASE + $100,x
    inx
    bne ccopy1

ccopy2:
    lda VIC_COLOR_BASE + COLS + $200,x
    sta VIC_COLOR_BASE + $200,x
    inx
    bne ccopy2

ccopy3:
    lda VIC_COLOR_BASE + COLS + $300,x
    sta VIC_COLOR_BASE + $300,x
    inx
    cpx #192
    bne ccopy3

    ; clear last color row with composed color byte
    lda VIC_BG_COLOR
    asl a
    asl a
    asl a
    asl a
    ora VIC_TEXT_COLOR
    ldx #0
cclr:
    sta VIC_COLOR_BASE + (ROWS-1)*COLS,x
    inx
    cpx #COLS
    bne cclr

    ; Restore registers in reverse order
    pla
    tay                     ; restore Y
    pla
    tax                     ; restore X
    pla                     ; restore A
    rts
.endproc

; ------------------------------------------------------------
; calc_ptr_xy -- set SCRPTR = VIC_BASE + Y*COLS + X
;             (internal helper, not in jump table)
; ------------------------------------------------------------
.proc calc_ptr_xy
    lda #<VIC_BASE
    sta SCRPTR_LO
    lda #>VIC_BASE
    sta SCRPTR_HI
    cpy #0
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
    txa
    adc SCRPTR_LO
    sta SCRPTR_LO
    bcc done
    inc SCRPTR_HI
done:
    rts
.endproc

; ------------------------------------------------------------
; write_color_attr -- write CUR_COLOR to color RAM at SCRPTR+$0400
;                     Y must be 0. Clobbers A, SCRPTR_HI.
; ------------------------------------------------------------
.proc write_color_attr
    lda SCRPTR_HI
    clc
    adc #$04
    sta SCRPTR_HI
    lda VIC_BG_COLOR
    asl a
    asl a
    asl a
    asl a
    ora VIC_TEXT_COLOR
    sta (SCRPTR_LO),y
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

; ------------------------------------------------------------
; uart_put -- send char in A to hardware UART ($8810)
;             $0D -> CR + LF;  $0A -> ignored (VIC handles it)
;             Preserves: A, X, Y
; ------------------------------------------------------------
.proc uart_put
    cmp #$0A                ; ignore LF
    beq up_done
    pha
    cmp #$0D                ; CR -> send CR then LF
    bne up_char
up_cr_wait:
    lda UART_SR
    and #UART_TDRE
    beq up_cr_wait
    lda #$0D
    sta UART_DATA
up_lf_wait:
    lda UART_SR
    and #UART_TDRE
    beq up_lf_wait
    lda #$0A
    sta UART_DATA
    pla
    rts
up_char:
up_char_wait:
    lda UART_SR
    and #UART_TDRE
    beq up_char_wait
    pla
    sta UART_DATA
up_done:
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

; ============================================================
; 6502 hardware vectors at $FFFA-$FFFF.  The kernel ROM owns them and
; points reset/IRQ/NMI at EhBASIC's fixed entry table ($A000/$A003/$A006).
; ============================================================
.segment "VECTORS"
    .word $A006             ; $FFFA NMI   -> EhBASIC ENTRY_TABLE+6
    .word $A000             ; $FFFC RESET -> EhBASIC ENTRY_TABLE+0
    .word $A003             ; $FFFE IRQ   -> EhBASIC ENTRY_TABLE+3
