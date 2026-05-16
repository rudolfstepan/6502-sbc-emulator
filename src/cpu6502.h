#pragma once
#include <stdint.h>
#include <stdbool.h>

/* 6502 status flags */
#define FLAG_C  0x01   /* Carry */
#define FLAG_Z  0x02   /* Zero */
#define FLAG_I  0x04   /* IRQ disable */
#define FLAG_D  0x08   /* Decimal mode */
#define FLAG_B  0x10   /* Break */
#define FLAG_U  0x20   /* Unused (always 1) */
#define FLAG_V  0x40   /* Overflow */
#define FLAG_N  0x80   /* Negative */

/* Interrupt vectors */
#define VEC_NMI   0xFFFA
#define VEC_RESET 0xFFFC
#define VEC_IRQ   0xFFFE

typedef struct CPU6502 {
    uint8_t  A;           /* Accumulator */
    uint8_t  X;           /* Index X */
    uint8_t  Y;           /* Index Y */
    uint8_t  SP;          /* Stack pointer (page 1) */
    uint16_t PC;          /* Program counter */
    uint8_t  P;           /* Status register */

    uint64_t cycles;      /* Total cycles executed */

    bool     nmi_pending;
    bool     irq_pending;
    bool     reset_pending;
    bool     stopped;     /* STP / halt */

    /* Bus callbacks */
    uint8_t (*read) (void *ctx, uint16_t addr);
    void    (*write)(void *ctx, uint16_t addr, uint8_t val);
    void    *bus_ctx;
} CPU6502;

void cpu6502_init(CPU6502 *cpu,
                  uint8_t (*read)(void *, uint16_t),
                  void    (*write)(void *, uint16_t, uint8_t),
                  void    *ctx);
void cpu6502_reset(CPU6502 *cpu);
int  cpu6502_step(CPU6502 *cpu);   /* returns cycles consumed */
void cpu6502_nmi(CPU6502 *cpu);
void cpu6502_irq(CPU6502 *cpu);
void cpu6502_irq_clear(CPU6502 *cpu);
