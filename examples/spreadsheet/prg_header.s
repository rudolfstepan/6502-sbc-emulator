BASIC_LOAD = $0301
ENTRY_ADDR = $1000
TK_CALL    = $9C
BASIC_PAD  = $0CF3

.segment "EXEHDR"
    .word BASIC_LOAD

.segment "BASIC"
basic:
    .word basic_end
    .word 10
    .byte TK_CALL, "4096", 0
basic_end:
    .word 0
    .res BASIC_PAD
