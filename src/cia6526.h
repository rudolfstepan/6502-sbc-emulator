#ifndef CIA6526_H
#define CIA6526_H

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    uint8_t regs[16];
    uint16_t timer_a;
    uint16_t latch_a;
    uint32_t timer_accum;
    uint8_t cycles_per_tick;
    uint8_t irq_mask;
    uint8_t irq_pending;
} CIA6526;

void cia_init(CIA6526 *cia);
void cia_init_native(CIA6526 *cia);
uint8_t cia_read(void *dev, uint16_t offset);
void cia_write(void *dev, uint16_t offset, uint8_t val);
void cia_tick(void *dev, uint32_t cycles);
bool cia_irq(const CIA6526 *cia);

#endif
