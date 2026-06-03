#include <assert.h>
#include <stdint.h>
#include <stdio.h>

#include "bus.h"
#include "diskdev.h"
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
    assert(peek(bus, addr) == value);
}

int main(void)
{
    Bus bus;
    SRAM ram;
    VIA6522 via;
    DiskDev disk;

    bus_init(&bus);
    vic_init();
    via_init(&via);

    assert(sram_init(&ram, 0x8000) == 0);
    assert(diskdev_init(&disk, &bus, "data/disk") == 0);

    bus_register(&bus, "VIC-VIDEO", NULL, 0x8000, 2048,
                 vic_bus_read, vic_bus_write, vic_bus_tick);
    bus_register(&bus, "VIA-6522", &via, 0x8800, 16,
                 via_read, via_write, via_tick);
    bus_register(&bus, "DISK-MVP", &disk, 0x8820, 16,
                 diskdev_read, diskdev_write, NULL);
    bus_register(&bus, "SOUND", NULL, 0x8830, 6,
                 soundchip_voice_read, soundchip_voice_write, NULL);
    bus_register(&bus, "VIC-REGS", NULL, 0x9000, 16,
                 vic_reg_read, vic_reg_write, NULL);
    bus_register(&bus, "VIC-BITMAP", NULL, 0x9010, 8000,
                 vic_bitmap_read, vic_bitmap_write, NULL);
    bus_register(&bus, "SRAM", &ram, 0x0000, 0x8000,
                 sram_read, sram_write, NULL);

    /* VIC text RAM and color RAM */
    assert_peek_poke(&bus, 0x8000, 0x41);
    assert_peek_poke(&bus, 0x8400, 0x1F);

    /* VIA keyboard-related registers */
    assert_peek_poke(&bus, 0x8803, 0x00); /* DDRA */
    assert_peek_poke(&bus, 0x880E, 0x82); /* IER set CA1 */

    /* DISK register window (address/length registers are read-back capable) */
    assert_peek_poke(&bus, 0x8822, 0x34); /* ADDR_LO */
    assert_peek_poke(&bus, 0x8823, 0x12); /* ADDR_HI */
    assert_peek_poke(&bus, 0x8824, 0x78); /* LEN_LO */
    assert_peek_poke(&bus, 0x8825, 0x56); /* LEN_HI */

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
    assert_peek_poke(&bus, 0x9004, 0x06); /* background color */

    /* Color POKEs should be immediately visible on text cells. */
    poke(&bus, 0x9003, 0x02);
    assert((peek(&bus, 0x8400) & 0x0F) == 0x02);
    assert((peek(&bus, 0x8400 + 123) & 0x0F) == 0x02);

    poke(&bus, 0x9004, 0x07);
    assert(((peek(&bus, 0x8400) >> 4) & 0x0F) == 0x07);
    assert(((peek(&bus, 0x8400 + 456) >> 4) & 0x0F) == 0x07);

    /* VIC bitmap RAM */
    assert_peek_poke(&bus, 0x9010, 0xAA);
    assert_peek_poke(&bus, 0xA000, 0x55);

    bus_shutdown();
    sram_free(&ram);

    puts("test_peek_poke_addrs: ok");
    return 0;
}
