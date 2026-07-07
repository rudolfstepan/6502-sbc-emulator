/*
 * End-to-end test of the MultiCalc disk save/load path.  It drives the real
 * emulator disk device (src/diskdev.c) through the exact MVP register sequence
 * the 6502 program uses (SAVE/LOAD at the fpga.ini base $8824), round-tripping
 * a serialized worksheet image through a file on disk, then reloads it into the
 * engine and checks a computed value survives.
 */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "bus.h"
#include "sram.h"
#include "diskdev.h"
#include "sheet.h"

#define DISK_BASE 0x8824
#define IMG_BASE  0x1000

static void dwr(DiskDev *d, uint16_t off, uint8_t v) { diskdev_write(d, off, v); }
static uint8_t drd(DiskDev *d, uint16_t off) { return diskdev_read(d, off); }

static void set_fname(DiskDev *d, const char *n)
{
    uint8_t i;
    for (i = 0; n[i]; ++i) { dwr(d, 0x09, i); dwr(d, 0x0A, (uint8_t)n[i]); }
}

static void run_cmd(DiskDev *d, const char *name, uint16_t addr, uint16_t len, uint8_t cmd)
{
    set_fname(d, name);
    dwr(d, 0x02, (uint8_t)(addr & 0xFF));
    dwr(d, 0x03, (uint8_t)(addr >> 8));
    dwr(d, 0x04, (uint8_t)(len & 0xFF));
    dwr(d, 0x05, (uint8_t)(len >> 8));
    dwr(d, 0x00, cmd);
}

static void put(const char *ref, const char *entry)
{
    uint8_t c, r; const char *end;
    sheet_parse_ref(ref, &c, &r, &end);
    sheet_set(c, r, entry);
}

static long val(const char *ref)
{
    uint8_t c, r; const char *end;
    sheet_parse_ref(ref, &c, &r, &end);
    return sheet_value(c, r);
}

int main(void)
{
    Bus bus;
    SRAM ram;
    DiskDev disk;
    uint8_t *img;
    int sz, i;
    uint16_t actual;

    bus_init(&bus);
    assert(sram_init(&ram, 0x8000) == 0);
    bus_register(&bus, "SRAM", &ram, 0x0000, 0x8000, sram_read, sram_write, NULL);
    assert(diskdev_init(&disk, &bus, "data/disk") == 0);
    bus_register(&bus, "DISK", &disk, DISK_BASE, 12, diskdev_read, diskdev_write, NULL);
    disk.mounted_d64[0] = 0;      /* force host-file save/load, not the d64 */

    /* Build a worksheet and copy its image into simulated 6502 RAM. */
    sheet_reset();
    put("A1", "1000"); put("A2", "250"); put("A3", "=SUM(A1:A2)");
    put("B1", "PROFIT");
    sheet_set_colw(0, 15);
    sheet_set_fmt(0, 2, FMT_CURRENCY);
    sheet_recalc();
    assert(val("A3") == 125000);

    sheet_image_prepare();
    sz = sheet_image_size();
    img = sheet_image_ptr();
    for (i = 0; i < sz; ++i) bus_write(&bus, (uint16_t)(IMG_BASE + i), img[i]);

    /* SAVE to disk. */
    run_cmd(&disk, "RTTEST.MC", IMG_BASE, (uint16_t)sz, 0x01);
    assert((drd(&disk, 0x01) & 0x02) != 0);            /* DISK_ST_OK */

    /* Wipe RAM so a successful load is unambiguous. */
    for (i = 0; i < sz; ++i) bus_write(&bus, (uint16_t)(IMG_BASE + i), 0);

    /* LOAD back. */
    run_cmd(&disk, "RTTEST.MC", IMG_BASE, (uint16_t)sz, 0x02);
    assert((drd(&disk, 0x01) & 0x02) != 0);
    actual = (uint16_t)(drd(&disk, 0x06) | (drd(&disk, 0x07) << 8));
    assert(actual == (uint16_t)sz);

    /* Bytes must match the original image exactly. */
    for (i = 0; i < sz; ++i)
        assert(bus_read(&bus, (uint16_t)(IMG_BASE + i)) == img[i]);

    /* Reload into the engine from the round-tripped bytes and re-check. */
    sheet_reset();
    img = sheet_image_ptr();
    for (i = 0; i < sz; ++i) img[i] = bus_read(&bus, (uint16_t)(IMG_BASE + i));
    assert(sheet_image_reload(sz) == 0);
    assert(val("A3") == 125000);
    assert(sheet_colw(0) == 15);
    {
        char out[16];
        uint8_t c, r; const char *end;
        sheet_parse_ref("A3", &c, &r, &end);
        sheet_cell_display(c, r, out, sizeof(out));
        assert(strcmp(out, "$1250.00") == 0);
    }

    sram_free(&ram);
    puts("test_sheet_disk: ok");
    return 0;
}
