#include "sram.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

int sram_init(SRAM *ram, uint32_t size)
{
    ram->data = calloc(1, size);
    if (!ram->data) {
        perror("sram_init: calloc");
        return -1;
    }
    ram->size = size;
    return 0;
}

void sram_free(SRAM *ram)
{
    free(ram->data);
    ram->data = NULL;
    ram->size = 0;
}

uint8_t sram_read(void *dev, uint16_t offset)
{
    SRAM *ram = (SRAM *)dev;
    if (offset < ram->size)
        return ram->data[offset];
    return 0xFF;
}

void sram_write(void *dev, uint16_t offset, uint8_t val)
{
    SRAM *ram = (SRAM *)dev;
    if (offset < ram->size)
        ram->data[offset] = val;
}
