#ifndef KEYBOARD_REGS_H
#define KEYBOARD_REGS_H

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    uint8_t connected;
    uint8_t key_ready;
    uint8_t keycode;
    uint8_t modifier;
    uint8_t ascii;
    uint8_t fifo[32];
    uint8_t read_pos;
    uint8_t write_pos;
    uint8_t count;
} KeyboardRegs;

void keyboard_regs_init(KeyboardRegs *kbd);
bool keyboard_regs_push_ascii(KeyboardRegs *kbd, uint8_t ascii);
bool keyboard_regs_irq(const KeyboardRegs *kbd);
uint8_t keyboard_regs_read(void *dev, uint16_t offset);
void keyboard_regs_write(void *dev, uint16_t offset, uint8_t val);

#endif
