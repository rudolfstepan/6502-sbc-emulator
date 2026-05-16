.segment "CODE"

DISK_CMD      := $8020
DISK_STATUS   := $8021
DISK_ADDR_LO  := $8022
DISK_ADDR_HI  := $8023
DISK_LEN_LO   := $8024
DISK_LEN_HI   := $8025
DISK_ACT_LO   := $8026
DISK_ACT_HI   := $8027

DISK_CMD_SAVE := $01
DISK_CMD_LOAD := $02
DISK_ST_OK    := $02

SAVE:
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
        jmp     STROUT

SAVE_ERR:
        lda     #<QT_IOERR
        ldy     #>QT_IOERR
        jmp     STROUT

LOAD:
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
        jmp     FIX_LINKS

LOAD_ERR:
        lda     #<QT_IOERR
        ldy     #>QT_IOERR
        jmp     STROUT

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
