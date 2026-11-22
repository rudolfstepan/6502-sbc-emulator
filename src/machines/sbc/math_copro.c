#include "math_copro.h"
#include <string.h>

static int64_t signed_operand(uint32_t bits)
{
    int64_t value = bits;
    if (bits & UINT32_C(0x80000000)) {
        value -= INT64_C(0x100000000);
    }
    return value;
}

static uint64_t scaled_product(uint64_t product, uint8_t shift)
{
    uint64_t scaled = product >> shift;
    if (shift != 0 && (product & (UINT64_C(1) << 63))) {
        scaled |= UINT64_MAX << (64 - shift);
    }
    return scaled;
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

    if (offset < 12) {
        /* The FPGA's pipeline settles between the 6502's writes and result reads. */
        if (m->product_dirty) {
            m->product = (uint64_t)(signed_operand(m->a) * signed_operand(m->b));
            m->product_dirty = false;
        }
        if (offset < 8) {
            return (uint8_t)(m->product >> (offset * 8));
        }
        uint64_t scaled = scaled_product(m->product, m->shift);
        return (uint8_t)(scaled >> ((offset - 8) * 8));
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

    if (offset < 8) {
        uint32_t *operand = offset < 4 ? &m->a : &m->b;
        unsigned int bit = (offset % 4) * 8;
        *operand = (*operand & ~(UINT32_C(0xFF) << bit)) | ((uint32_t)val << bit);
        m->product_dirty = true;
    } else if (offset == 12) {
        m->shift = val & 0x3F;
    }
}
