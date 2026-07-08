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

void keyboard_regs_release_ascii(KeyboardRegs *kbd, uint8_t ascii)
{
    uint8_t kept[sizeof(kbd->fifo)];
    uint8_t kept_count = 0;
    uint8_t pos = kbd->read_pos;

    for (unsigned int i = 0; i < kbd->count; i++) {
        uint8_t v = kbd->fifo[pos];
        if (v != ascii) {
            kept[kept_count++] = v;
        }
        pos = (uint8_t)((pos + 1) % sizeof(kbd->fifo));
    }

    for (unsigned int i = 0; i < kept_count; i++) {
        kbd->fifo[i] = kept[i];
    }
    kbd->read_pos = 0;
    kbd->write_pos = (uint8_t)(kept_count % sizeof(kbd->fifo));
    kbd->count = kept_count;

    if (kbd->count > 0) {
        kbd->keycode = kbd->fifo[kbd->read_pos];
        kbd->modifier = 0;
        kbd->ascii = kbd->keycode;
        kbd->key_ready = 1;
    } else if (kbd->ascii == ascii || kbd->keycode == ascii) {
        kbd->keycode = 0;
        kbd->modifier = 0;
        kbd->ascii = 0;
        kbd->key_ready = 0;
    }
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
