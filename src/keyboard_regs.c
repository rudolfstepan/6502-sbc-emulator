#include "keyboard_regs.h"
#include <string.h>

void keyboard_regs_init(KeyboardRegs *kbd)
{
    memset(kbd, 0, sizeof(*kbd));
    kbd->connected = 1;
}

bool keyboard_regs_push_ascii(KeyboardRegs *kbd, uint8_t ascii)
{
    if (ascii == 0 || kbd->count >= sizeof(kbd->fifo)) {
        return false;
    }
    kbd->fifo[kbd->write_pos] = ascii;
    kbd->write_pos = (uint8_t)((kbd->write_pos + 1) % sizeof(kbd->fifo));
    kbd->count++;
    if (!kbd->key_ready) {
        kbd->keycode = ascii;
        kbd->modifier = 0;
        kbd->ascii = ascii;
        kbd->key_ready = 1;
    }
    return true;
}

bool keyboard_regs_irq(const KeyboardRegs *kbd)
{
    return kbd->key_ready != 0;
}

static uint8_t keyboard_regs_pop(KeyboardRegs *kbd)
{
    uint8_t v = kbd->ascii;
    if (kbd->count > 0) {
        v = kbd->fifo[kbd->read_pos];
        kbd->read_pos = (uint8_t)((kbd->read_pos + 1) % sizeof(kbd->fifo));
        kbd->count--;
    }

    if (kbd->count > 0) {
        kbd->keycode = kbd->fifo[kbd->read_pos];
        kbd->ascii = kbd->keycode;
        kbd->modifier = 0;
        kbd->key_ready = 1;
    } else {
        kbd->key_ready = 0;
    }
    return v;
}

uint8_t keyboard_regs_read(void *dev, uint16_t offset)
{
    KeyboardRegs *kbd = (KeyboardRegs *)dev;
    switch (offset & 0x03) {
    case 0:
        return (uint8_t)((kbd->connected ? 0x80 : 0x00) |
                         (kbd->key_ready ? 0x01 : 0x00));
    case 1: {
        uint8_t v = kbd->keycode;
        keyboard_regs_pop(kbd);
        return v;
    }
    case 2:
        return kbd->modifier;
    case 3: {
        return keyboard_regs_pop(kbd);
    }
    }
    return 0x00;
}

void keyboard_regs_write(void *dev, uint16_t offset, uint8_t val)
{
    (void)dev;
    (void)offset;
    (void)val;
}
