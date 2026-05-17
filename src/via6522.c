#include "via6522.h"
#include <string.h>

void via_init(VIA6522 *via)
{
    memset(via, 0, sizeof(*via));
    via->kb_read_pos = 0;
    via->kb_write_pos = 0;
    via->kb_count = 0;
}

static void via_update_irq(VIA6522 *via)
{
    /* IFR bit 7 is set if any enabled interrupt flag is set */
    uint8_t active = via->ifr & via->ier & 0x7F;
    if (active)
        via->ifr |= VIA_IRQ_ANY;
    else
        via->ifr &= ~VIA_IRQ_ANY;
    via->irq_active = (via->ifr & VIA_IRQ_ANY) != 0;
}

uint8_t via_read(void *dev, uint16_t offset)
{
    VIA6522 *via = (VIA6522 *)dev;
    offset &= 0x0F;

    switch (offset) {
    case VIA_ORB:
        /* Read pins: output bits from ORB, input bits from IRB */
        via->ifr &= ~(VIA_IRQ_CB1 | VIA_IRQ_CB2);
        via_update_irq(via);
        return (via->orb & via->ddrb) | (via->irb & ~via->ddrb);

    case VIA_ORA:
    case VIA_ORA2:
        via->ifr &= ~(VIA_IRQ_CA1 | VIA_IRQ_CA2);
        via_update_irq(via);
        /* If Port A is configured as input, read from keyboard buffer */
        if (via->ddra == 0x00 && via->kb_count > 0) {
            uint8_t key = via_keyboard_pop(via);
            /* Re-assert CA1 if more keys remain in the buffer so that
             * the next CHRIN_NB poll still sees data-available. */
            if (via->kb_count > 0) {
                via->ifr |= VIA_IRQ_CA1;
                via_update_irq(via);
            }
            return key;
        }
        return (via->ora & via->ddra) | (via->ira & ~via->ddra);

    case VIA_DDRB: return via->ddrb;
    case VIA_DDRA: return via->ddra;

    case VIA_T1CL:
        via->ifr &= ~VIA_IRQ_T1;
        via_update_irq(via);
        return (uint8_t)(via->t1_counter & 0xFF);

    case VIA_T1CH: return (uint8_t)(via->t1_counter >> 8);
    case VIA_T1LL: return (uint8_t)(via->t1_latch & 0xFF);
    case VIA_T1LH: return (uint8_t)(via->t1_latch >> 8);

    case VIA_T2CL:
        via->ifr &= ~VIA_IRQ_T2;
        via_update_irq(via);
        return (uint8_t)(via->t2_counter & 0xFF);

    case VIA_T2CH: return (uint8_t)(via->t2_counter >> 8);
    case VIA_SR:   return via->sr;
    case VIA_ACR:  return via->acr;
    case VIA_PCR:  return via->pcr;

    case VIA_IFR:  return via->ifr;
    case VIA_IER:  return via->ier | 0x80; /* bit 7 always reads 1 */
    }
    return 0xFF;
}

void via_write(void *dev, uint16_t offset, uint8_t val)
{
    VIA6522 *via = (VIA6522 *)dev;
    offset &= 0x0F;

    switch (offset) {
    case VIA_ORB:
        via->orb = val;
        via->ifr &= ~(VIA_IRQ_CB1 | VIA_IRQ_CB2);
        via_update_irq(via);
        break;

    case VIA_ORA:
    case VIA_ORA2:
        via->ora = val;
        via->ifr &= ~(VIA_IRQ_CA1 | VIA_IRQ_CA2);
        via_update_irq(via);
        break;

    case VIA_DDRB: via->ddrb = val; break;
    case VIA_DDRA: via->ddra = val; break;

    case VIA_T1CL:
    case VIA_T1LL:
        via->t1_latch = (via->t1_latch & 0xFF00) | val;
        break;

    case VIA_T1LH:
        via->t1_latch = (via->t1_latch & 0x00FF) | ((uint16_t)val << 8);
        break;

    case VIA_T1CH:
        via->t1_latch   = (via->t1_latch & 0x00FF) | ((uint16_t)val << 8);
        via->t1_counter = via->t1_latch;
        via->t1_running = true;
        via->ifr &= ~VIA_IRQ_T1;
        via_update_irq(via);
        break;

    case VIA_T2CL:
        via->t2_latch_lo = val;
        break;

    case VIA_T2CH:
        via->t2_counter = ((uint16_t)val << 8) | via->t2_latch_lo;
        via->t2_running = true;
        via->ifr &= ~VIA_IRQ_T2;
        via_update_irq(via);
        break;

    case VIA_SR:  via->sr  = val; break;
    case VIA_ACR: via->acr = val; break;
    case VIA_PCR: via->pcr = val; break;

    case VIA_IFR:
        /* Writing clears specified flags */
        via->ifr &= ~(val & 0x7F);
        via_update_irq(via);
        break;

    case VIA_IER:
        /* Bit 7=1 sets bits, bit 7=0 clears bits */
        if (val & 0x80)
            via->ier |= (val & 0x7F);
        else
            via->ier &= ~(val & 0x7F);
        via_update_irq(via);
        break;
    }
}

void via_tick(void *dev, uint32_t cycles)
{
    VIA6522 *via = (VIA6522 *)dev;

    /* Timer 1 */
    if (via->t1_running) {
        if (via->t1_counter <= cycles) {
            via->ifr |= VIA_IRQ_T1;
            via_update_irq(via);
            if (via->acr & 0x40) {
                /* Free-running mode: reload from latch */
                via->t1_counter = via->t1_latch + (uint16_t)(cycles - via->t1_counter);
            } else {
                /* One-shot mode */
                via->t1_counter = 0;
                via->t1_running = false;
            }
        } else {
            via->t1_counter -= (uint16_t)cycles;
        }
    }

    /* Timer 2 (one-shot only in this implementation) */
    if (via->t2_running && !(via->acr & 0x20)) {
        if (via->t2_counter <= cycles) {
            via->ifr |= VIA_IRQ_T2;
            via_update_irq(via);
            via->t2_counter = 0;
            via->t2_running = false;
        } else {
            via->t2_counter -= (uint16_t)cycles;
        }
    }
}

bool via_irq(const VIA6522 *via)
{
    return via->irq_active;
}

void via_set_porta_input(VIA6522 *via, uint8_t val) { via->ira = val; }
void via_set_portb_input(VIA6522 *via, uint8_t val) { via->irb = val; }

uint8_t via_get_porta_output(const VIA6522 *via)
{
    return via->ora & via->ddra;
}

uint8_t via_get_portb_output(const VIA6522 *via)
{
    return via->orb & via->ddrb;
}

/* ── Keyboard buffer functions ────────────────────────── */

/* Push a key into the keyboard buffer and trigger CA1 interrupt */
bool via_keyboard_push(VIA6522 *via, uint8_t keycode)
{
    if (via->kb_count >= VIA_KB_BUFFER_SIZE) {
        return false;  /* Buffer full */
    }
    
    via->kb_buffer[via->kb_write_pos] = keycode;
    via->kb_write_pos = (via->kb_write_pos + 1) % VIA_KB_BUFFER_SIZE;
    via->kb_count++;
    
    /* Trigger CA1 interrupt (keyboard data available) */
    via->ifr |= VIA_IRQ_CA1;
    via_update_irq(via);
    
    return true;
}

/* Check if keyboard data is available */
bool via_keyboard_available(const VIA6522 *via)
{
    return via->kb_count > 0;
}

/* Pop a key from the keyboard buffer */
uint8_t via_keyboard_pop(VIA6522 *via)
{
    if (via->kb_count == 0) {
        return 0;  /* No data available */
    }
    
    uint8_t keycode = via->kb_buffer[via->kb_read_pos];
    via->kb_read_pos = (via->kb_read_pos + 1) % VIA_KB_BUFFER_SIZE;
    via->kb_count--;
    
    /* Clear CA1 interrupt if buffer is now empty */
    if (via->kb_count == 0) {
        via->ifr &= ~VIA_IRQ_CA1;
        via_update_irq(via);
    }
    
    return keycode;
}
