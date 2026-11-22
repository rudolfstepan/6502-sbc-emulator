#include "c64_floppy.h"
#include "media/d64.h"

#include <stdlib.h>
#include <string.h>

#define DIR_TRACK 18
#define DIR_FIRST_SECTOR 1
#define DIR_ENTRIES_PER_SECTOR 8
#define DIR_ENTRY_SIZE 32
#define DIR_NAME_SIZE 16
#define DIR_PROGRAM_CAPACITY 8192

#define KERNAL_LOAD 0xFFD5
#define KERNAL_LOAD_VECTOR 0x0330
#define KERNAL_STATUS 0x90
#define KERNAL_NAME_LEN 0xB7
#define KERNAL_SECONDARY 0xB9
#define KERNAL_DEVICE 0xBA
#define KERNAL_NAME_ADDR 0xBB
#define KERNAL_FILE_NOT_FOUND 4
#define KERNAL_MISSING_FILENAME 8
#define KERNAL_LOAD_ERROR 0x20
#define KERNAL_VERIFY_ERROR 0x10

bool c64_floppy_mount(C64Floppy *floppy, const char *path)
{
    FILE *image = fopen(path, "rb");
    if (!image) {
        fprintf(stderr, "C64: cannot open disk image '%s'\n", path);
        return false;
    }

    long size = fseek(image, 0, SEEK_END) == 0 ? ftell(image) : -1;
    if (size != D64_IMAGE_SIZE && size != D64_IMAGE_SIZE + D64_SECTOR_COUNT) {
        fprintf(stderr, "C64: expected a 35-track D64 image: '%s'\n", path);
        fclose(image);
        return false;
    }

    c64_floppy_close(floppy);
    floppy->image = image;
    printf("C64: mounted '%s' on device %u (read-only)\n", path, floppy->device);
    return true;
}

void c64_floppy_close(C64Floppy *floppy)
{
    if (floppy->image) {
        fclose(floppy->image);
        floppy->image = NULL;
    }
}

static uint8_t fold_name_byte(uint8_t byte)
{
    if (byte == 0xA0) {
        return ' ';
    }
    if (byte >= 'a' && byte <= 'z') {
        return byte - ('a' - 'A');
    }
    return byte;
}

static size_t directory_name_length(const uint8_t *name)
{
    size_t length = DIR_NAME_SIZE;
    while (length && (name[length - 1] == 0xA0 || name[length - 1] == 0)) {
        length--;
    }
    return length;
}

static bool matches_name(const uint8_t *pattern, const uint8_t *name)
{
    size_t length = directory_name_length(name);
    for (size_t i = 0; i < length; i++, pattern++) {
        if (*pattern == '*') {
            return true;
        }
        if (!*pattern || (*pattern != '?' && fold_name_byte(*pattern) != fold_name_byte(name[i]))) {
            return false;
        }
    }
    if (*pattern == '*') {
        return true;
    }
    while (fold_name_byte(*pattern) == ' ') {
        pattern++;
    }
    return *pattern == 0;
}

static bool append_line(uint8_t *data, size_t *length, unsigned int number,
                        const uint8_t *text, size_t text_len, uint16_t address)
{
    size_t end = *length + 5 + text_len;
    if (end + 2 > DIR_PROGRAM_CAPACITY || (size_t)address + end > UINT16_MAX) {
        return false;
    }
    unsigned int next = address + (unsigned int)end;
    uint8_t *line = data + *length;
    line[0] = (uint8_t)next;
    line[1] = (uint8_t)(next >> 8);
    line[2] = (uint8_t)number;
    line[3] = (uint8_t)(number >> 8);
    memcpy(line + 4, text, text_len);
    line[4 + text_len] = 0;
    *length = end;
    return true;
}

static void copy_display_name(uint8_t *dest, const uint8_t *source, size_t count)
{
    for (size_t i = 0; i < count; i++) {
        dest[i] = source[i] == 0xA0 || source[i] == 0 ? ' ' : source[i];
    }
}

static size_t make_directory(FILE *image, uint16_t address, uint8_t *data)
{
    uint8_t block[D64_SECTOR_SIZE];
    if (read_d64_sector(image, DIR_TRACK, 0, block) != 0) {
        return 0;
    }
    unsigned int free_blocks = 0;
    for (unsigned int track = 1; track <= 35; track++) {
        if (track != DIR_TRACK) {
            free_blocks += block[4 * track];
        }
    }

    uint8_t header[] = "\x12\"                \"      ";
    copy_display_name(header + 2, block + 0x90, DIR_NAME_SIZE);
    copy_display_name(header + 20, block + 0xA2, 5);
    size_t length = 0;
    if (!append_line(data, &length, 0, header, sizeof(header) - 1, address)) {
        return 0;
    }

    uint8_t track = DIR_TRACK;
    uint8_t sector = DIR_FIRST_SECTOR;
    for (unsigned int seen = 0; track && seen < D64_SECTOR_COUNT; seen++) {
        if (read_d64_sector(image, track, sector, block) != 0) {
            return 0;
        }
        for (size_t i = 0; i < DIR_ENTRIES_PER_SECTOR; i++) {
            const uint8_t *entry = block + 2 + i * DIR_ENTRY_SIZE;
            unsigned int type = entry[0] & 7;
            static const char types[][4] = {"DEL", "SEQ", "PRG", "USR", "REL"};
            if (!entry[0] || type >= sizeof(types) / sizeof(types[0])) {
                continue;
            }
            uint8_t text[] = "   \"                \" PRG";
            size_t name_length = directory_name_length(entry + 3);
            copy_display_name(text + 4, entry + 3, name_length);
            text[20] = ' ';
            text[4 + name_length] = '"';
            memcpy(text + 22, types[type], 3);
            unsigned int blocks = entry[28] | (entry[29] << 8);
            if (!append_line(data, &length, blocks, text, sizeof(text) - 1, address)) {
                return 0;
            }
        }
        track = block[0];
        sector = block[1];
    }

    static const uint8_t footer[] = "BLOCKS FREE.";
    if (track || !append_line(data, &length, free_blocks, footer, sizeof(footer) - 1, address)) {
        return 0;
    }
    data[length] = data[length + 1] = 0;
    return length + 2;
}

static uint8_t find_program(FILE *image, const uint8_t *name, uint8_t **data, size_t *length)
{
    uint8_t track = DIR_TRACK;
    uint8_t sector = DIR_FIRST_SECTOR;
    uint8_t block[D64_SECTOR_SIZE];
    for (unsigned int seen = 0; track && seen < D64_SECTOR_COUNT; seen++) {
        if (read_d64_sector(image, track, sector, block) != 0) {
            return KERNAL_LOAD_ERROR;
        }
        for (size_t i = 0; i < DIR_ENTRIES_PER_SECTOR; i++) {
            const uint8_t *entry = block + 2 + i * DIR_ENTRY_SIZE;
            if ((entry[0] & 7) == 2 && matches_name(name, entry + 3)) {
                if (d64_load_prg(image, entry[1], entry[2], data, length) != 0 || *length < 2) {
                    return KERNAL_LOAD_ERROR;
                }
                return 0;
            }
        }
        track = block[0];
        sector = block[1];
    }
    return track ? KERNAL_LOAD_ERROR : KERNAL_FILE_NOT_FOUND;
}

static uint8_t transfer(C64 *c64, CPU6502 *cpu, uint16_t address,
                        const uint8_t *data, size_t size)
{
    if (size > C64_RAM_SIZE - (size_t)address) {
        return KERNAL_LOAD_ERROR;
    }

    for (size_t i = 0; i < size; i++, address++) {
        if (cpu->A == 0) {
            c64_write(c64, address, data[i]);
        } else if (c64_read(c64, address) != data[i]) {
            c64->ram[KERNAL_STATUS] = KERNAL_VERIFY_ERROR;
        }
    }
    cpu->X = (uint8_t)address;
    cpu->Y = (uint8_t)(address >> 8);
    return 0;
}

static uint8_t load(C64Floppy *floppy, C64 *c64, CPU6502 *cpu)
{
    uint8_t filename[256];
    size_t length = c64->ram[KERNAL_NAME_LEN];
    uint16_t pointer = c64->ram[KERNAL_NAME_ADDR] | (c64->ram[KERNAL_NAME_ADDR + 1] << 8);
    for (size_t i = 0; i < length; i++) {
        filename[i] = c64_read(c64, (uint16_t)(pointer + i));
    }
    filename[length] = 0;
    const uint8_t *name = filename;
    if (length >= 2 && filename[0] == '0' && filename[1] == ':') {
        name += 2;
    }
    if (!*name) {
        return KERNAL_MISSING_FILENAME;
    }

    uint16_t address = cpu->X | (cpu->Y << 8);
    if (strcmp((const char *)name, "$") == 0 || strcmp((const char *)name, "$0") == 0) {
        uint8_t listing[DIR_PROGRAM_CAPACITY];
        size_t size = make_directory(floppy->image, address, listing);
        return size ? transfer(c64, cpu, address, listing, size) : KERNAL_LOAD_ERROR;
    }

    uint8_t *data = NULL;
    size_t size = 0;
    uint8_t error = find_program(floppy->image, name, &data, &size);
    if (!error) {
        if (c64->ram[KERNAL_SECONDARY] != 0) {
            address = data[0] | (data[1] << 8);
        }
        error = transfer(c64, cpu, address, data + 2, size - 2);
    }
    free(data);
    return error;
}

int c64_floppy_step(C64Floppy *floppy, C64 *c64, CPU6502 *cpu)
{
    /* Let banked-out ROM, patched LOAD vectors, and pending interrupts run normally. */
    if (cpu->PC != KERNAL_LOAD || !floppy->image || cpu->reset_pending || cpu->nmi_pending ||
        (cpu->irq_pending && !(cpu->P & FLAG_I)) || !(c64_read(c64, 1) & 2) ||
        c64->ram[KERNAL_DEVICE] != floppy->device || c64->ram[KERNAL_LOAD_VECTOR + 1] < 0xE0) {
        return 0;
    }

    uint8_t lo = c64_read(c64, 0x100 | (uint8_t)(cpu->SP + 1));
    uint8_t hi = c64_read(c64, 0x100 | (uint8_t)(cpu->SP + 2));
    c64->ram[KERNAL_STATUS] = 0;
    uint8_t error = load(floppy, c64, cpu);
    cpu->A = error;
    cpu->P = (cpu->P & ~FLAG_C) | (error ? FLAG_C : 0);
    cpu->SP += 2;
    cpu->PC = (uint16_t)((lo | (hi << 8)) + 1);
    cpu->cycles += 6;
    return 6;
}
