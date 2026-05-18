#define _POSIX_C_SOURCE 200809L

#include <assert.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "bus.h"
#include "diskdev.h"
#include "sram.h"

static void must_create_file(const char *dir, const char *name)
{
    char path[512];
    snprintf(path, sizeof(path), "%s/%s", dir, name);
    int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0644);
    assert(fd >= 0);
    close(fd);
}

static void remove_file(const char *dir, const char *name)
{
    char path[512];
    snprintf(path, sizeof(path), "%s/%s", dir, name);
    unlink(path);
}

static size_t build_expected(uint16_t load_addr, const char *const *names, size_t count, uint8_t *out)
{
    uint16_t offset = 0;
    uint16_t line_number = 10;

    for (size_t i = 0; i < count; i++) {
        size_t name_len = strlen(names[i]);
        uint16_t line_len = (uint16_t)(2 + 2 + 1 + 1 + name_len + 1);
        uint16_t next_addr = (uint16_t)(load_addr + offset + line_len);

        out[offset + 0] = (uint8_t)(next_addr & 0xFF);
        out[offset + 1] = (uint8_t)(next_addr >> 8);
        out[offset + 2] = (uint8_t)(line_number & 0xFF);
        out[offset + 3] = (uint8_t)(line_number >> 8);
        out[offset + 4] = 0x8E;
        out[offset + 5] = ' ';
        memcpy(out + offset + 6, names[i], name_len);
        out[offset + 6 + name_len] = 0x00;

        offset = (uint16_t)(offset + line_len);
        line_number = (uint16_t)(line_number + 10);
    }

    out[offset + 0] = 0x00;
    out[offset + 1] = 0x00;
    return (size_t)(offset + 2);
}

int main(void)
{
    char template[] = "build/sbc6502-diskdir-XXXXXX";
    char *root = mkdtemp(template);
    assert(root != NULL);

    must_create_file(root, "hello.prg");
    must_create_file(root, "basic.prg");
    must_create_file(root, "test2.prg");
    must_create_file(root, ".hidden.prg");

    Bus bus;
    SRAM ram;
    DiskDev disk;
    uint8_t expected[256] = {0};
    const char *sorted_names[] = {"basic.prg", "hello.prg", "test2.prg"};
    const uint16_t load_addr = 0x0300;
    size_t expected_len = build_expected(load_addr, sorted_names, 3, expected);

    bus_init(&bus);
    assert(sram_init(&ram, 0x10000) == 0);
    bus_register(&bus, "SRAM", &ram, 0x0000, 0x8000, sram_read, sram_write, NULL);

    assert(diskdev_init(&disk, &bus, root) == 0);
    disk.addr = load_addr;
    disk.len = 0x1000;

    diskdev_write(&disk, DISK_REG_CMD, DISK_CMD_DIR);

    assert((disk.status & DISK_ST_OK) != 0);
    assert((disk.status & DISK_ST_ERR) == 0);
    assert(disk.actual == expected_len);

    for (size_t i = 0; i < expected_len; i++) {
        uint8_t actual = bus_read(&bus, (uint16_t)(load_addr + i));
        assert(actual == expected[i]);
    }

    sram_free(&ram);
    remove_file(root, "hello.prg");
    remove_file(root, "basic.prg");
    remove_file(root, "test2.prg");
    remove_file(root, ".hidden.prg");
    rmdir(root);
    return 0;
}