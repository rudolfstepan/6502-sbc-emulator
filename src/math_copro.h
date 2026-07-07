#ifndef MATH_COPRO_H
#define MATH_COPRO_H

#include <stdint.h>

typedef struct {
    int32_t a;
    int32_t b;
    uint8_t shift;
} MathCopro;

void math_copro_init(MathCopro *m);
uint8_t math_copro_read(void *dev, uint16_t offset);
void math_copro_write(void *dev, uint16_t offset, uint8_t val);

#endif
