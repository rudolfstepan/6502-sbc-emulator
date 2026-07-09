#include <assert.h>
#include <stdint.h>
#include <stdio.h>

#include "bus.h"
#include "diskdev.h"
#include "cia6526.h"
#include "keyboard_regs.h"
#include "math_copro.h"
#include "sid_stub.h"
#include "soundchip.h"
#include "sram.h"
#include "via6522.h"
#include "vic.h"

static void poke(Bus *bus, uint16_t addr, uint8_t value)
{
    bus_write(bus, addr, value);
}

static uint8_t peek(Bus *bus, uint16_t addr)
{
    return bus_read(bus, addr);
}

static void assert_peek_poke(Bus *bus, uint16_t addr, uint8_t value)
{
    poke(bus, addr, value);
    uint8_t got = peek(bus, addr);
    if (got != value) {
        fprintf(stderr, "peek/poke mismatch at $%04X: wrote $%02X got $%02X\n",
                addr, value, got);
    }
    assert(got == value);
}

int main(void)
{
    Bus bus;
    SRAM ram;
    VIA6522 via;
    DiskDev disk;
    KeyboardRegs kbd;
    MathCopro math;
    CIA6526 cia;
    SIDStub sid;

    bus_init(&bus);
    vic_init();
    via_init(&via);
    keyboard_regs_init(&kbd);
    math_copro_init(&math);
    cia_init(&cia);
    sid_init(&sid);

    assert(sram_init(&ram, 0x8000) == 0);
    assert(diskdev_init(&disk, &bus, "data/disk") == 0);

    bus_register(&bus, "VIC-BITMAP", NULL, 0x6000, 0x2000,
                 vic_bitmap_read, vic_bitmap_write, NULL);
    bus_register(&bus, "VIC-VIDEO", NULL, 0x8000, 2048,
                 vic_bus_read, vic_bus_write, vic_bus_tick);
    bus_register(&bus, "KEYBOARD", &kbd, 0x8820, 4,
                 keyboard_regs_read, keyboard_regs_write, NULL);
    bus_register(&bus, "VIA-6522", &via, 0x8800, 16,
                 via_read, via_write, via_tick);
    bus_register(&bus, "DISK-MVP", &disk, 0x8824, 12,
                 diskdev_read, diskdev_write, NULL);
    bus_register(&bus, "SOUND", NULL, 0x8830, 6,
                 soundchip_voice_read, soundchip_voice_write, NULL);
    bus_register(&bus, "VIC-REGS", NULL, 0x9000, 16,
                 vic_reg_read, vic_reg_write, NULL);
    bus_register(&bus, "MATH-COPRO", &math, 0x88B0, 16,
                 math_copro_read, math_copro_write, NULL);
    bus_register(&bus, "VIC-II", NULL, 0xD000, 0x40,
                 vicii_read, vicii_write, NULL);
    bus_register(&bus, "SID-6581", &sid, 0xD400, 0x1D,
                 sid_read, sid_write, sid_tick);
    bus_register(&bus, "CIA1-6526", &cia, 0xDC00, 16,
                 cia_read, cia_write, cia_tick);
    bus_register(&bus, "SRAM", &ram, 0x0000, 0x8000,
                 sram_read, sram_write, NULL);

    /* VIC text RAM and color RAM */
    assert_peek_poke(&bus, 0x8000, 0x41);
    assert_peek_poke(&bus, 0x8400, 0x1F);

    /* VIA keyboard-related registers */
    assert_peek_poke(&bus, 0x8803, 0x00); /* DDRA */
    assert_peek_poke(&bus, 0x880E, 0x82); /* IER set CA1 */

    keyboard_regs_push_ascii(&kbd, 'A');
    assert(peek(&bus, 0x8820) == 0x81);
    assert(peek(&bus, 0x8823) == 'A');
    assert((peek(&bus, 0x8820) & 0x01) == 0);

    keyboard_regs_push_ascii(&kbd, 0x1D);
    keyboard_regs_push_ascii(&kbd, 0x1D);
    keyboard_regs_push_ascii(&kbd, 'Z');
    keyboard_regs_release_ascii(&kbd, 0x1D);
    assert(peek(&bus, 0x8820) == 0x81);
    assert(peek(&bus, 0x8823) == 'Z');
    assert((peek(&bus, 0x8820) & 0x01) == 0);

    via_keyboard_push(&via, 0x1D);
    via_keyboard_push(&via, 0x1D);
    via_keyboard_push(&via, 'Z');
    via_keyboard_release_key(&via, 0x1D);
    assert(via_keyboard_available(&via));
    assert(via_keyboard_pop(&via) == 'Z');
    assert(!via_keyboard_available(&via));

    /* FPGA GoDrive register window at $8824. */
    poke(&bus, 0x8825, 0x0A);          /* RESET command */
    assert((peek(&bus, 0x8824) & 0x02) != 0); /* DONE */
    assert(peek(&bus, 0x8828) == 0x00);       /* RESULT OK */
    assert_peek_poke(&bus, 0x8826, 0x34); /* TRACK */
    assert_peek_poke(&bus, 0x8827, 0x12); /* SECTOR */

    /* SOUND register block */
    assert_peek_poke(&bus, 0x8830, 0x70); /* FREQ_LO */
    assert_peek_poke(&bus, 0x8831, 0x03); /* FREQ_HI */
    assert_peek_poke(&bus, 0x8832, 0x5A); /* DUR_LO */
    assert_peek_poke(&bus, 0x8833, 0x00); /* DUR_HI */
    assert_peek_poke(&bus, 0x8834, 0xD0); /* VOLUME */
    assert_peek_poke(&bus, 0x8835, 0x01); /* CONTROL/trigger */

    /* VIC control registers */
    assert_peek_poke(&bus, 0x9000, 0x01); /* graphics mode */
    assert_peek_poke(&bus, 0x9001, 0x0A); /* cursor x */
    assert_peek_poke(&bus, 0x9002, 0x05); /* cursor y */
    assert_peek_poke(&bus, 0x9003, 0x0F); /* text color */
    assert_peek_poke(&bus, 0x9004, 0x06); /* legacy background color */
    assert_peek_poke(&bus, 0x9005, 0x02); /* TEXT_ATTR / 80-col bit */
    assert_peek_poke(&bus, 0x9006, 0x03); /* extended bitmap bank */

    /* Color POKEs should be immediately visible on text cells. */
    poke(&bus, 0x9003, 0x02);
    assert((peek(&bus, 0x8400) & 0x0F) == 0x02);
    assert((peek(&bus, 0x8400 + 123) & 0x0F) == 0x02);

    poke(&bus, 0x9004, 0x07);
    assert(((peek(&bus, 0x8400) >> 4) & 0x0F) == 0x07);
    assert(((peek(&bus, 0x8400 + 456) >> 4) & 0x0F) == 0x07);

    /* VIC bitmap RAM: $6000-$7FFF is a banked window and wins over SRAM. */
    poke(&bus, 0x9000, 0x10);
    poke(&bus, 0x6000, 0xAA);
    assert(peek(&bus, 0x6000) == 0xAA);
    poke(&bus, 0x9000, 0x30);
    poke(&bus, 0x6000, 0x55);
    assert(peek(&bus, 0x6000) == 0x55);
    poke(&bus, 0x9000, 0x10);
    assert(peek(&bus, 0x6000) == 0xAA);
    poke(&bus, 0x9000, 0x20);
    poke(&bus, 0x9006, 0x23);
    assert(peek(&bus, 0x9006) == 0x23);
    poke(&bus, 0x6000, 0x99);
    poke(&bus, 0x9006, 0x03);
    assert(peek(&bus, 0x6000) == 0x55);
    poke(&bus, 0x9006, 0x23);
    assert(peek(&bus, 0x6000) == 0x99);

    /* Math coprocessor: 2.0 * 3.0 in 8.24 -> 6.0 */
    poke(&bus, 0x88BC, 24);
    poke(&bus, 0x88B0, 0x00); poke(&bus, 0x88B1, 0x00);
    poke(&bus, 0x88B2, 0x00); poke(&bus, 0x88B3, 0x02);
    poke(&bus, 0x88B4, 0x00); poke(&bus, 0x88B5, 0x00);
    poke(&bus, 0x88B6, 0x00); poke(&bus, 0x88B7, 0x03);
    assert(peek(&bus, 0x88B8) == 0x00);
    assert(peek(&bus, 0x88B9) == 0x00);
    assert(peek(&bus, 0x88BA) == 0x00);
    assert(peek(&bus, 0x88BB) == 0x06);

    assert_peek_poke(&bus, 0xD020, 0x05);
    assert_peek_poke(&bus, 0xD021, 0x06);
    assert_peek_poke(&bus, 0xD400, 0x34);
    assert_peek_poke(&bus, 0xDC02, 0x12);

    bus_shutdown();
    sram_free(&ram);

    puts("test_peek_poke_addrs: ok");
    return 0;
}
