#define _POSIX_C_SOURCE 200809L

#include "diskdev.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <errno.h>
#include <ctype.h>

#ifdef _WIN32
#include <direct.h>
#define MKDIR_PCOMPAT(path) _mkdir(path)
#else
#define MKDIR_PCOMPAT(path) mkdir((path), 0755)
#endif

#define BASIC_REM_TOKEN 0x8E
#define D64_TRACKS 35
#define D64_SECTOR_SIZE 256
#define D64_IMAGE_SIZE 174848

#define FPGA_ST_BUSY          0x01
#define FPGA_ST_DONE          0x02
#define FPGA_ST_ERROR         0x04
#define FPGA_ST_MOUNTED       0x08
#define FPGA_ST_WRITE_PROTECT 0x10
#define FPGA_ST_IMAGE_READY   0x40

#define FPGA_CMD_READ_SECTOR 0x01
#define FPGA_CMD_MOUNT       0x03
#define FPGA_CMD_UNMOUNT     0x04
#define FPGA_CMD_RAW_READ    0x05
#define FPGA_CMD_MOUNT_LBA   0x07
#define FPGA_CMD_RESET       0x0A

#define FPGA_RES_OK              0x00
#define FPGA_RES_NO_IMAGE        0x01
#define FPGA_RES_INVALID_TRACK   0x02
#define FPGA_RES_INVALID_SECTOR  0x03
#define FPGA_RES_SD_READ_ERROR   0x04
#define FPGA_RES_INVALID_COMMAND 0x0A
#define FPGA_RES_DIR_ERROR       0x0B

static const uint8_t d64_sectors_per_track[D64_TRACKS + 1] = {
    0,
    21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,
    19,19,19,19,19,19,19,
    18,18,18,18,18,18,
    17,17,17,17,17
};

static int cmp_dir_names(const void *lhs, const void *rhs)
{
    const char *const *left = lhs;
    const char *const *right = rhs;
    return strcmp(*left, *right);
}

static int strcasecmp_ascii(const char *a, const char *b)
{
    while (*a && *b) {
        unsigned char ca = (unsigned char)tolower((unsigned char)*a++);
        unsigned char cb = (unsigned char)tolower((unsigned char)*b++);
        if (ca != cb) return (int)ca - (int)cb;
    }
    return (unsigned char)*a - (unsigned char)*b;
}

static int ends_with_ignore_case(const char *s, const char *suffix)
{
    size_t slen = strlen(s);
    size_t tlen = strlen(suffix);
    if (slen < tlen) return 0;
    return strcasecmp_ascii(s + slen - tlen, suffix) == 0;
}

static long d64_sector_offset(uint8_t track, uint8_t sector)
{
    if (track < 1 || track > D64_TRACKS || sector >= d64_sectors_per_track[track]) {
        return -1;
    }

    long offset = 0;
    for (uint8_t t = 1; t < track; t++) {
        offset += (long)d64_sectors_per_track[t] * D64_SECTOR_SIZE;
    }
    return offset + (long)sector * D64_SECTOR_SIZE;
}

static int read_d64_sector(FILE *f, uint8_t track, uint8_t sector, uint8_t out[D64_SECTOR_SIZE])
{
    long offset = d64_sector_offset(track, sector);
    if (offset < 0 || fseek(f, offset, SEEK_SET) != 0) {
        return -1;
    }
    return fread(out, 1, D64_SECTOR_SIZE, f) == D64_SECTOR_SIZE ? 0 : -1;
}

static void d64_name_to_ascii(const uint8_t raw[16], char out[17])
{
    size_t n = 0;
    for (size_t i = 0; i < 16; i++) {
        uint8_t c = raw[i];
        if (c == 0xA0 || c == 0x00) {
            break;
        }
        out[n++] = (char)tolower(c >= 'A' && c <= 'Z' ? c : raw[i]);
    }
    out[n] = 0;
}

static void normalize_prg_name(const char *in, char out[32])
{
    size_t n = 0;
    while (*in && n < 31) {
        char c = (char)tolower((unsigned char)*in++);
        if (c == '/') c = '_';
        out[n++] = c;
    }
    out[n] = 0;
    if (ends_with_ignore_case(out, ".prg")) {
        out[n - 4] = 0;
    }
}

static int d64_find_prg(FILE *f, const char *name, uint8_t *track, uint8_t *sector,
                        char found_name[17])
{
    char want[32];
    normalize_prg_name(name, want);

    uint8_t dt = 18;
    uint8_t ds = 1;
    uint8_t buf[D64_SECTOR_SIZE];
    int guard = 0;

    while (dt != 0 && guard++ < 32) {
        if (read_d64_sector(f, dt, ds, buf) != 0) {
            return -1;
        }

        for (int i = 0; i < 8; i++) {
            size_t off = 2 + (size_t)i * 32;
            uint8_t type = buf[off + 0] & 0x07;
            if (type != 0x02) {
                continue;
            }

            char entry_name[17];
            d64_name_to_ascii(&buf[off + 3], entry_name);
            if (found_name) {
                snprintf(found_name, 17, "%s", entry_name);
            }
            if (strcasecmp_ascii(entry_name, want) == 0) {
                *track = buf[off + 1];
                *sector = buf[off + 2];
                return 0;
            }
        }

        dt = buf[0];
        ds = buf[1];
    }
    return -1;
}

static int d64_load_prg(FILE *f, uint8_t track, uint8_t sector,
                        uint8_t **out, size_t *out_len)
{
    size_t cap = 4096;
    size_t len = 0;
    uint8_t *data = (uint8_t *)malloc(cap);
    uint8_t buf[D64_SECTOR_SIZE];
    int guard = 0;

    if (!data) return -1;

    while (track != 0 && guard++ < 1024) {
        if (read_d64_sector(f, track, sector, buf) != 0) {
            free(data);
            return -1;
        }

        uint8_t next_track = buf[0];
        uint8_t next_sector = buf[1];
        size_t chunk_len = next_track == 0 ? (next_sector > 1 ? next_sector - 1 : 0) : 254;
        if (len + chunk_len > cap) {
            while (len + chunk_len > cap) cap *= 2;
            uint8_t *grown = (uint8_t *)realloc(data, cap);
            if (!grown) {
                free(data);
                return -1;
            }
            data = grown;
        }
        memcpy(data + len, buf + 2, chunk_len);
        len += chunk_len;
        track = next_track;
        sector = next_sector;
    }

    *out = data;
    *out_len = len;
    return 0;
}

static int mount_first_d64(DiskDev *d)
{
    DIR *dir = opendir(d->sdcard_path);
    if (!dir) {
        return -1;
    }

    char *names[256];
    size_t count = 0;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL && count < sizeof(names) / sizeof(names[0])) {
        if (entry->d_name[0] == '.' || !ends_with_ignore_case(entry->d_name, ".d64")) {
            continue;
        }
        names[count] = strdup(entry->d_name);
        if (!names[count]) {
            closedir(dir);
            return -1;
        }
        count++;
    }
    closedir(dir);

    if (count == 0) {
        return -1;
    }
    qsort(names, count, sizeof(names[0]), cmp_dir_names);
    snprintf(d->mounted_d64, sizeof(d->mounted_d64), "%s/%s", d->sdcard_path, names[0]);
    d->status = DISK_ST_OK;
    d->fpga_status = FPGA_ST_DONE | FPGA_ST_MOUNTED | FPGA_ST_WRITE_PROTECT | FPGA_ST_IMAGE_READY;
    d->fpga_result = FPGA_RES_OK;
    for (size_t i = 0; i < count; i++) {
        free(names[i]);
    }
    return 0;
}

static int collect_d64_names(const DiskDev *d, char **names, size_t max_names)
{
    DIR *dir = opendir(d->sdcard_path);
    if (!dir) {
        return -1;
    }

    size_t count = 0;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL && count < max_names) {
        if (entry->d_name[0] == '.' || !ends_with_ignore_case(entry->d_name, ".d64")) {
            continue;
        }
        names[count] = strdup(entry->d_name);
        if (!names[count]) {
            closedir(dir);
            for (size_t i = 0; i < count; i++) {
                free(names[i]);
            }
            return -1;
        }
        count++;
    }
    closedir(dir);
    qsort(names, count, sizeof(names[0]), cmp_dir_names);
    return (int)count;
}

static void free_d64_names(char **names, size_t count)
{
    for (size_t i = 0; i < count; i++) {
        free(names[i]);
    }
}

static int mount_d64_index(DiskDev *d, size_t wanted)
{
    char *names[256];
    int count = collect_d64_names(d, names, sizeof(names) / sizeof(names[0]));
    if (count <= 0 || wanted >= (size_t)count) {
        if (count > 0) {
            free_d64_names(names, (size_t)count);
        }
        return -1;
    }

    snprintf(d->mounted_d64, sizeof(d->mounted_d64), "%s/%s", d->sdcard_path, names[wanted]);
    free_d64_names(names, (size_t)count);
    d->status = DISK_ST_OK;
    d->fpga_status = FPGA_ST_DONE | FPGA_ST_MOUNTED | FPGA_ST_WRITE_PROTECT | FPGA_ST_IMAGE_READY;
    d->fpga_result = FPGA_RES_OK;
    return 0;
}

static int build_sdcard_d64_path(const DiskDev *d, const char *name,
                                 char *out, size_t out_sz)
{
    char image_name[64];
    size_t n = 0;

    while (name[n] && n < sizeof(image_name) - 5) {
        char c = (char)tolower((unsigned char)name[n]);
        if (c == '/' || c == '\\' || c == ':') {
            return -1;
        }
        image_name[n++] = c;
    }
    image_name[n] = 0;
    if (n == 0) {
        return -1;
    }
    if (!ends_with_ignore_case(image_name, ".d64")) {
        snprintf(image_name + n, sizeof(image_name) - n, ".d64");
    }

    int len = snprintf(out, out_sz, "%s/%s", d->sdcard_path, image_name);
    return (len > 0 && (size_t)len < out_sz) ? 0 : -1;
}

static int mount_named_d64(DiskDev *d, const char *name)
{
    char path[512];
    FILE *f;

    if (build_sdcard_d64_path(d, name, path, sizeof(path)) != 0) {
        return -1;
    }

    f = fopen(path, "rb");
    if (!f) {
        return -1;
    }
    fclose(f);
    snprintf(d->mounted_d64, sizeof(d->mounted_d64), "%s", path);
    d->status = DISK_ST_OK;
    d->fpga_status = FPGA_ST_DONE | FPGA_ST_MOUNTED | FPGA_ST_WRITE_PROTECT | FPGA_ST_IMAGE_READY;
    d->fpga_result = FPGA_RES_OK;
    return 0;
}

static void fpga_set_result(DiskDev *d, uint8_t result)
{
    uint8_t mounted = d->mounted_d64[0] ? FPGA_ST_MOUNTED | FPGA_ST_WRITE_PROTECT | FPGA_ST_IMAGE_READY : 0;
    d->fpga_result = result;
    d->fpga_status = FPGA_ST_DONE | mounted | (result == FPGA_RES_OK ? 0 : FPGA_ST_ERROR);
}

static void make_fat_name(const char *filename, uint8_t out[11])
{
    memset(out, ' ', 11);
    size_t n = 0;
    for (const char *p = filename; *p && *p != '.' && n < 8; p++) {
        out[n++] = (uint8_t)toupper((unsigned char)*p);
    }
    out[8] = 'D';
    out[9] = '6';
    out[10] = '4';
}

static void fill_virtual_sd_sector(DiskDev *d, uint32_t lba, uint8_t upper_half)
{
    uint8_t sector[512];
    memset(sector, 0, sizeof(sector));

    if (lba == 0) {
        sector[0] = 0xEB;          /* Superfloppy BPB, so the ROM skips MBR parsing. */
        sector[2] = 0x90;
        sector[11] = 0x00;         /* bytes/sector = 512 */
        sector[12] = 0x02;
        sector[13] = 0x01;         /* sectors/cluster */
        sector[14] = 0x01;         /* reserved sectors */
        sector[16] = 0x01;         /* FAT count */
        sector[36] = 0x01;         /* sectors/FAT */
        sector[44] = 0x02;         /* root cluster */
        sector[510] = 0x55;
        sector[511] = 0xAA;
    } else if (lba == 2) {
        char *names[16];
        int count = collect_d64_names(d, names, sizeof(names) / sizeof(names[0]));
        if (count > 0) {
            for (int i = 0; i < count && i < 16; i++) {
                size_t off = (size_t)i * 32;
                uint8_t fat_name[11];
                uint32_t cluster = (uint32_t)(3 + i);
                make_fat_name(names[i], fat_name);
                memcpy(sector + off, fat_name, 11);
                sector[off + 11] = 0x20; /* archive */
                sector[off + 20] = (uint8_t)((cluster >> 16) & 0xFF);
                sector[off + 21] = (uint8_t)((cluster >> 24) & 0xFF);
                sector[off + 26] = (uint8_t)(cluster & 0xFF);
                sector[off + 27] = (uint8_t)((cluster >> 8) & 0xFF);
                sector[off + 28] = (uint8_t)(D64_IMAGE_SIZE & 0xFF);
                sector[off + 29] = (uint8_t)((D64_IMAGE_SIZE >> 8) & 0xFF);
                sector[off + 30] = (uint8_t)((D64_IMAGE_SIZE >> 16) & 0xFF);
                sector[off + 31] = (uint8_t)((D64_IMAGE_SIZE >> 24) & 0xFF);
            }
            free_d64_names(names, (size_t)count);
        }
    }

    memcpy(d->fpga_sector_buf, sector + (upper_half ? 256 : 0), sizeof(d->fpga_sector_buf));
    d->fpga_ptr = 0;
}

static void fpga_read_d64_sector(DiskDev *d)
{
    FILE *f;

    if (!d->mounted_d64[0]) {
        fpga_set_result(d, FPGA_RES_NO_IMAGE);
        return;
    }
    if (d->fpga_track < 1 || d->fpga_track > D64_TRACKS) {
        fpga_set_result(d, FPGA_RES_INVALID_TRACK);
        return;
    }
    if (d->fpga_sector >= d64_sectors_per_track[d->fpga_track]) {
        fpga_set_result(d, FPGA_RES_INVALID_SECTOR);
        return;
    }

    f = fopen(d->mounted_d64, "rb");
    if (!f) {
        fpga_set_result(d, FPGA_RES_SD_READ_ERROR);
        return;
    }
    if (read_d64_sector(f, d->fpga_track, d->fpga_sector, d->fpga_sector_buf) != 0) {
        fclose(f);
        fpga_set_result(d, FPGA_RES_SD_READ_ERROR);
        return;
    }
    fclose(f);
    d->fpga_ptr = 0;
    fpga_set_result(d, FPGA_RES_OK);
}

static void fpga_execute_command(DiskDev *d, uint8_t cmd)
{
    uint32_t lba = (uint32_t)d->fpga_raw_lba[0] |
                   ((uint32_t)d->fpga_raw_lba[1] << 8) |
                   ((uint32_t)d->fpga_raw_lba[2] << 16) |
                   ((uint32_t)d->fpga_raw_lba[3] << 24);

    switch (cmd) {
    case FPGA_CMD_READ_SECTOR:
        fpga_read_d64_sector(d);
        break;
    case FPGA_CMD_MOUNT:
        if (d->mounted_d64[0] || mount_first_d64(d) == 0) fpga_set_result(d, FPGA_RES_OK);
        else fpga_set_result(d, FPGA_RES_DIR_ERROR);
        break;
    case FPGA_CMD_UNMOUNT:
        d->mounted_d64[0] = 0;
        fpga_set_result(d, FPGA_RES_OK);
        break;
    case FPGA_CMD_RAW_READ:
        fill_virtual_sd_sector(d, lba, d->fpga_track != 0);
        fpga_set_result(d, FPGA_RES_OK);
        break;
    case FPGA_CMD_MOUNT_LBA:
        if (lba >= 3 && mount_d64_index(d, (size_t)(lba - 3)) == 0) fpga_set_result(d, FPGA_RES_OK);
        else fpga_set_result(d, FPGA_RES_DIR_ERROR);
        break;
    case FPGA_CMD_RESET:
        fpga_set_result(d, FPGA_RES_OK);
        break;
    case 0:
        break;
    default:
        fpga_set_result(d, FPGA_RES_INVALID_COMMAND);
        break;
    }
}

static int write_basic_dir_entries(DiskDev *d, char **names, size_t name_count)
{
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

    if ((uint32_t)offset + 2 > d->len) {
        return -1;
    }

    bus_write(d->bus, (uint16_t)(d->addr + offset), 0x00);
    bus_write(d->bus, (uint16_t)(d->addr + offset + 1), 0x00);
    d->actual = (uint16_t)(offset + 2);
    return 0;
}

static int write_host_dir_listing(DiskDev *d)
{
    DIR *dir = opendir(d->root_path);
    if (!dir) {
        return -1;
    }

    char *names[256];
    size_t name_count = 0;
    struct dirent *entry;

    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.' || name_count >= sizeof(names) / sizeof(names[0])) {
            continue;
        }
        names[name_count] = strdup(entry->d_name);
        if (!names[name_count]) {
            closedir(dir);
            return -1;
        }
        name_count++;
    }

    closedir(dir);
    int rc = write_basic_dir_entries(d, names, name_count);
    for (size_t i = 0; i < name_count; i++) {
        free(names[i]);
    }
    return rc;
}

static int write_d64_dir_listing(DiskDev *d)
{
    if (!d->mounted_d64[0]) {
        return -1;
    }

    FILE *f = fopen(d->mounted_d64, "rb");
    if (!f) {
        return -1;
    }

    char *names[256];
    size_t name_count = 0;
    uint8_t dt = 18;
    uint8_t ds = 1;
    uint8_t buf[D64_SECTOR_SIZE];
    int guard = 0;

    while (dt != 0 && guard++ < 32 && name_count < sizeof(names) / sizeof(names[0])) {
        if (read_d64_sector(f, dt, ds, buf) != 0) {
            fclose(f);
            return -1;
        }
        for (int i = 0; i < 8 && name_count < sizeof(names) / sizeof(names[0]); i++) {
            size_t off = 2 + (size_t)i * 32;
            if ((buf[off + 0] & 0x07) != 0x02) {
                continue;
            }
            char entry_name[17];
            char display[32];
            d64_name_to_ascii(&buf[off + 3], entry_name);
            snprintf(display, sizeof(display), "%s.prg", entry_name);
            names[name_count] = strdup(display);
            if (!names[name_count]) {
                fclose(f);
                return -1;
            }
            name_count++;
        }
        dt = buf[0];
        ds = buf[1];
    }
    fclose(f);

    int rc = write_basic_dir_entries(d, names, name_count);
    for (size_t i = 0; i < name_count; i++) {
        free(names[i]);
    }
    return rc;
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
    if (d->filename[0] && ends_with_ignore_case(d->filename, ".d64")) {
        if (mount_named_d64(d, d->filename) == 0 && write_d64_dir_listing(d) == 0) {
            set_status(d, DISK_ST_OK, 0);
        } else {
            set_status(d, DISK_ST_ERR, 7);
        }
        return;
    }

    if (d->mounted_d64[0]) {
        FILE *img = fopen(d->mounted_d64, "rb");
        if (img) {
            uint8_t track = 0;
            uint8_t sector = 0;
            if (d64_find_prg(img, d->filename[0] ? d->filename : "basic.prg",
                             &track, &sector, NULL) == 0) {
                uint8_t *prg = NULL;
                size_t prg_len = 0;
                if (d64_load_prg(img, track, sector, &prg, &prg_len) == 0) {
                    size_t start = prg_len >= 2 ? 2 : 0; /* Skip D64 PRG load address. */
                    d->actual = 0;
                    set_status(d, DISK_ST_OK, 0);
                    for (uint16_t i = 0; i < d->len && start + i < prg_len; i++) {
                        bus_write(d->bus, (uint16_t)(d->addr + i), prg[start + i]);
                        d->actual++;
                    }
                    free(prg);
                    fclose(img);
                    return;
                }
                free(prg);
            }
            fclose(img);
        }
    }

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

    int b0 = fgetc(f);
    int b1 = fgetc(f);
    uint16_t file_load_addr = 0;
    if (b0 != EOF && b1 != EOF) {
        file_load_addr = (uint16_t)((uint8_t)b0 | ((uint16_t)(uint8_t)b1 << 8));
    }
    if (b0 == EOF || b1 == EOF || file_load_addr != d->addr) {
        rewind(f);
    }

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
    if ((d->mounted_d64[0] && write_d64_dir_listing(d) != 0) ||
        (!d->mounted_d64[0] && write_host_dir_listing(d) != 0)) {
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
    snprintf(d->sdcard_path, sizeof(d->sdcard_path), "%s", "data/sdcard");
    if (mount_first_d64(d) != 0) {
        d->status = 0;
    }
    return 0;
}

uint8_t diskdev_read(void *dev, uint16_t offset)
{
    DiskDev *d = (DiskDev *)dev;
    switch (offset & 0x0F) {
    case 0x00: return d->fpga_status;
    case DISK_REG_STATUS:  return d->status;
    case DISK_REG_ADDR_LO: return (uint8_t)(d->addr & 0xFF);
    case DISK_REG_ADDR_HI: return (uint8_t)(d->addr >> 8);
    case DISK_REG_LEN_LO:  return d->fpga_result;
    case DISK_REG_LEN_HI: {
        uint8_t data = d->fpga_sector_buf[d->fpga_ptr];
        d->fpga_ptr++;
        return data;
    }
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
    case DISK_REG_STATUS:
        fpga_execute_command(d, val);
        break;
    case DISK_REG_ADDR_LO:
        d->addr = (uint16_t)((d->addr & 0xFF00) | val);
        d->fpga_track = val;
        break;
    case DISK_REG_ADDR_HI:
        d->addr = (uint16_t)((d->addr & 0x00FF) | ((uint16_t)val << 8));
        d->fpga_sector = val;
        break;
    case DISK_REG_LEN_LO:
        d->len = (uint16_t)((d->len & 0xFF00) | val);
        break;
    case DISK_REG_LEN_HI:
        d->len = (uint16_t)((d->len & 0x00FF) | ((uint16_t)val << 8));
        break;
    case DISK_REG_ACT_LO:
        d->fpga_ptr = val;
        break;
    case DISK_REG_FNAME_IDX:
        d->fname_idx = val;
        d->fpga_raw_lba[1] = val;
        break;
    case DISK_REG_FNAME_CHR:
        if (d->fname_idx < sizeof(d->filename) - 1) {
            d->filename[d->fname_idx] = (char)val;
            // Auto null-terminate on index increment
            d->filename[d->fname_idx + 1] = 0;
        }
        d->fpga_raw_lba[2] = val;
        break;
    case 0x08:
        d->fpga_raw_lba[0] = val;
        break;
    case 0x0B:
        d->fpga_raw_lba[3] = val;
        break;
    default:
        break;
    }
}
