#include <assert.h>
#include <stdint.h>
#include <stdio.h>

#include "bus.h"
#include "diskdev.h"

static void wr(DiskDev *disk, uint16_t offset, uint8_t value)
{
    diskdev_write(disk, offset, value);
}

static uint8_t rd(DiskDev *disk, uint16_t offset)
{
    return diskdev_read(disk, offset);
}

static void set_lba(DiskDev *disk, uint32_t lba)
{
    wr(disk, 0x08, (uint8_t)(lba & 0xFF));
    wr(disk, 0x09, (uint8_t)((lba >> 8) & 0xFF));
    wr(disk, 0x0A, (uint8_t)((lba >> 16) & 0xFF));
    wr(disk, 0x0B, (uint8_t)((lba >> 24) & 0xFF));
}

static void read_sector(DiskDev *disk, uint8_t track, uint8_t sector)
{
    wr(disk, 0x02, track);
    wr(disk, 0x03, sector);
    wr(disk, 0x01, 0x01); /* READ_SECTOR */
    assert((rd(disk, 0x00) & 0x04) == 0);
    assert(rd(disk, 0x04) == 0x00);
}

static void read_data(DiskDev *disk, uint8_t offset, uint8_t *out, size_t len)
{
    wr(disk, 0x06, offset);
    for (size_t i = 0; i < len; i++) {
        out[i] = rd(disk, 0x05);
    }
}

int main(void)
{
    Bus bus;
    DiskDev disk;

    bus_init(&bus);
    assert(diskdev_init(&disk, &bus, "data/disk") == 0);

    disk.mounted_d64[0] = 0;
    disk.fpga_status = 0;
    wr(&disk, 0x01, 0x03); /* MOUNT */
    assert((rd(&disk, 0x00) & 0x08) != 0);
    assert((rd(&disk, 0x00) & 0x04) == 0);
    assert(rd(&disk, 0x04) == 0x00);

    read_sector(&disk, 18, 1);
    wr(&disk, 0x06, 0);
    assert(rd(&disk, 0x05) == 0x00);
    assert(rd(&disk, 0x05) == 0xFF);
    wr(&disk, 0x06, 2);
    assert(rd(&disk, 0x05) == 0x82);
    (void)rd(&disk, 0x05); /* first track */
    (void)rd(&disk, 0x05); /* first sector */
    assert(rd(&disk, 0x05) == 'S');
    assert(rd(&disk, 0x05) == 'P');
    wr(&disk, 0x02, 0);
    set_lba(&disk, 0);
    wr(&disk, 0x01, 0x05); /* RAW_READ lower half of BPB */
    wr(&disk, 0x06, 0);
    assert(rd(&disk, 0x05) == 0xEB);

    set_lba(&disk, 2);
    wr(&disk, 0x01, 0x05); /* RAW_READ lower half of synthetic root dir */
    wr(&disk, 0x06, 8);
    assert(rd(&disk, 0x05) == 'D');
    assert(rd(&disk, 0x05) == '6');
    assert(rd(&disk, 0x05) == '4');

    set_lba(&disk, 3);
    wr(&disk, 0x01, 0x07); /* MOUNT_LBA first menu entry */
    assert((rd(&disk, 0x00) & 0x08) != 0);
    assert(rd(&disk, 0x04) == 0x00);

    read_sector(&disk, 18, 1);
    uint8_t entry[32];
    read_data(&disk, 2, entry, sizeof(entry));
    assert((entry[0] & 0x07) == 0x02);
    assert(entry[1] == 1);
    assert(entry[2] == 0);
    assert(entry[30] != 0);
    assert(entry[31] == 0);
    const char want[] = "SPREADSHEET";
    for (size_t i = 0; i < sizeof(want) - 1; i++) {
        assert(entry[3 + i] == (uint8_t)want[i]);
    }
    assert(entry[3 + sizeof(want) - 1] == 0xA0);

    read_sector(&disk, entry[1], entry[2]);
    uint8_t first[20];
    read_data(&disk, 0, first, sizeof(first));
    assert(first[0] != 0);          /* multi-sector PRG chain */
    assert(first[2] == 0x00);       /* PRG load address low */
    assert(first[3] == 0x10);       /* PRG load address high */
    assert(first[4] != 0x00);       /* cc65 startup code, not an empty file */

    puts("test_diskdev_fpga: ok");
    return 0;
}
