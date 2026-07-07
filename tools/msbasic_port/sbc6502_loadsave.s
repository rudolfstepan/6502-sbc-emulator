.segment "CODE"

.export LOAD, SAVE

DISK_CMD       := $8820
DISK_STATUS    := $8821
DISK_ADDR_LO   := $8822
DISK_ADDR_HI   := $8823
DISK_LEN_LO    := $8824
DISK_LEN_HI    := $8825
DISK_ACT_LO    := $8826
DISK_ACT_HI    := $8827
DISK_FNAME_IDX := $8829
DISK_FNAME_CHR := $882A

DISK_CMD_SAVE  := $01
DISK_CMD_LOAD  := $02
DISK_CMD_DIR   := $03
DISK_ST_OK     := $02

; Temporary buffer for filename
FNAME_BUF      := $0280
FNAME_MAX      := 31
; Reuse disk length registers as temporary line number storage while
; building a directory listing after DISK_CMD_DIR has already completed.
LINNUM_LO      := DISK_LEN_LO
LINNUM_HI      := DISK_LEN_HI

SAVE:
        ; Check for string parameter (SAVE "filename",8)
        jsr     CHRGOT
        bne     :+
        jmp     save_noname     ; end of line - use default
:
        ; Evaluate string expression
        jsr     FRMEVL
        jsr     CHKSTR
        jsr     FREFAC          ; A=length, INDEX=pointer
        
        ; Copy filename and add .prg if needed (same as LOAD)
        tax                     ; X = length
        bne     :+
        jmp     save_noname     ; empty string
:
        cpx     #FNAME_MAX
        bcc     :+
        ldx     #FNAME_MAX-1
:
        ldy     #0
save_copy_loop:
        lda     (INDEX),y
        sta     FNAME_BUF,y
        iny
        dex
        bne     save_copy_loop
        
        ; Y = length, save in X
        tya
        tax
        
        ; Check for .prg extension (same logic as LOAD)
        cpy     #4
        bcs     :+
        jmp     save_add_prg
        
        ; Save original length
        sty     FNAME_BUF+FNAME_MAX-1
        
        dey
        lda     FNAME_BUF,y
        cmp     #'G'
        beq     :+
        cmp     #'g'
        beq     :+
        jmp     save_add_prg
:       dey
        lda     FNAME_BUF,y
        cmp     #'R'
        beq     :+
        cmp     #'r'
        beq     :+
        jmp     save_add_prg
:       dey
        lda     FNAME_BUF,y
        cmp     #'P'
        beq     :+
        cmp     #'p'
        beq     :+
        jmp     save_add_prg
:       dey
        lda     FNAME_BUF,y
        cmp     #'.'
        beq     :+
        jmp     save_add_prg
:
        
        ; Found .prg! Restore Y to original length
        ldy     FNAME_BUF+FNAME_MAX-1
        jmp     save_has_prg
        
save_add_prg:
        txa
        tay
        lda     #'.'
        sta     FNAME_BUF,y
        iny
        lda     #'p'
        sta     FNAME_BUF,y
        iny
        lda     #'r'
        sta     FNAME_BUF,y
        iny
        lda     #'g'
        sta     FNAME_BUF,y
        iny
        
save_has_prg:
        lda     #0
        sta     FNAME_BUF,y
        
        ; Convert filename to lowercase (Linux filesystems are case-sensitive)
        ldy     #0
save_lowercase_loop:
        lda     FNAME_BUF,y
        beq     save_lowercase_done
        cmp     #'A'
        bcc     :+
        cmp     #'Z'+1
        bcs     :+
        ora     #$20            ; set bit 5 -> lowercase
        sta     FNAME_BUF,y
:       iny
        bne     save_lowercase_loop
save_lowercase_done:
        jsr     consume_trailing_args
        
        ; Write to disk device
        jsr     write_filename_to_disk
        jmp     do_save

save_noname:
        ; No filename, use default
        jsr     set_default_filename
        jmp     do_save

do_save:
        lda     TXTTAB
        sta     DISK_ADDR_LO
        lda     TXTTAB+1
        sta     DISK_ADDR_HI

        sec
        lda     VARTAB
        sbc     TXTTAB
        sta     DISK_LEN_LO
        lda     VARTAB+1
        sbc     TXTTAB+1
        sta     DISK_LEN_HI

        lda     #DISK_CMD_SAVE
        sta     DISK_CMD

        lda     DISK_STATUS
        and     #DISK_ST_OK
        beq     SAVE_ERR

        lda     #<QT_SAVED
        ldy     #>QT_SAVED
        jsr     STROUT
        rts

SAVE_ERR:
        lda     #<QT_IOERR
        ldy     #>QT_IOERR
        jsr     STROUT
        rts

LOAD:
        ; Check if there's a parameter
        jsr     CHRGOT
        bne     :+
        jmp     load_default    ; no parameter - use default file
:
        ; Evaluate string expression
        jsr     FRMEVL          ; evaluate expression
        jsr     CHKSTR          ; ensure it's a string
        jsr     FREFAC          ; unpack: A=length, INDEX=pointer to string data
        
        ; Save length
        pha                     ; save length on stack
        tax                     ; X = length
        bne     :+
        jmp     load_default_pop ; empty string
:
        
        ; For directory: accept length=1 with non-alphanumeric character
        ; This handles "$", "*", or even if BASIC transforms it to CR
        cmp     #1
        beq     check_special   ; length = 1, check character
        jmp     copy_filename_pop ; length > 1, use as filename
        
check_special:
        ; Length is 1, check if it's a special character (not A-Z, 0-9)
        ldy     #0
        lda     (INDEX),y       ; get the character
        
        ; Check if it's alphanumeric
        cmp     #'0'
        bcc     is_special      ; < '0' → special
        cmp     #'9'+1
        bcc     :+              ; '0'-'9' → filename
        cmp     #'A'
        bcc     is_special      ; between '9' and 'A' → special  
        cmp     #'Z'+1
        bcc     :+              ; 'A'-'Z' → filename
        ; Above 'Z' → special
        jmp     is_special
:
        jmp     copy_filename_pop
        
is_special:
        ; Single non-alphanumeric character → directory
        pla                     ; clean up stack
        jsr     consume_trailing_args
        jmp     load_is_dir

load_default_pop:
        pla                     ; clean up stack
        jmp     load_default

copy_filename_pop:
        pla                     ; restore length into A
        ; Copy string from INDEX to FNAME_BUF
        ; A = length, INDEX = pointer to string
        tax                     ; X = length
        bne     :+
        jmp     load_default    ; empty string - use default
:
        cpx     #FNAME_MAX
        bcc     :+
        ldx     #FNAME_MAX-1    ; truncate if too long
:
        ldy     #0
copy_loop:
        lda     (INDEX),y
        sta     FNAME_BUF,y
        iny
        dex
        bne     copy_loop
        
        ; Y now = string length
        ; Save length in X
        tya
        tax
        
        ; Check if filename ends with ".prg" or ".d64" (case insensitive)
        ; Need at least 4 characters
        cpy     #4
        bcs     :+
        jmp     add_prg         ; < 4 chars, add .prg
:
        
        ; Save original length in X for later
        sty     FNAME_BUF+FNAME_MAX-1  ; temp storage

        ; Check last 4 characters for ".d64"
        dey
        lda     FNAME_BUF,y
        cmp     #'4'
        bne     check_prg_ext
        dey
        lda     FNAME_BUF,y
        cmp     #'6'
        bne     check_prg_ext
        dey
        lda     FNAME_BUF,y
        cmp     #'D'
        beq     :+
        cmp     #'d'
        bne     check_prg_ext
:       dey
        lda     FNAME_BUF,y
        cmp     #'.'
        bne     check_prg_ext
        ldy     FNAME_BUF+FNAME_MAX-1
        jmp     has_prg         ; .d64 is a disk image name, do not append .prg

check_prg_ext:
        ldy     FNAME_BUF+FNAME_MAX-1
        ; Check last 4 characters: [Y-4] through [Y-1]
        dey
        lda     FNAME_BUF,y     ; should be 'g' or 'G'
        cmp     #'G'
        beq     :+
        cmp     #'g'
        beq     :+
        jmp     add_prg
:       dey
        lda     FNAME_BUF,y     ; should be 'r' or 'R'
        cmp     #'R'
        beq     :+
        cmp     #'r'
        beq     :+
        jmp     add_prg
:       dey
        lda     FNAME_BUF,y     ; should be 'p' or 'P'
        cmp     #'P'
        beq     :+
        cmp     #'p'
        beq     :+
        jmp     add_prg
:       dey
        lda     FNAME_BUF,y     ; should be '.'
        cmp     #'.'
        beq     :+
        jmp     add_prg
:
        
        ; Found .prg! Restore Y to original length
        ldy     FNAME_BUF+FNAME_MAX-1
        jmp     has_prg         ; already has .prg
        
add_prg:
        ; Restore Y to original length from X
        txa
        tay
        
        ; Append ".prg" at position Y
        lda     #'.'
        sta     FNAME_BUF,y
        iny
        lda     #'p'
        sta     FNAME_BUF,y
        iny
        lda     #'r'
        sta     FNAME_BUF,y
        iny
        lda     #'g'
        sta     FNAME_BUF,y
        iny
        
has_prg:
        ; Null-terminate at position Y
        lda     #0
        sta     FNAME_BUF,y
        
        ; Convert filename to lowercase (Linux filesystems are case-sensitive)
        ldy     #0
lowercase_loop:
        lda     FNAME_BUF,y
        beq     lowercase_done
        cmp     #'A'
        bcc     :+              ; < 'A', skip
        cmp     #'Z'+1
        bcs     :+              ; > 'Z', skip
        ora     #$20            ; set bit 5 -> lowercase
        sta     FNAME_BUF,y
:       iny
        bne     lowercase_loop
lowercase_done:
        jsr     consume_trailing_args
        
        ; Write filename to disk device
        jsr     write_filename_to_disk
        jmp     do_load
        
load_is_dir:
        ; Execute directory as BASIC program
        jmp     do_dir

load_default:
        jsr     set_default_filename
        ; Fall through to do_load

do_load:
        lda     TXTTAB
        sta     DISK_ADDR_LO
        lda     TXTTAB+1
        sta     DISK_ADDR_HI

        sec
        lda     MEMSIZ
        sbc     TXTTAB
        sta     DISK_LEN_LO
        lda     MEMSIZ+1
        sbc     TXTTAB+1
        sta     DISK_LEN_HI

        lda     #DISK_CMD_LOAD
        sta     DISK_CMD

        lda     DISK_STATUS
        and     #DISK_ST_OK
        beq     LOAD_ERR

        clc
        lda     TXTTAB
        adc     DISK_ACT_LO
        sta     VARTAB
        sta     ARYTAB
        sta     STREND
        lda     TXTTAB+1
        adc     DISK_ACT_HI
        sta     VARTAB+1
        sta     ARYTAB+1
        sta     STREND+1

        lda     MEMSIZ
        sta     FRETOP
        lda     MEMSIZ+1
        sta     FRETOP+1

        lda     #<QT_LOADED
        ldy     #>QT_LOADED
        jsr     STROUT
        jsr     FIX_LINKS
        rts

LOAD_ERR:
        lda     #<QT_IOERR
        ldy     #>QT_IOERR
        jsr     STROUT
        rts

; Directory listing (LOAD "$",8)
; Disk device returns a ready-to-list BASIC program at TXTTAB.
do_dir:
        ; Request BASIC directory listing directly at TXTTAB
        lda     TXTTAB
        sta     DISK_ADDR_LO
        lda     TXTTAB+1
        sta     DISK_ADDR_HI
        
        sec
        lda     MEMSIZ
        sbc     TXTTAB
        sta     DISK_LEN_LO
        lda     MEMSIZ+1
        sbc     TXTTAB+1
        sta     DISK_LEN_HI
        
        lda     #DISK_CMD_DIR
        sta     DISK_CMD
        
        lda     DISK_STATUS
        and     #DISK_ST_OK
        bne     dir_ok
        jmp     dir_err
dir_ok:
        clc
        lda     TXTTAB
        adc     DISK_ACT_LO
        sta     VARTAB
        sta     ARYTAB
        sta     STREND
        lda     TXTTAB+1
        adc     DISK_ACT_HI
        sta     VARTAB+1
        sta     ARYTAB+1
        sta     STREND+1
        
        lda     MEMSIZ
        sta     FRETOP
        lda     MEMSIZ+1
        sta     FRETOP+1
        
        lda     #<QT_LOADED
        ldy     #>QT_LOADED
        jsr     STROUT
        rts

; Create one BASIC line for directory
; Format: LINK(2) LINENUM(2) REM(1) "filename" 00
dir_create_line:
        ; Calculate line length first
        ldy     #0
dir_calc_len:
        lda     (INDEX),y
        beq     dir_len_done
        cmp     #CR
        beq     dir_len_done
        iny
        jmp     dir_calc_len
dir_len_done:
        ; Y = filename length
        ; Line length = 2(link) + 2(line#) + 1(REM) + 1(space) + Y(filename) + 1(null) = Y+7
        tya
        clc
        adc     #7
        pha                     ; Save line length on stack (will be used at end)
        
        ; Calculate LINK = TEMPPT + line_length
        clc
        adc     TEMPPT
        tax                     ; X = link low
        lda     TEMPPT+1
        adc     #0
        pha                     ; save link high on stack
        
        ; Write LINK
        ldy     #0
        txa                     ; link low
        sta     (TEMPPT),y
        iny
        pla                     ; link high
        sta     (TEMPPT),y
        
        ; Write line number
        iny
        lda     LINNUM_LO
        sta     (TEMPPT),y
        iny
        lda     LINNUM_HI
        sta     (TEMPPT),y
        
        ; Write REM token (0x8E)
        iny
        lda     #$8E
        sta     (TEMPPT),y
        
        ; Write space after REM
        iny
        lda     #$20
        sta     (TEMPPT),y
        
        ; Copy filename - use DEST as temp pointer to source
        lda     INDEX
        sta     DEST
        lda     INDEX+1
        sta     DEST+1
        
dir_copy_fname:
        ldx     #0
        lda     (DEST,x)
        beq     dir_fname_done
        cmp     #CR
        beq     dir_fname_done
        iny
        sta     (TEMPPT),y
        inc     DEST
        bne     dir_copy_fname
        inc     DEST+1
        jmp     dir_copy_fname
        
dir_fname_done:
        ; Write null terminator
        iny
        lda     #0
        sta     (TEMPPT),y
        
        ; Advance output pointer by the calculated line length (saved on stack)
        pla                     ; get line length back from stack
        clc
        adc     TEMPPT
        sta     TEMPPT
        lda     TEMPPT+1
        adc     #0
        sta     TEMPPT+1
        rts

dir_err:
        lda     #<QT_IOERR
        ldy     #>QT_IOERR
        jsr     STROUT
        rts

consume_trailing_args:
        jsr     CHRGOT
consume_trailing_args_loop:
        beq     consume_trailing_args_done
        cmp     #':'
        beq     consume_trailing_args_done
        jsr     CHRGET
        jsr     CHRGOT
        jmp     consume_trailing_args_loop

consume_trailing_args_done:
        rts

; Write filename from FNAME_BUF to disk device
write_filename_to_disk:
        ldx     #0
wf_loop:
        lda     FNAME_BUF,x
        beq     wf_done
        
        ; Set index
        stx     DISK_FNAME_IDX
        ; Write character
        sta     DISK_FNAME_CHR
        
        inx
        cpx     #FNAME_MAX
        bcc     wf_loop
        
wf_done:
        ; Write null terminator
        stx     DISK_FNAME_IDX
        lda     #0
        sta     DISK_FNAME_CHR
        rts

; Set default filename "basic.prg"
set_default_filename:
        ldx     #0
sdf_loop:
        lda     default_fname,x
        sta     FNAME_BUF,x
        beq     sdf_done
        inx
        jmp     sdf_loop
sdf_done:
        jsr     write_filename_to_disk
        rts

default_fname:
        .byte   "basic.prg", 0

QT_SAVED:
        .byte   CR,LF
        .byte   "SAVED"
        .byte   CR,LF,0

QT_LOADED:
        .byte   CR,LF
        .byte   "LOADED"
        .byte   CR,LF,0

QT_IOERR:
        .byte   CR,LF
        .byte   "I/O ERROR"
        .byte   CR,LF,0
