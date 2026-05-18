#define _POSIX_C_SOURCE 200809L

#include "diskdev.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <errno.h>

#ifdef _WIN32
#include <direct.h>
#define MKDIR_PCOMPAT(path) _mkdir(path)
#else
#define MKDIR_PCOMPAT(path) mkdir((path), 0755)
#endif

#define BASIC_REM_TOKEN 0x8E

static int cmp_dir_names(const void *lhs, const void *rhs)
{
    const char *const *left = lhs;
    const char *const *right = rhs;
    return strcmp(*left, *right);
}

static int write_basic_dir_listing(DiskDev *d)
{
    DIR *dir = opendir(d->root_path);
    if (!dir) {
        return -1;
    }

    char *names[256];
    size_t name_count = 0;
    struct dirent *entry;

    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        if (entry->d_name[0] == '.') {
            continue;
        }
        if (name_count >= (sizeof(names) / sizeof(names[0]))) {
            closedir(dir);
            return -1;
        }

        names[name_count] = strdup(entry->d_name);
        if (!names[name_count]) {
            closedir(dir);
            for (size_t i = 0; i < name_count; i++) {
                free(names[i]);
            }
            return -1;
        }
        name_count++;
    }

    closedir(dir);
    qsort(names, name_count, sizeof(names[0]), cmp_dir_names);

    uint16_t offset = 0;
    uint16_t line_number = 10;

    for (size_t i = 0; i < name_count; i++) {
        size_t name_len = strlen(names[i]);
        uint16_t line_len = (uint16_t)(2 + 2 + 1 + 1 + name_len + 1);

        if ((uint32_t)offset + line_len + 2 > d->len) {
            break;
        }

        uint16_t line_addr = (uint16_t)(d->addr + offset);
        uint16_t next_addr = (uint16_t)(line_addr + line_len);

        bus_write(d->bus, line_addr + 0, (uint8_t)(next_addr & 0xFF));
        bus_write(d->bus, line_addr + 1, (uint8_t)(next_addr >> 8));
        bus_write(d->bus, line_addr + 2, (uint8_t)(line_number & 0xFF));
        bus_write(d->bus, line_addr + 3, (uint8_t)(line_number >> 8));
        bus_write(d->bus, line_addr + 4, BASIC_REM_TOKEN);
        bus_write(d->bus, line_addr + 5, (uint8_t)' ');

        for (size_t j = 0; j < name_len; j++) {
            bus_write(d->bus, (uint16_t)(line_addr + 6 + j), (uint8_t)names[i][j]);
        }
        bus_write(d->bus, (uint16_t)(line_addr + 6 + name_len), 0x00);

        offset = (uint16_t)(offset + line_len);
        line_number = (uint16_t)(line_number + 10);
    }

    for (size_t i = 0; i < name_count; i++) {
        free(names[i]);
    }

    if ((uint32_t)offset + 2 > d->len) {
        return -1;
    }

    bus_write(d->bus, (uint16_t)(d->addr + offset), 0x00);
    bus_write(d->bus, (uint16_t)(d->addr + offset + 1), 0x00);
    d->actual = (uint16_t)(offset + 2);
    return 0;
}

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
            if (MKDIR_PCOMPAT(tmp) != 0 && errno != EEXIST) return -1;
            *p = '/';
        }
    }
    if (MKDIR_PCOMPAT(tmp) != 0 && errno != EEXIST) return -1;
    return 0;
}

static int build_target_path(const DiskDev *d, char *out, size_t out_sz)
{
    const char *fname = d->filename[0] ? d->filename : "basic.prg";
    int n = snprintf(out, out_sz, "%s/%s", d->root_path, fname);
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

static void execute_dir(DiskDev *d)
{
    if (write_basic_dir_listing(d) != 0) {
        set_status(d, DISK_ST_ERR, 6);
        return;
    }

    set_status(d, DISK_ST_OK, 0);
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
    case DISK_REG_FNAME_IDX: return d->fname_idx;
    case DISK_REG_FNAME_CHR:
        if (d->fname_idx < sizeof(d->filename)) {
            return (uint8_t)d->filename[d->fname_idx];
        }
        return 0;
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
        // Clear filename if not set (will use default)
        if (d->filename[0] == 0) {
            // Filename will be handled by build_target_path
        }
        if (val == DISK_CMD_SAVE) execute_save(d);
        else if (val == DISK_CMD_LOAD) execute_load(d);
        else if (val == DISK_CMD_DIR) execute_dir(d);
        // Clear filename after command for next operation
        d->filename[0] = 0;
        d->fname_idx = 0;
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
    case DISK_REG_FNAME_IDX:
        d->fname_idx = val;
        break;
    case DISK_REG_FNAME_CHR:
        if (d->fname_idx < sizeof(d->filename) - 1) {
            d->filename[d->fname_idx] = (char)val;
            // Auto null-terminate on index increment
            d->filename[d->fname_idx + 1] = 0;
        }
        break;
    default:
        break;
    }
}
