#pragma once
#include <stdint.h>
#include <stddef.h>

typedef struct {
    uint8_t *data;
    uint32_t size;
} SRAM;

int     sram_init(SRAM *ram, uint32_t size);
void    sram_free(SRAM *ram);
uint8_t sram_read(void *dev, uint16_t offset);
void    sram_write(void *dev, uint16_t offset, uint8_t val);
