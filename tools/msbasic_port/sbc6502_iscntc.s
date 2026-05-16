.segment "CODE"
ISCNTC:
        jsr MONRDKEY_NB
        bcc @nothing
        cmp #$03
        beq @stopit
@nothing:
        rts
@stopit:
; runs into STOP
