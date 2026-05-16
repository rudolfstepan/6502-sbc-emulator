#include "rom.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

int rom_init(ROM *rom, uint32_t size)
{
    rom->data = calloc(1, size);
    if (!rom->data) {
        perror("rom_init: calloc");
        return -1;
    }
    memset(rom->data, 0xFF, size);
    rom->size = size;
    return 0;
}

int rom_load(ROM *rom, const char *filename, uint32_t size)
{
    FILE *f = fopen(filename, "rb");
    if (!f) {
        fprintf(stderr, "rom_load: cannot open '%s': ", filename);
        perror("");
        return -1;
    }

    /* determine file size */
    fseek(f, 0, SEEK_END);
    long fsize = ftell(f);
    fseek(f, 0, SEEK_SET);

    if (fsize <= 0) {
        fprintf(stderr, "rom_load: empty file '%s'\n", filename);
        fclose(f);
        return -1;
    }

    if (rom_init(rom, size) != 0) {
        fclose(f);
        return -1;
    }

    /* load into the end of the ROM region (top-aligned) */
    uint32_t load_size = (uint32_t)fsize < size ? (uint32_t)fsize : size;
    uint32_t offset    = size - load_size;
    size_t   n         = fread(rom->data + offset, 1, load_size, f);
    fclose(f);

    if (n != load_size) {
        fprintf(stderr, "rom_load: short read from '%s'\n", filename);
        return -1;
    }

    printf("ROM: loaded '%s' (%ld bytes) into %u-byte window\n",
           filename, fsize, size);
    return 0;
}

void rom_free(ROM *rom)
{
    free(rom->data);
    rom->data = NULL;
    rom->size = 0;
}

uint8_t rom_read(void *dev, uint16_t offset)
{
    ROM *rom = (ROM *)dev;
    if (offset < rom->size)
        return rom->data[offset];
    return 0xFF;
}

void rom_write(void *dev, uint16_t offset, uint8_t val)
{
    (void)dev; (void)offset; (void)val;
    /* ROM is read-only */
}
