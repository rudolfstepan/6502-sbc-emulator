; configuration
CONFIG_2C := 1

CONFIG_NO_CR        := 1
CONFIG_SCRTCH_ORDER := 2

; zero page
ZP_START1 := $00
ZP_START2 := $0D
ZP_START3 := $5B
ZP_START4 := $65

; extra ZP variables
USR := $000A

; constants
STACK_TOP       := $FC
SPACE_FOR_GOSUB := $33
WIDTH           := 72
WIDTH2          := 56

; memory layout
RAMSTART2 := $0300

; load/save stubs
SAVE:
LOAD:
        rts
