#include "cia6526.h"
#include <string.h>

#define CIA_ICR 0x0D
#define CIA_CRA 0x0E
#define CIA_TIMER_START 0x01u
#define CIA_TIMER_ONESHOT 0x08u
#define CIA_TIMER_FORCE_LOAD 0x10u
#define CIA_TIMER_COUNT_CNT 0x20u
#define CIA_IRQ_TIMER_A 0x01u
#define CIA_IRQ_SOURCES 0x1Fu
#define CIA_IRQ_MASTER 0x80u

void cia_init_native(CIA6526 *cia)
{
    memset(cia, 0, sizeof(*cia));
    cia->latch_a = 0xFFFF;
    cia->timer_a = 0xFFFF;
    cia->cycles_per_tick = 1;
}

void cia_init(CIA6526 *cia)
{
    cia_init_native(cia);
    /* Preserve the SBC's 1 MHz timer on its 27 MHz bus. */
    cia->cycles_per_tick = 27;
}

uint8_t cia_read(void *dev, uint16_t offset)
{
    CIA6526 *cia = (CIA6526 *)dev;
    offset &= 0x0F;
    switch (offset) {
    case 4: return (uint8_t)(cia->timer_a & 0xFF);
    case 5: return (uint8_t)(cia->timer_a >> 8);
    case CIA_ICR: {
        uint8_t v = cia->irq_pending | (cia_irq(cia) ? CIA_IRQ_MASTER : 0);
        cia->irq_pending = 0;
        return v;
    }
    default:
        return cia->regs[offset];
    }
}

void cia_write(void *dev, uint16_t offset, uint8_t val)
{
    CIA6526 *cia = (CIA6526 *)dev;
    offset &= 0x0F;
    switch (offset) {
    case 4:
        cia->latch_a = (uint16_t)((cia->latch_a & 0xFF00) | val);
        break;
    case 5:
        cia->latch_a = (uint16_t)((cia->latch_a & 0x00FF) | ((uint16_t)val << 8));
        if (!(cia->regs[CIA_CRA] & CIA_TIMER_START)) {
            cia->timer_a = cia->latch_a;
        }
        break;
    case CIA_ICR:
        if (val & CIA_IRQ_MASTER) {
            cia->irq_mask |= val & CIA_IRQ_SOURCES;
        } else {
            cia->irq_mask &= (uint8_t)~(val & CIA_IRQ_SOURCES);
        }
        break;
    case CIA_CRA:
        cia->regs[offset] = val & ~CIA_TIMER_FORCE_LOAD;
        if (val & CIA_TIMER_FORCE_LOAD) {
            cia->timer_a = cia->latch_a;
        }
        break;
    default:
        cia->regs[offset] = val;
        break;
    }
}

void cia_tick(void *dev, uint32_t cycles)
{
    CIA6526 *cia = (CIA6526 *)dev;
    uint8_t control = cia->regs[CIA_CRA];
    if (!(control & CIA_TIMER_START) || (control & CIA_TIMER_COUNT_CNT)) {
        return;
    }

    uint64_t elapsed = (uint64_t)cia->timer_accum + cycles;
    uint32_t ticks = (uint32_t)(elapsed / cia->cycles_per_tick);
    cia->timer_accum = (uint32_t)(elapsed % cia->cycles_per_tick);
    uint32_t until_underflow = (uint32_t)cia->timer_a + 1;
    if (ticks < until_underflow) {
        cia->timer_a = (uint16_t)(cia->timer_a - ticks);
        return;
    }

    cia->irq_pending |= CIA_IRQ_TIMER_A;
    if (control & CIA_TIMER_ONESHOT) {
        cia->regs[CIA_CRA] &= (uint8_t)~CIA_TIMER_START;
        cia->timer_a = cia->latch_a;
    } else {
        uint32_t remaining = (ticks - until_underflow) % ((uint32_t)cia->latch_a + 1);
        cia->timer_a = (uint16_t)(cia->latch_a - remaining);
    }
}

bool cia_irq(const CIA6526 *cia)
{
    return (cia->irq_pending & cia->irq_mask) != 0;
}
