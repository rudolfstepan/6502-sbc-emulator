#include "diskdev.h"
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <errno.h>

static void set_status(DiskDev *d, uint8_t st, uint8_t err)
{
    d->status = st;
    d->err = err;
}

static int mkdir_p(const char *path)
{
    char tmp[256];
    size_t n = strlen(path);
    if (n == 0 || n >= sizeof(tmp)) return -1;

    memcpy(tmp, path, n + 1);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
            *p = '/';
        }
    }
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
    return 0;
}

static int build_target_path(const DiskDev *d, char *out, size_t out_sz)
{
    int n = snprintf(out, out_sz, "%s/basic.prg", d->root_path);
    return (n > 0 && (size_t)n < out_sz) ? 0 : -1;
}

static void execute_save(DiskDev *d)
{
    char path[320];
    if (build_target_path(d, path, sizeof(path)) != 0) {
        set_status(d, DISK_ST_ERR, 1);
        return;
    }

    if (mkdir_p(d->root_path) != 0) {
        set_status(d, DISK_ST_ERR, 2);
        return;
    }

    FILE *f = fopen(path, "wb");
    if (!f) {
        set_status(d, DISK_ST_ERR, 3);
        return;
    }

    d->actual = 0;
    for (uint16_t i = 0; i < d->len; i++) {
        uint8_t b = bus_read(d->bus, (uint16_t)(d->addr + i));
        if (fwrite(&b, 1, 1, f) != 1) {
            fclose(f);
            set_status(d, DISK_ST_ERR, 4);
            return;
        }
        d->actual++;
    }

    fclose(f);
    set_status(d, DISK_ST_OK, 0);
}

static void execute_load(DiskDev *d)
{
    char path[320];
    if (build_target_path(d, path, sizeof(path)) != 0) {
        set_status(d, DISK_ST_ERR, 1);
        return;
    }

    FILE *f = fopen(path, "rb");
    if (!f) {
        set_status(d, DISK_ST_ERR, 5);
        return;
    }

    d->actual = 0;
    set_status(d, DISK_ST_OK, 0);

    for (uint16_t i = 0; i < d->len; i++) {
        int c = fgetc(f);
        if (c == EOF) {
            d->status |= DISK_ST_EOF;
            break;
        }
        bus_write(d->bus, (uint16_t)(d->addr + i), (uint8_t)c);
        d->actual++;
    }

    fclose(f);
}

int diskdev_init(DiskDev *d, Bus *bus, const char *root_path)
{
    memset(d, 0, sizeof(*d));
    d->bus = bus;
    if (root_path && root_path[0])
        snprintf(d->root_path, sizeof(d->root_path), "%s", root_path);
    else
        snprintf(d->root_path, sizeof(d->root_path), "%s", "data/disk");
    return 0;
}

uint8_t diskdev_read(void *dev, uint16_t offset)
{
    DiskDev *d = (DiskDev *)dev;
    switch (offset & 0x0F) {
    case DISK_REG_STATUS:  return d->status;
    case DISK_REG_ADDR_LO: return (uint8_t)(d->addr & 0xFF);
    case DISK_REG_ADDR_HI: return (uint8_t)(d->addr >> 8);
    case DISK_REG_LEN_LO:  return (uint8_t)(d->len & 0xFF);
    case DISK_REG_LEN_HI:  return (uint8_t)(d->len >> 8);
    case DISK_REG_ACT_LO:  return (uint8_t)(d->actual & 0xFF);
    case DISK_REG_ACT_HI:  return (uint8_t)(d->actual >> 8);
    case DISK_REG_ERR:     return d->err;
    default:               return 0;
    }
}

void diskdev_write(void *dev, uint16_t offset, uint8_t val)
{
    DiskDev *d = (DiskDev *)dev;
    switch (offset & 0x0F) {
    case DISK_REG_CMD:
        d->status = 0;
        d->err = 0;
        if (val == DISK_CMD_SAVE) execute_save(d);
        else if (val == DISK_CMD_LOAD) execute_load(d);
        break;
    case DISK_REG_ADDR_LO:
        d->addr = (uint16_t)((d->addr & 0xFF00) | val);
        break;
    case DISK_REG_ADDR_HI:
        d->addr = (uint16_t)((d->addr & 0x00FF) | ((uint16_t)val << 8));
        break;
    case DISK_REG_LEN_LO:
        d->len = (uint16_t)((d->len & 0xFF00) | val);
        break;
    case DISK_REG_LEN_HI:
        d->len = (uint16_t)((d->len & 0x00FF) | ((uint16_t)val << 8));
        break;
    default:
        break;
    }
}
