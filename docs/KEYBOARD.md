# Keyboard Integration

## Overview

Keyboard input is routed through VIA6522 Port A and exposed to 6502 software via memory-mapped reads.
SDL keyboard events feed an internal FIFO queue in the VIA implementation.

## Hardware View

- VIA base: typically `$8800`
- ORA (`$8801`): read next key byte
- DDRA (`$8803`): set to input mode (`$00`)
- IFR (`$880D`): CA1 bit indicates key available
- IER (`$880E`): enable CA1 interrupt if desired

## Read Loop (Assembly)

```asm
VIA_ORA  = $8801
VIA_DDRA = $8803
VIA_IFR  = $880D

LDA #$00
STA VIA_DDRA

.wait:
  LDA VIA_IFR
  AND #$02
  BEQ .wait
  LDA VIA_ORA
```

## Read Loop (C)

```c
#include <stdint.h>

#define VIA_ORA  (*(volatile uint8_t *)0x8801)
#define VIA_DDRA (*(volatile uint8_t *)0x8803)
#define VIA_IFR  (*(volatile uint8_t *)0x880D)

static inline void kb_init(void) {
    VIA_DDRA = 0x00;
}

static inline uint8_t kb_getc_blocking(void) {
    while ((VIA_IFR & 0x02u) == 0) {
    }
    return VIA_ORA;
}
```

## Supported Input

- ASCII letters and numbers
- common punctuation
- Enter (`0x0D`)
- Backspace (`0x08`)
- ESC closes emulator window

## Related Files

- [src/via6522.c](../src/via6522.c)
- [src/vic_sdl.c](../src/vic_sdl.c)
- [examples/keyboard_io.s](../examples/keyboard_io.s)
- [examples/keyboard_io.c](../examples/keyboard_io.c)
