#pragma once
#include <stdint.h>
#include <stdbool.h>

/*
 * MOS 6522 VIA - Versatile Interface Adapter
 *
 * Register map (16 bytes, offset from base):
 *  $0  ORB / IRB  - Port B Output/Input Register
 *  $1  ORA / IRA  - Port A Output/Input Register
 *  $2  DDRB       - Data Direction Register B (1=output)
 *  $3  DDRA       - Data Direction Register A
 *  $4  T1CL       - Timer 1 Counter Low  (read clears T1 IRQ)
 *  $5  T1CH       - Timer 1 Counter High
 *  $6  T1LL       - Timer 1 Latch Low
 *  $7  T1LH       - Timer 1 Latch High
 *  $8  T2CL       - Timer 2 Counter Low  (read clears T2 IRQ)
 *  $9  T2CH       - Timer 2 Counter High
 *  $A  SR         - Shift Register
 *  $B  ACR        - Auxiliary Control Register
 *  $C  PCR        - Peripheral Control Register
 *  $D  IFR        - Interrupt Flag Register
 *  $E  IER        - Interrupt Enable Register
 *  $F  ORA (no handshake)
 *
 * IFR/IER bits: 7=ANY 6=T1 5=T2 4=CB1 3=CB2 2=SR 1=CA1 0=CA2
 */

#define VIA_ORB   0x0
#define VIA_ORA   0x1
#define VIA_DDRB  0x2
#define VIA_DDRA  0x3
#define VIA_T1CL  0x4
#define VIA_T1CH  0x5
#define VIA_T1LL  0x6
#define VIA_T1LH  0x7
#define VIA_T2CL  0x8
#define VIA_T2CH  0x9
#define VIA_SR    0xA
#define VIA_ACR   0xB
#define VIA_PCR   0xC
#define VIA_IFR   0xD
#define VIA_IER   0xE
#define VIA_ORA2  0xF

#define VIA_IRQ_CA2 (1 << 0)
#define VIA_IRQ_CA1 (1 << 1)
#define VIA_IRQ_SR  (1 << 2)
#define VIA_IRQ_CB2 (1 << 3)
#define VIA_IRQ_CB1 (1 << 4)
#define VIA_IRQ_T2  (1 << 5)
#define VIA_IRQ_T1  (1 << 6)
#define VIA_IRQ_ANY (1 << 7)

/* Keyboard buffer size */
#define VIA_KB_BUFFER_SIZE 128

typedef struct {
    uint8_t  orb, ora;         /* output registers */
    uint8_t  irb, ira;         /* input registers (driven externally) */
    uint8_t  ddrb, ddra;
    uint16_t t1_counter;
    uint16_t t1_latch;
    uint16_t t2_counter;
    uint8_t  t2_latch_lo;
    uint8_t  sr;
    uint8_t  acr;
    uint8_t  pcr;
    uint8_t  ifr;              /* interrupt flag register */
    uint8_t  ier;              /* interrupt enable register */
    bool     t1_running;
    bool     t2_running;
    bool     irq_active;       /* current /IRQ output state */
    
    /* Keyboard buffer (Port A used for keyboard input) */
    uint8_t  kb_buffer[VIA_KB_BUFFER_SIZE];
    uint8_t  kb_read_pos;
    uint8_t  kb_write_pos;
    uint8_t  kb_count;
} VIA6522;

void    via_init(VIA6522 *via);
uint8_t via_read(void *dev, uint16_t offset);
void    via_write(void *dev, uint16_t offset, uint8_t val);
void    via_tick(void *dev, uint32_t cycles);
bool    via_irq(const VIA6522 *via);

/* Inject external pin state */
void    via_set_porta_input(VIA6522 *via, uint8_t val);
void    via_set_portb_input(VIA6522 *via, uint8_t val);
uint8_t via_get_porta_output(const VIA6522 *via);
uint8_t via_get_portb_output(const VIA6522 *via);

/* Keyboard buffer functions (Port A) */
bool    via_keyboard_push(VIA6522 *via, uint8_t keycode);
bool    via_keyboard_available(const VIA6522 *via);
uint8_t via_keyboard_pop(VIA6522 *via);
void    via_keyboard_release_key(VIA6522 *via, uint8_t keycode);
