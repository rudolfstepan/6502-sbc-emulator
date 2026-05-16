#pragma once
#include <stdint.h>
#include <stddef.h>

typedef struct {
    uint8_t *data;
    uint32_t size;
} ROM;

int     rom_init(ROM *rom, uint32_t size);
int     rom_load(ROM *rom, const char *filename, uint32_t size);
void    rom_free(ROM *rom);
uint8_t rom_read(void *dev, uint16_t offset);
void    rom_write(void *dev, uint16_t offset, uint8_t val); /* no-op */
