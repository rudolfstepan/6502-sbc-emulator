.segment "EXTRA"
.export MONRDKEY_NB, MONRDKEY, MONCOUT

UART_DATA   := $8010
UART_STATUS := $8011
UART_RDRF   := $08

MONRDKEY_NB:
        lda UART_STATUS
        and #UART_RDRF
        beq @nothing
        lda UART_DATA
        sec
        rts
@nothing:
        clc
        rts

MONRDKEY:
@retry:
        jsr MONRDKEY_NB
        bcc @retry
        jsr MONCOUT
        rts

MONCOUT:
        sta UART_DATA
        rts
