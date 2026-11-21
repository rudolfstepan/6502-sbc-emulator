#ifndef MATH_COPRO_H
#define MATH_COPRO_H

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    uint32_t a;
    uint32_t b;
    uint64_t product;
    uint8_t shift;
    bool product_dirty;
} MathCopro;

void math_copro_init(MathCopro *m);
uint8_t math_copro_read(void *dev, uint16_t offset);
void math_copro_write(void *dev, uint16_t offset, uint8_t val);

#endif
