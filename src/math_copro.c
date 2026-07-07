#include "math_copro.h"
#include <string.h>

static int64_t product(const MathCopro *m)
{
    return (int64_t)m->a * (int64_t)m->b;
}

static int32_t shifted_result(const MathCopro *m)
{
    int64_t p = product(m);
    uint8_t shift = m->shift & 0x3F;
    if (shift == 0) {
        return (int32_t)p;
    }
    return (int32_t)(p >> shift);
}

void math_copro_init(MathCopro *m)
{
    memset(m, 0, sizeof(*m));
    m->shift = 24;
}

uint8_t math_copro_read(void *dev, uint16_t offset)
{
    MathCopro *m = (MathCopro *)dev;
    offset &= 0x0F;

    if (offset < 8) {
        uint64_t p = (uint64_t)product(m);
        return (uint8_t)(p >> (offset * 8));
    }
    if (offset < 12) {
        uint32_t r = (uint32_t)shifted_result(m);
        return (uint8_t)(r >> ((offset - 8) * 8));
    }
    if (offset == 12) {
        return m->shift;
    }
    return 0x00;
}

void math_copro_write(void *dev, uint16_t offset, uint8_t val)
{
    MathCopro *m = (MathCopro *)dev;
    offset &= 0x0F;

    if (offset < 4) {
        uint32_t a = (uint32_t)m->a;
        a = (a & ~(0xFFu << (offset * 8))) | ((uint32_t)val << (offset * 8));
        m->a = (int32_t)a;
    } else if (offset < 8) {
        uint8_t byte = (uint8_t)(offset - 4);
        uint32_t b = (uint32_t)m->b;
        b = (b & ~(0xFFu << (byte * 8))) | ((uint32_t)val << (byte * 8));
        m->b = (int32_t)b;
    } else if (offset == 12) {
        m->shift = val & 0x3F;
    }
}
