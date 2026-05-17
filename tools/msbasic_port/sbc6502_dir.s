; ============================================================
; DIR command for MS BASIC
; Adds DIR as a standalone keyword
; ============================================================
.segment "CODE"

.export DIR

DISK_CMD       := $8820
DISK_STATUS    := $8821
DISK_ADDR_LO   := $8822
DISK_ADDR_HI   := $8823
DISK_LEN_LO    := $8824
DISK_LEN_HI    := $8825

DISK_CMD_DIR   := $03
DISK_ST_OK     := $02

DIR:
        ; Use buffer at $0400 for directory listing
        lda     #$00
        sta     DISK_ADDR_LO
        lda     #$04
        sta     DISK_ADDR_HI
        
        lda     #$00
        sta     DISK_LEN_LO
        lda     #$10            ; 4KB max
        sta     DISK_LEN_HI
        
        lda     #DISK_CMD_DIR
        sta     DISK_CMD
        
        lda     DISK_STATUS
        and     #DISK_ST_OK
        beq     dir_err
        
        ; Print directory header
        lda     #<dir_header
        ldy     #>dir_header
        jsr     STROUT
        
        ; Print directory content from $0400
        lda     #$00
        ldy     #$04
        jsr     STROUT
        
        ; Print footer
        lda     #<dir_footer
        ldy     #>dir_footer
        jsr     STROUT
        rts

dir_err:
        lda     #<dir_error
        ldy     #>dir_error
        jsr     STROUT
        rts

.segment "RODATA"
dir_header:
        .byte   CR,LF
        .byte   "DIRECTORY:", CR,LF, 0

dir_footer:
        .byte   CR,LF, "OK", CR,LF, 0

dir_error:
        .byte   CR,LF
        .byte   "DIR ERROR", CR,LF, 0
