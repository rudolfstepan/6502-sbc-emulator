#include "apple2_disk.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    TRACK_COUNT = 35,
    TRACK_BYTES = 6656,
    SECTOR_COUNT = 16,
    SECTOR_BYTES = 256,
    SECTOR_TRACK_BYTES = SECTOR_COUNT * SECTOR_BYTES,
    NIBBLE_CYCLES = 32,
    /* The controller holds its motor-enable output for about one second. */
    MOTOR_OFF_DELAY = 1020484
};

static const uint8_t dos_order[SECTOR_COUNT] = {
    0, 7, 14, 6, 13, 5, 12, 4, 11, 3, 10, 2, 9, 1, 8, 15
};

static const uint8_t prodos_order[SECTOR_COUNT] = {
    0, 8, 1, 9, 2, 10, 3, 11, 4, 12, 5, 13, 6, 14, 7, 15
};

static const uint8_t gcr_code[64] = {
    0x96, 0x97, 0x9A, 0x9B, 0x9D, 0x9E, 0x9F, 0xA6,
    0xA7, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF, 0xB2, 0xB3,
    0xB4, 0xB5, 0xB6, 0xB7, 0xB9, 0xBA, 0xBB, 0xBC,
    0xBD, 0xBE, 0xBF, 0xCB, 0xCD, 0xCE, 0xCF, 0xD3,
    0xD6, 0xD7, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE,
    0xDF, 0xE5, 0xE6, 0xE7, 0xE9, 0xEA, 0xEB, 0xEC,
    0xED, 0xEE, 0xEF, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6,
    0xF7, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF
};

static uint8_t *encode_address(uint8_t *out, uint8_t value)
{
    *out++ = (value >> 1) | 0xAA;
    *out++ = value | 0xAA;
    return out;
}

static void encode_sector(uint8_t *out, const uint8_t *data)
{
    enum { AUX_BYTES = 86 };
    uint8_t aux[AUX_BYTES] = {0};
    for (unsigned i = 0; i < SECTOR_BYTES; ++i) {
        /* The Disk II stores the two low bits in reverse order. */
        unsigned low_bits = ((data[i] & 1) << 1) | ((data[i] & 2) >> 1);
        aux[i % AUX_BYTES] |= low_bits << (2 * (i / AUX_BYTES));
    }

    unsigned previous = 0;
    for (unsigned i = 0; i < AUX_BYTES; ++i) {
        *out++ = gcr_code[previous ^ aux[i]];
        previous = aux[i];
    }
    for (unsigned i = 0; i < SECTOR_BYTES; ++i) {
        unsigned value = data[i] >> 2;
        *out++ = gcr_code[previous ^ value];
        previous = value;
    }
    *out = gcr_code[previous];
}

static void encode_track(uint8_t *out, const uint8_t *data, unsigned track,
                         const uint8_t *order)
{
    static const uint8_t epilogue[] = {0xDE, 0xAA, 0xEB};
    const uint8_t volume = 254;
    enum { GCR_BYTES = 343, SECTOR_SPAN = 400 };

    memset(out, 0xFF, TRACK_BYTES);
    for (unsigned sector = 0; sector < SECTOR_COUNT; ++sector) {
        uint8_t *field = out + sector * SECTOR_SPAN + 24;
        *field++ = 0xD5;
        *field++ = 0xAA;
        *field++ = 0x96;
        field = encode_address(field, volume);
        field = encode_address(field, track);
        field = encode_address(field, sector);
        field = encode_address(field, volume ^ track ^ sector);
        memcpy(field, epilogue, sizeof(epilogue));
        field += sizeof(epilogue) + 6;

        *field++ = 0xD5;
        *field++ = 0xAA;
        *field++ = 0xAD;
        encode_sector(field, data + order[sector] * SECTOR_BYTES);
        memcpy(field + GCR_BYTES, epilogue, sizeof(epilogue));
    }
}

static bool has_extension(const char *path, const char *extension)
{
    const char *suffix = strrchr(path, '.');
    if (!suffix) return false;
    while (*suffix && tolower((unsigned char)*suffix) == *extension) {
        ++suffix;
        ++extension;
    }
    return *suffix == *extension;
}

bool apple2_disk_mount(Apple2Disk *disk, const char *path)
{
    bool nibble = has_extension(path, ".nib");
    bool prodos = has_extension(path, ".po");
    if (!nibble && !prodos && !has_extension(path, ".do") &&
        !has_extension(path, ".dsk")) {
        fprintf(stderr, "Apple II: unsupported disk format '%s' (use .dsk, .do, .po or .nib)\n",
                path);
        return false;
    }

    FILE *file = fopen(path, "rb");
    if (!file) {
        fprintf(stderr, "Apple II: cannot open disk '%s'\n", path);
        return false;
    }
    uint8_t *tracks = malloc(TRACK_COUNT * TRACK_BYTES);
    if (!tracks) {
        fprintf(stderr, "Apple II: out of memory mounting '%s'\n", path);
        fclose(file);
        return false;
    }

    uint8_t sectors[SECTOR_TRACK_BYTES];
    bool ok = true;
    for (unsigned track = 0; track < TRACK_COUNT && ok; ++track) {
        uint8_t *destination = tracks + track * TRACK_BYTES;
        if (nibble) {
            ok = fread(destination, 1, TRACK_BYTES, file) == TRACK_BYTES;
        } else {
            ok = fread(sectors, 1, sizeof(sectors), file) == sizeof(sectors);
            if (ok) {
                encode_track(destination, sectors, track, prodos ? prodos_order : dos_order);
            }
        }
    }
    ok = ok && fgetc(file) == EOF && !ferror(file);
    fclose(file);
    if (!ok) {
        fprintf(stderr, "Apple II: invalid or unreadable 35-track disk '%s'\n", path);
        free(tracks);
        return false;
    }

    free(disk->tracks);
    disk->tracks = tracks;
    disk->latch = 0;
    return true;
}

void apple2_disk_eject(Apple2Disk *disk)
{
    free(disk->tracks);
    disk->tracks = NULL;
    disk->latch = 0;
}

void apple2_disk_reset(Apple2Disk *disk)
{
    disk->phases = disk->latch = 0;
    disk->motor = disk->drive_two = disk->q6 = disk->q7 = false;
    disk->coast_cycles = 0;
}

void apple2_disk_tick(Apple2Disk *disk, unsigned cycles)
{
    if (!disk->motor) {
        if (cycles > disk->coast_cycles) cycles = disk->coast_cycles;
        disk->coast_cycles -= cycles;
    }
    if (disk->drive_two || !disk->tracks || cycles == 0) return;
    disk->rotation_cycles += cycles;
    if (disk->rotation_cycles < NIBBLE_CYCLES) return;

    unsigned count = disk->rotation_cycles / NIBBLE_CYCLES;
    disk->rotation_cycles %= NIBBLE_CYCLES;
    unsigned track = disk->half_track / 2;
    unsigned index = (disk->position + count - 1) % TRACK_BYTES;
    disk->position = (index + 1) % TRACK_BYTES;
    if (!disk->q6 && !disk->q7)
        disk->latch = disk->tracks[track * TRACK_BYTES + index];
}

static void step_head(Apple2Disk *disk, unsigned address)
{
    unsigned phase = address / 2;
    unsigned mask = 1u << phase;
    if (!(address & 1)) {
        disk->phases &= ~mask;
        return;
    }
    if (disk->phases & mask) return;
    disk->phases |= mask;
    if (disk->drive_two) return;

    unsigned offset = (phase + 4 - disk->half_track % 4) % 4;
    if (offset == 1 && disk->half_track < 2 * (TRACK_COUNT - 1)) {
        ++disk->half_track;
    } else if (offset == 3 && disk->half_track > 0) {
        --disk->half_track;
    }
}

uint8_t apple2_disk_switch(Apple2Disk *disk, unsigned address)
{
    if (address < 8) {
        step_head(disk, address);
    } else {
        switch (address) {
        case 8:
            if (disk->motor) disk->coast_cycles = MOTOR_OFF_DELAY;
            disk->motor = false;
            break;
        case 9:
            disk->motor = true;
            disk->coast_cycles = 0;
            break;
        case 10: disk->drive_two = false; break;
        case 11: disk->drive_two = true; break;
        case 12: disk->q6 = false; break;
        case 13: disk->q6 = true; break;
        case 14: disk->q7 = false; break;
        case 15: disk->q7 = true; break;
        }
    }
    if ((address & 1) || disk->q7) return 0;
    if (disk->q6) return 0x80; /* Write-protected media. */
    if ((!disk->motor && !disk->coast_cycles) || disk->drive_two || !disk->tracks) {
        return 0;
    }

    uint8_t result = disk->latch;
    disk->latch &= 0x7F;
    return result;
}
