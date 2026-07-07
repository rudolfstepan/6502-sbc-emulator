#pragma once
#include "via6522.h"
#include "keyboard_regs.h"

/*
 * Keyboard interface via VIA6522 Port A
 * 
 * The keyboard uses VIA Port A as input (DDRA=0x00)
 * Keys are buffered in a FIFO queue and trigger CA1 interrupts
 */

/* Get the VIA configured for keyboard input */
VIA6522* get_keyboard_via(void);
KeyboardRegs* get_keyboard_regs(void);
