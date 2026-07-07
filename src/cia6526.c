#include "cia6526.h"
#include <string.h>

#define CIA_ICR 0x0D
#define CIA_CRA 0x0E
#define CIA_CPU_HZ 27000000ULL
#define CIA_TIMER_HZ 1000000ULL

static void update_irq(CIA6526 *cia)
{
    cia->irq_active = (cia->regs[CIA_ICR] & 0x81) == 0x81;
    if (cia->irq_active) {
        cia->regs[CIA_ICR] |= 0x80;
    } else {
        cia->regs[CIA_ICR] &= 0x7F;
    }
}

void cia_init(CIA6526 *cia)
{
    memset(cia, 0, sizeof(*cia));
    cia->latch_a = 0xFFFF;
    cia->timer_a = 0xFFFF;
}

uint8_t cia_read(void *dev, uint16_t offset)
{
    CIA6526 *cia = (CIA6526 *)dev;
    offset &= 0x0F;
    switch (offset) {
    case 4: return (uint8_t)(cia->timer_a & 0xFF);
    case 5: return (uint8_t)(cia->timer_a >> 8);
    case CIA_ICR: {
        uint8_t v = cia->regs[CIA_ICR];
        cia->regs[CIA_ICR] &= 0x7E;
        update_irq(cia);
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
        cia->regs[offset] = val;
        break;
    case 5:
        cia->latch_a = (uint16_t)((cia->latch_a & 0x00FF) | ((uint16_t)val << 8));
        cia->timer_a = cia->latch_a;
        cia->regs[offset] = val;
        break;
    case CIA_ICR:
        if (val & 0x80) {
            cia->regs[CIA_ICR] |= val & 0x1F;
        } else {
            cia->regs[CIA_ICR] &= (uint8_t)~(val & 0x1F);
        }
        update_irq(cia);
        break;
    case CIA_CRA:
        cia->regs[offset] = val;
        cia->timer_a_running = (val & 0x01) != 0;
        if (val & 0x10) {
            cia->timer_a = cia->latch_a;
            cia->regs[offset] &= (uint8_t)~0x10;
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
    if (!cia->timer_a_running) {
        return;
    }

    cia->timer_accum += (uint64_t)cycles * CIA_TIMER_HZ;
    uint32_t ticks = (uint32_t)(cia->timer_accum / CIA_CPU_HZ);
    cia->timer_accum %= CIA_CPU_HZ;
    if (ticks == 0) {
        return;
    }

    if (cia->timer_a <= ticks) {
        cia->regs[CIA_ICR] |= 0x01;
        if (cia->regs[CIA_CRA] & 0x08) {
            cia->timer_a_running = false;
            cia->timer_a = 0;
        } else {
            cia->timer_a = cia->latch_a ? cia->latch_a : 0xFFFF;
        }
        update_irq(cia);
    } else {
        cia->timer_a = (uint16_t)(cia->timer_a - ticks);
    }
}

bool cia_irq(const CIA6526 *cia)
{
    return cia->irq_active;
}
