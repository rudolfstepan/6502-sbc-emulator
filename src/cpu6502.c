#include "cpu6502.h"
#include "disasm.h"
#include <stdio.h>
#include <string.h>

/* ── Bus helpers ──────────────────────────────────────────── */
#define RD(a)       cpu->read(cpu->bus_ctx, (uint16_t)(a))
#define WR(a,v)     cpu->write(cpu->bus_ctx, (uint16_t)(a), (uint8_t)(v))
#define FETCH()     RD(cpu->PC++)

/* Stack */
#define PUSH(v)     WR(0x0100u | cpu->SP--, (v))
#define POP()       RD(0x0100u | (uint8_t)(++cpu->SP))

/* Read 16-bit little-endian */
#define RD16(a)     ((uint16_t)(RD(a) | (RD((uint16_t)((a)+1)) << 8)))

/* 6502 indirect JMP bug: wrap within page */
static uint16_t rd16_wrap(CPU6502 *cpu, uint16_t a)
{
    uint8_t lo = RD(a);
    uint8_t hi = RD((uint16_t)((a & 0xFF00) | ((a + 1) & 0x00FF)));
    return (uint16_t)(lo | (hi << 8));
}

/* ── Flag helpers ─────────────────────────────────────────── */
#define SET_FLAG(f)   (cpu->P |=  (f))
#define CLR_FLAG(f)   (cpu->P &= ~(uint8_t)(f))
#define TST_FLAG(f)   (cpu->P &   (f))

static inline void set_nz(CPU6502 *cpu, uint8_t v)
{
    cpu->P = (uint8_t)((cpu->P & ~(FLAG_N | FLAG_Z))
             | (v & 0x80 ? FLAG_N : 0)
             | (v == 0   ? FLAG_Z : 0));
}

/* ── Addressing mode helpers ──────────────────────────────── */
static inline uint16_t addr_zp (CPU6502 *cpu)              { return FETCH(); }
static inline uint16_t addr_zpx(CPU6502 *cpu)              { return (uint8_t)(FETCH() + cpu->X); }
static inline uint16_t addr_zpy(CPU6502 *cpu)              { return (uint8_t)(FETCH() + cpu->Y); }
static inline uint16_t addr_abs(CPU6502 *cpu)              { uint16_t a = FETCH(); a |= (uint16_t)(FETCH() << 8); return a; }

static inline uint16_t addr_abx(CPU6502 *cpu, int *extra)
{
    uint16_t base = addr_abs(cpu);
    uint16_t eff  = base + cpu->X;
    if (extra && (base & 0xFF00) != (eff & 0xFF00)) (*extra)++;
    return eff;
}
static inline uint16_t addr_aby(CPU6502 *cpu, int *extra)
{
    uint16_t base = addr_abs(cpu);
    uint16_t eff  = base + cpu->Y;
    if (extra && (base & 0xFF00) != (eff & 0xFF00)) (*extra)++;
    return eff;
}
static inline uint16_t addr_izx(CPU6502 *cpu)
{
    uint8_t zp = (uint8_t)(FETCH() + cpu->X);
    return (uint16_t)(RD(zp) | (RD((uint8_t)(zp + 1)) << 8));
}
static inline uint16_t addr_izy(CPU6502 *cpu, int *extra)
{
    uint8_t zp   = FETCH();
    uint16_t base = (uint16_t)(RD(zp) | (RD((uint8_t)(zp + 1)) << 8));
    uint16_t eff  = base + cpu->Y;
    if (extra && (base & 0xFF00) != (eff & 0xFF00)) (*extra)++;
    return eff;
}

/* ── ADC / SBC ────────────────────────────────────────────── */
static void do_adc(CPU6502 *cpu, uint8_t m)
{
    if (cpu->P & FLAG_D) {
        /* BCD */
        uint8_t c   = TST_FLAG(FLAG_C) ? 1 : 0;
        uint16_t lo = (cpu->A & 0x0F) + (m & 0x0F) + c;
        if (lo > 9) lo += 6;
        uint16_t hi = (cpu->A >> 4) + (m >> 4) + (lo > 15 ? 1 : 0);
        uint8_t  bres = (uint8_t)((cpu->A + m + c) & 0xFF);
        set_nz(cpu, bres);
        if (~(cpu->A ^ m) & (bres ^ cpu->A) & 0x80) SET_FLAG(FLAG_V); else CLR_FLAG(FLAG_V);
        if (hi > 9) hi += 6;
        cpu->A = (uint8_t)((hi << 4) | (lo & 0x0F));
        if (hi > 15) SET_FLAG(FLAG_C); else CLR_FLAG(FLAG_C);
        /* 65C02: set N/Z from decimal result */
        if (cpu->mode == 1)
            set_nz(cpu, cpu->A);
    } else {
        uint16_t res = cpu->A + m + (TST_FLAG(FLAG_C) ? 1 : 0);
        if (~(cpu->A ^ m) & (res ^ cpu->A) & 0x80) SET_FLAG(FLAG_V); else CLR_FLAG(FLAG_V);
        if (res > 0xFF) SET_FLAG(FLAG_C); else CLR_FLAG(FLAG_C);
        cpu->A = (uint8_t)res;
        set_nz(cpu, cpu->A);
    }
}

static void do_sbc(CPU6502 *cpu, uint8_t m)
{
    uint8_t a = cpu->A;
    uint8_t c = TST_FLAG(FLAG_C) ? 1u : 0u;
    uint16_t diff = (uint16_t)a - (uint16_t)m - (uint16_t)(1u - c);
    uint8_t bres = (uint8_t)diff;

    /* Overflow and NZ follow the binary subtraction result. */
    if (((a ^ bres) & (a ^ m) & 0x80) != 0) SET_FLAG(FLAG_V); else CLR_FLAG(FLAG_V);
    set_nz(cpu, bres);
    if (diff < 0x100) SET_FLAG(FLAG_C); else CLR_FLAG(FLAG_C); /* no borrow */

    if (cpu->P & FLAG_D) {
        int16_t lo = (int16_t)(a & 0x0F) - (int16_t)(m & 0x0F) - (int16_t)(1u - c);
        int16_t hi = (int16_t)(a >> 4) - (int16_t)(m >> 4);

        if (lo < 0) {
            lo -= 6;
            hi -= 1;
        }
        if (hi < 0) {
            hi -= 6;
        }

        cpu->A = (uint8_t)(((uint8_t)hi << 4) | ((uint8_t)lo & 0x0F));
        /* 65C02: set N/Z from decimal result */
        if (cpu->mode == 1)
            set_nz(cpu, cpu->A);
    } else {
        cpu->A = bres;
    }
}

/* ── CMP / CPX / CPY ─────────────────────────────────────── */
static void do_cmp(CPU6502 *cpu, uint8_t reg, uint8_t m)
{
    uint16_t res = (uint16_t)reg - m;
    set_nz(cpu, (uint8_t)res);
    if (reg >= m) SET_FLAG(FLAG_C); else CLR_FLAG(FLAG_C);
}

/* ── ASL / LSR / ROL / ROR ───────────────────────────────── */
static uint8_t do_asl(CPU6502 *cpu, uint8_t v)
{
    if (v & 0x80) SET_FLAG(FLAG_C); else CLR_FLAG(FLAG_C);
    uint8_t r = (uint8_t)(v << 1);
    set_nz(cpu, r);
    return r;
}
static uint8_t do_lsr(CPU6502 *cpu, uint8_t v)
{
    if (v & 0x01) SET_FLAG(FLAG_C); else CLR_FLAG(FLAG_C);
    uint8_t r = (uint8_t)(v >> 1);
    set_nz(cpu, r);
    return r;
}
static uint8_t do_rol(CPU6502 *cpu, uint8_t v)
{
    uint8_t c = TST_FLAG(FLAG_C) ? 1 : 0;
    if (v & 0x80) SET_FLAG(FLAG_C); else CLR_FLAG(FLAG_C);
    uint8_t r = (uint8_t)((v << 1) | c);
    set_nz(cpu, r);
    return r;
}
static uint8_t do_ror(CPU6502 *cpu, uint8_t v)
{
    uint8_t c = TST_FLAG(FLAG_C) ? 0x80 : 0;
    if (v & 0x01) SET_FLAG(FLAG_C); else CLR_FLAG(FLAG_C);
    uint8_t r = (uint8_t)((v >> 1) | c);
    set_nz(cpu, r);
    return r;
}

/* ── BIT ────────────────────────────────────────────────── */
static void do_bit(CPU6502 *cpu, uint8_t m)
{
    cpu->P = (uint8_t)((cpu->P & ~(FLAG_N | FLAG_V | FLAG_Z))
             | (m & 0xC0)
             | ((cpu->A & m) == 0 ? FLAG_Z : 0));
}

/* ── Interrupt / Reset ─────────────────────────────────────── */
static int do_reset(CPU6502 *cpu)
{
    cpu->PC = RD16(VEC_RESET);
    cpu->SP = 0xFD;
    cpu->P  = FLAG_I | FLAG_U;
    cpu->A = cpu->X = cpu->Y = 0;
    cpu->reset_pending = false;
    return 7;
}
static int do_nmi(CPU6502 *cpu)
{
    PUSH((cpu->PC >> 8) & 0xFF);
    PUSH(cpu->PC & 0xFF);
    PUSH((cpu->P | FLAG_U) & ~FLAG_B);
    SET_FLAG(FLAG_I);
    cpu->PC = RD16(VEC_NMI);
    cpu->nmi_pending = false;
    return 7;
}
static int do_irq(CPU6502 *cpu)
{
    PUSH((cpu->PC >> 8) & 0xFF);
    PUSH(cpu->PC & 0xFF);
    PUSH((cpu->P | FLAG_U) & ~FLAG_B);
    SET_FLAG(FLAG_I);
    cpu->PC = RD16(VEC_IRQ);
    return 7;
}

/* ── Branch helper ─────────────────────────────────────────── */
static int do_branch(CPU6502 *cpu, bool taken)
{
    int8_t  offset = (int8_t)FETCH();
    if (!taken) return 2;
    uint16_t old_pc = cpu->PC;
    cpu->PC = (uint16_t)(cpu->PC + offset);
    /* +1 if taken, +1 more if page crossed */
    return 3 + ((old_pc & 0xFF00) != (cpu->PC & 0xFF00) ? 1 : 0);
}

/* ═══════════════════════════════════════════════════════════
 * cpu6502_step  –  execute one instruction, return cycle count
 * ═══════════════════════════════════════════════════════════ */
int cpu6502_step(CPU6502 *cpu)
{
    /* WAI wakes up on interrupt; STP stays stopped */
    if (cpu->stopped && (cpu->nmi_pending || cpu->irq_pending || cpu->reset_pending))
        cpu->stopped = false;

    if (cpu->stopped) return 1;

    if (cpu->reset_pending)  { int c = do_reset(cpu); cpu->cycles += (uint64_t)c; return c; }
    if (cpu->nmi_pending)    { int c = do_nmi(cpu);   cpu->cycles += (uint64_t)c; return c; }
    if (cpu->irq_pending && !TST_FLAG(FLAG_I))
                             { int c = do_irq(cpu);   cpu->cycles += (uint64_t)c; return c; }

    int      extra = 0;  /* extra cycle for page cross */
    uint16_t ea;
    uint8_t  m;
    int      cycles;
    uint8_t  op = FETCH();

    /* Tracing: log instruction before execution */
    if (cpu->trace_enabled) {
        char buf[64];
        disasm((uint16_t)(cpu->PC - 1), cpu->read, cpu->bus_ctx, buf, sizeof(buf));
        FILE *f = cpu->trace_fp ? (FILE*)cpu->trace_fp : stderr;
        fprintf(f, "%04X  %-20s  A:%02X X:%02X Y:%02X SP:%02X P:%02X CYC:%llu\n",
                (uint16_t)(cpu->PC - 1), buf, cpu->A, cpu->X, cpu->Y, cpu->SP, cpu->P,
                (unsigned long long)cpu->cycles);
    }

    switch (op) {

    /* ── BRK ─────────────────────────────────────────── */
    case 0x00:
        cpu->PC++;  /* skip padding byte */
        PUSH((cpu->PC >> 8) & 0xFF);
        PUSH(cpu->PC & 0xFF);
        PUSH(cpu->P | FLAG_B | FLAG_U);
        SET_FLAG(FLAG_I);
        cpu->PC = RD16(VEC_IRQ);
        cycles = 7; break;

    /* ── NOP ─────────────────────────────────────────── */
    case 0xEA: cycles = 2; break;

    /* ── LDA ─────────────────────────────────────────── */
    case 0xA9: cpu->A = FETCH();              set_nz(cpu,cpu->A); cycles=2; break;
    case 0xA5: cpu->A = RD(addr_zp(cpu));    set_nz(cpu,cpu->A); cycles=3; break;
    case 0xB5: cpu->A = RD(addr_zpx(cpu));   set_nz(cpu,cpu->A); cycles=4; break;
    case 0xAD: cpu->A = RD(addr_abs(cpu));   set_nz(cpu,cpu->A); cycles=4; break;
    case 0xBD: cpu->A = RD(addr_abx(cpu,&extra)); set_nz(cpu,cpu->A); cycles=4+extra; break;
    case 0xB9: cpu->A = RD(addr_aby(cpu,&extra)); set_nz(cpu,cpu->A); cycles=4+extra; break;
    case 0xA1: cpu->A = RD(addr_izx(cpu));   set_nz(cpu,cpu->A); cycles=6; break;
    case 0xB1: cpu->A = RD(addr_izy(cpu,&extra)); set_nz(cpu,cpu->A); cycles=5+extra; break;

    /* ── LDX ─────────────────────────────────────────── */
    case 0xA2: cpu->X = FETCH();              set_nz(cpu,cpu->X); cycles=2; break;
    case 0xA6: cpu->X = RD(addr_zp(cpu));    set_nz(cpu,cpu->X); cycles=3; break;
    case 0xB6: cpu->X = RD(addr_zpy(cpu));   set_nz(cpu,cpu->X); cycles=4; break;
    case 0xAE: cpu->X = RD(addr_abs(cpu));   set_nz(cpu,cpu->X); cycles=4; break;
    case 0xBE: cpu->X = RD(addr_aby(cpu,&extra)); set_nz(cpu,cpu->X); cycles=4+extra; break;

    /* ── LDY ─────────────────────────────────────────── */
    case 0xA0: cpu->Y = FETCH();              set_nz(cpu,cpu->Y); cycles=2; break;
    case 0xA4: cpu->Y = RD(addr_zp(cpu));    set_nz(cpu,cpu->Y); cycles=3; break;
    case 0xB4: cpu->Y = RD(addr_zpx(cpu));   set_nz(cpu,cpu->Y); cycles=4; break;
    case 0xAC: cpu->Y = RD(addr_abs(cpu));   set_nz(cpu,cpu->Y); cycles=4; break;
    case 0xBC: cpu->Y = RD(addr_abx(cpu,&extra)); set_nz(cpu,cpu->Y); cycles=4+extra; break;

    /* ── STA ─────────────────────────────────────────── */
    case 0x85: WR(addr_zp(cpu),  cpu->A); cycles=3; break;
    case 0x95: WR(addr_zpx(cpu), cpu->A); cycles=4; break;
    case 0x8D: WR(addr_abs(cpu), cpu->A); cycles=4; break;
    case 0x9D: WR(addr_abx(cpu,NULL), cpu->A); cycles=5; break;
    case 0x99: WR(addr_aby(cpu,NULL), cpu->A); cycles=5; break;
    case 0x81: WR(addr_izx(cpu), cpu->A); cycles=6; break;
    case 0x91: WR(addr_izy(cpu,NULL), cpu->A); cycles=6; break;

    /* ── STX ─────────────────────────────────────────── */
    case 0x86: WR(addr_zp(cpu),  cpu->X); cycles=3; break;
    case 0x96: WR(addr_zpy(cpu), cpu->X); cycles=4; break;
    case 0x8E: WR(addr_abs(cpu), cpu->X); cycles=4; break;

    /* ── STY ─────────────────────────────────────────── */
    case 0x84: WR(addr_zp(cpu),  cpu->Y); cycles=3; break;
    case 0x94: WR(addr_zpx(cpu), cpu->Y); cycles=4; break;
    case 0x8C: WR(addr_abs(cpu), cpu->Y); cycles=4; break;

    /* ── Transfers ───────────────────────────────────── */
    case 0xAA: cpu->X = cpu->A; set_nz(cpu,cpu->X); cycles=2; break;
    case 0xA8: cpu->Y = cpu->A; set_nz(cpu,cpu->Y); cycles=2; break;
    case 0x8A: cpu->A = cpu->X; set_nz(cpu,cpu->A); cycles=2; break;
    case 0x98: cpu->A = cpu->Y; set_nz(cpu,cpu->A); cycles=2; break;
    case 0x9A: cpu->SP = cpu->X;                     cycles=2; break;
    case 0xBA: cpu->X = cpu->SP; set_nz(cpu,cpu->X); cycles=2; break;

    /* ── Stack ───────────────────────────────────────── */
    case 0x48: PUSH(cpu->A);                                      cycles=3; break;
    case 0x08: PUSH(cpu->P | FLAG_B | FLAG_U);                    cycles=3; break;
    case 0x68: cpu->A = POP(); set_nz(cpu,cpu->A);                cycles=4; break;
    case 0x28: cpu->P = (POP() | FLAG_U) & ~FLAG_B;               cycles=4; break;

    /* ── ADC ─────────────────────────────────────────── */
    case 0x69: do_adc(cpu, FETCH());                  cycles=2; break;
    case 0x65: do_adc(cpu, RD(addr_zp(cpu)));         cycles=3; break;
    case 0x75: do_adc(cpu, RD(addr_zpx(cpu)));        cycles=4; break;
    case 0x6D: do_adc(cpu, RD(addr_abs(cpu)));        cycles=4; break;
    case 0x7D: do_adc(cpu, RD(addr_abx(cpu,&extra))); cycles=4+extra; break;
    case 0x79: do_adc(cpu, RD(addr_aby(cpu,&extra))); cycles=4+extra; break;
    case 0x61: do_adc(cpu, RD(addr_izx(cpu)));        cycles=6; break;
    case 0x71: do_adc(cpu, RD(addr_izy(cpu,&extra))); cycles=5+extra; break;

    /* ── SBC ─────────────────────────────────────────── */
    case 0xE9: do_sbc(cpu, FETCH());                  cycles=2; break;
    case 0xE5: do_sbc(cpu, RD(addr_zp(cpu)));         cycles=3; break;
    case 0xF5: do_sbc(cpu, RD(addr_zpx(cpu)));        cycles=4; break;
    case 0xED: do_sbc(cpu, RD(addr_abs(cpu)));        cycles=4; break;
    case 0xFD: do_sbc(cpu, RD(addr_abx(cpu,&extra))); cycles=4+extra; break;
    case 0xF9: do_sbc(cpu, RD(addr_aby(cpu,&extra))); cycles=4+extra; break;
    case 0xE1: do_sbc(cpu, RD(addr_izx(cpu)));        cycles=6; break;
    case 0xF1: do_sbc(cpu, RD(addr_izy(cpu,&extra))); cycles=5+extra; break;

    /* ── AND ─────────────────────────────────────────── */
    case 0x29: cpu->A &= FETCH();                  set_nz(cpu,cpu->A); cycles=2; break;
    case 0x25: cpu->A &= RD(addr_zp(cpu));         set_nz(cpu,cpu->A); cycles=3; break;
    case 0x35: cpu->A &= RD(addr_zpx(cpu));        set_nz(cpu,cpu->A); cycles=4; break;
    case 0x2D: cpu->A &= RD(addr_abs(cpu));        set_nz(cpu,cpu->A); cycles=4; break;
    case 0x3D: cpu->A &= RD(addr_abx(cpu,&extra)); set_nz(cpu,cpu->A); cycles=4+extra; break;
    case 0x39: cpu->A &= RD(addr_aby(cpu,&extra)); set_nz(cpu,cpu->A); cycles=4+extra; break;
    case 0x21: cpu->A &= RD(addr_izx(cpu));        set_nz(cpu,cpu->A); cycles=6; break;
    case 0x31: cpu->A &= RD(addr_izy(cpu,&extra)); set_nz(cpu,cpu->A); cycles=5+extra; break;

    /* ── ORA ─────────────────────────────────────────── */
    case 0x09: cpu->A |= FETCH();                  set_nz(cpu,cpu->A); cycles=2; break;
    case 0x05: cpu->A |= RD(addr_zp(cpu));         set_nz(cpu,cpu->A); cycles=3; break;
    case 0x15: cpu->A |= RD(addr_zpx(cpu));        set_nz(cpu,cpu->A); cycles=4; break;
    case 0x0D: cpu->A |= RD(addr_abs(cpu));        set_nz(cpu,cpu->A); cycles=4; break;
    case 0x1D: cpu->A |= RD(addr_abx(cpu,&extra)); set_nz(cpu,cpu->A); cycles=4+extra; break;
    case 0x19: cpu->A |= RD(addr_aby(cpu,&extra)); set_nz(cpu,cpu->A); cycles=4+extra; break;
    case 0x01: cpu->A |= RD(addr_izx(cpu));        set_nz(cpu,cpu->A); cycles=6; break;
    case 0x11: cpu->A |= RD(addr_izy(cpu,&extra)); set_nz(cpu,cpu->A); cycles=5+extra; break;

    /* ── EOR ─────────────────────────────────────────── */
    case 0x49: cpu->A ^= FETCH();                  set_nz(cpu,cpu->A); cycles=2; break;
    case 0x45: cpu->A ^= RD(addr_zp(cpu));         set_nz(cpu,cpu->A); cycles=3; break;
    case 0x55: cpu->A ^= RD(addr_zpx(cpu));        set_nz(cpu,cpu->A); cycles=4; break;
    case 0x4D: cpu->A ^= RD(addr_abs(cpu));        set_nz(cpu,cpu->A); cycles=4; break;
    case 0x5D: cpu->A ^= RD(addr_abx(cpu,&extra)); set_nz(cpu,cpu->A); cycles=4+extra; break;
    case 0x59: cpu->A ^= RD(addr_aby(cpu,&extra)); set_nz(cpu,cpu->A); cycles=4+extra; break;
    case 0x41: cpu->A ^= RD(addr_izx(cpu));        set_nz(cpu,cpu->A); cycles=6; break;
    case 0x51: cpu->A ^= RD(addr_izy(cpu,&extra)); set_nz(cpu,cpu->A); cycles=5+extra; break;

    /* ── BIT ─────────────────────────────────────────── */
    case 0x24: do_bit(cpu, RD(addr_zp(cpu)));  cycles=3; break;
    case 0x2C: do_bit(cpu, RD(addr_abs(cpu))); cycles=4; break;

    /* ── CMP ─────────────────────────────────────────── */
    case 0xC9: do_cmp(cpu,cpu->A, FETCH());                  cycles=2; break;
    case 0xC5: do_cmp(cpu,cpu->A, RD(addr_zp(cpu)));         cycles=3; break;
    case 0xD5: do_cmp(cpu,cpu->A, RD(addr_zpx(cpu)));        cycles=4; break;
    case 0xCD: do_cmp(cpu,cpu->A, RD(addr_abs(cpu)));        cycles=4; break;
    case 0xDD: do_cmp(cpu,cpu->A, RD(addr_abx(cpu,&extra))); cycles=4+extra; break;
    case 0xD9: do_cmp(cpu,cpu->A, RD(addr_aby(cpu,&extra))); cycles=4+extra; break;
    case 0xC1: do_cmp(cpu,cpu->A, RD(addr_izx(cpu)));        cycles=6; break;
    case 0xD1: do_cmp(cpu,cpu->A, RD(addr_izy(cpu,&extra))); cycles=5+extra; break;

    /* ── CPX ─────────────────────────────────────────── */
    case 0xE0: do_cmp(cpu,cpu->X, FETCH());           cycles=2; break;
    case 0xE4: do_cmp(cpu,cpu->X, RD(addr_zp(cpu)));  cycles=3; break;
    case 0xEC: do_cmp(cpu,cpu->X, RD(addr_abs(cpu))); cycles=4; break;

    /* ── CPY ─────────────────────────────────────────── */
    case 0xC0: do_cmp(cpu,cpu->Y, FETCH());           cycles=2; break;
    case 0xC4: do_cmp(cpu,cpu->Y, RD(addr_zp(cpu)));  cycles=3; break;
    case 0xCC: do_cmp(cpu,cpu->Y, RD(addr_abs(cpu))); cycles=4; break;

    /* ── INC ─────────────────────────────────────────── */
    case 0xE6: ea=addr_zp(cpu);      m=RD(ea)+1; WR(ea,m); set_nz(cpu,m); cycles=5; break;
    case 0xF6: ea=addr_zpx(cpu);     m=RD(ea)+1; WR(ea,m); set_nz(cpu,m); cycles=6; break;
    case 0xEE: ea=addr_abs(cpu);     m=RD(ea)+1; WR(ea,m); set_nz(cpu,m); cycles=6; break;
    case 0xFE: ea=addr_abx(cpu,NULL);m=RD(ea)+1; WR(ea,m); set_nz(cpu,m); cycles=7; break;

    /* ── DEC ─────────────────────────────────────────── */
    case 0xC6: ea=addr_zp(cpu);      m=RD(ea)-1; WR(ea,m); set_nz(cpu,m); cycles=5; break;
    case 0xD6: ea=addr_zpx(cpu);     m=RD(ea)-1; WR(ea,m); set_nz(cpu,m); cycles=6; break;
    case 0xCE: ea=addr_abs(cpu);     m=RD(ea)-1; WR(ea,m); set_nz(cpu,m); cycles=6; break;
    case 0xDE: ea=addr_abx(cpu,NULL);m=RD(ea)-1; WR(ea,m); set_nz(cpu,m); cycles=7; break;

    /* ── INX / INY / DEX / DEY ───────────────────────── */
    case 0xE8: cpu->X++; set_nz(cpu,cpu->X); cycles=2; break;
    case 0xC8: cpu->Y++; set_nz(cpu,cpu->Y); cycles=2; break;
    case 0xCA: cpu->X--; set_nz(cpu,cpu->X); cycles=2; break;
    case 0x88: cpu->Y--; set_nz(cpu,cpu->Y); cycles=2; break;

    /* ── ASL ─────────────────────────────────────────── */
    case 0x0A: cpu->A = do_asl(cpu,cpu->A); cycles=2; break;
    case 0x06: ea=addr_zp(cpu);      WR(ea,do_asl(cpu,RD(ea))); cycles=5; break;
    case 0x16: ea=addr_zpx(cpu);     WR(ea,do_asl(cpu,RD(ea))); cycles=6; break;
    case 0x0E: ea=addr_abs(cpu);     WR(ea,do_asl(cpu,RD(ea))); cycles=6; break;
    case 0x1E: ea=addr_abx(cpu,NULL);WR(ea,do_asl(cpu,RD(ea))); cycles=7; break;

    /* ── LSR ─────────────────────────────────────────── */
    case 0x4A: cpu->A = do_lsr(cpu,cpu->A); cycles=2; break;
    case 0x46: ea=addr_zp(cpu);      WR(ea,do_lsr(cpu,RD(ea))); cycles=5; break;
    case 0x56: ea=addr_zpx(cpu);     WR(ea,do_lsr(cpu,RD(ea))); cycles=6; break;
    case 0x4E: ea=addr_abs(cpu);     WR(ea,do_lsr(cpu,RD(ea))); cycles=6; break;
    case 0x5E: ea=addr_abx(cpu,NULL);WR(ea,do_lsr(cpu,RD(ea))); cycles=7; break;

    /* ── ROL ─────────────────────────────────────────── */
    case 0x2A: cpu->A = do_rol(cpu,cpu->A); cycles=2; break;
    case 0x26: ea=addr_zp(cpu);      WR(ea,do_rol(cpu,RD(ea))); cycles=5; break;
    case 0x36: ea=addr_zpx(cpu);     WR(ea,do_rol(cpu,RD(ea))); cycles=6; break;
    case 0x2E: ea=addr_abs(cpu);     WR(ea,do_rol(cpu,RD(ea))); cycles=6; break;
    case 0x3E: ea=addr_abx(cpu,NULL);WR(ea,do_rol(cpu,RD(ea))); cycles=7; break;

    /* ── ROR ─────────────────────────────────────────── */
    case 0x6A: cpu->A = do_ror(cpu,cpu->A); cycles=2; break;
    case 0x66: ea=addr_zp(cpu);      WR(ea,do_ror(cpu,RD(ea))); cycles=5; break;
    case 0x76: ea=addr_zpx(cpu);     WR(ea,do_ror(cpu,RD(ea))); cycles=6; break;
    case 0x6E: ea=addr_abs(cpu);     WR(ea,do_ror(cpu,RD(ea))); cycles=6; break;
    case 0x7E: ea=addr_abx(cpu,NULL);WR(ea,do_ror(cpu,RD(ea))); cycles=7; break;

    /* ── JMP ─────────────────────────────────────────── */
    case 0x4C: cpu->PC = addr_abs(cpu); cycles=3; break;
    case 0x6C:
        ea = addr_abs(cpu);
        cpu->PC = rd16_wrap(cpu, ea);
        cycles=5; break;

    /* ── JSR ─────────────────────────────────────────── */
    case 0x20:
        ea = addr_abs(cpu);
        PUSH(((cpu->PC - 1) >> 8) & 0xFF);
        PUSH((cpu->PC - 1) & 0xFF);
        cpu->PC = ea;
        cycles=6; break;

    /* ── RTS ─────────────────────────────────────────── */
    case 0x60: {
        uint8_t lo = POP(), hi = POP();
        cpu->PC = (uint16_t)((uint16_t)(lo | (hi << 8)) + 1);
        cycles=6; break;
    }

    /* ── RTI ─────────────────────────────────────────── */
    case 0x40: {
        cpu->P  = (POP() | FLAG_U) & ~FLAG_B;
        uint8_t lo = POP(), hi = POP();
        cpu->PC = (uint16_t)(lo | (hi << 8));
        cycles=6; break;
    }

    /* ── Branches ────────────────────────────────────── */
    case 0x10: cycles = do_branch(cpu, !TST_FLAG(FLAG_N)); break; /* BPL */
    case 0x30: cycles = do_branch(cpu,  TST_FLAG(FLAG_N)); break; /* BMI */
    case 0x50: cycles = do_branch(cpu, !TST_FLAG(FLAG_V)); break; /* BVC */
    case 0x70: cycles = do_branch(cpu,  TST_FLAG(FLAG_V)); break; /* BVS */
    case 0x90: cycles = do_branch(cpu, !TST_FLAG(FLAG_C)); break; /* BCC */
    case 0xB0: cycles = do_branch(cpu,  TST_FLAG(FLAG_C)); break; /* BCS */
    case 0xD0: cycles = do_branch(cpu, !TST_FLAG(FLAG_Z)); break; /* BNE */
    case 0xF0: cycles = do_branch(cpu,  TST_FLAG(FLAG_Z)); break; /* BEQ */

    /* ── Flag instructions ───────────────────────────── */
    case 0x18: CLR_FLAG(FLAG_C); cycles=2; break;
    case 0x38: SET_FLAG(FLAG_C); cycles=2; break;
    case 0x58: CLR_FLAG(FLAG_I); cycles=2; break;
    case 0x78: SET_FLAG(FLAG_I); cycles=2; break;
    case 0xB8: CLR_FLAG(FLAG_V); cycles=2; break;
    case 0xD8: CLR_FLAG(FLAG_D); cycles=2; break;
    case 0xF8: SET_FLAG(FLAG_D); cycles=2; break;

    /* ── 65C02 CMOS extensions ──────────────────────── */
    /* BRA: Branch Always (available in 65C02) */
    case 0x80: cycles = do_branch(cpu, true); break;

    /* BIT immediate ($89) - 65C02: only affects Z flag */
    case 0x89:
        if (cpu->mode == 1) {
            m = FETCH();
            CLR_FLAG(FLAG_Z);
            if ((cpu->A & m) == 0) SET_FLAG(FLAG_Z);
            cycles = 2;
        } else {
            fprintf(stderr, "CPU: $89 BIT #imm is 65C02 only\n");
            cycles = 2;
        }
        break;

    /* TSB: Test and Set Bits */
    case 0x04:  /* TSB zp */
        if (cpu->mode == 1) {
            ea = addr_zp(cpu);
            m = RD(ea);
            CLR_FLAG(FLAG_Z);
            if ((cpu->A & m) == 0) SET_FLAG(FLAG_Z);
            WR(ea, (uint8_t)(m | cpu->A));
            cycles = 5;
        } else {
            fprintf(stderr, "CPU: $04 TSB zp is 65C02 only\n");
            cycles = 3;
        }
        break;
    case 0x0C:  /* TSB abs */
        if (cpu->mode == 1) {
            ea = addr_abs(cpu);
            m = RD(ea);
            CLR_FLAG(FLAG_Z);
            if ((cpu->A & m) == 0) SET_FLAG(FLAG_Z);
            WR(ea, (uint8_t)(m | cpu->A));
            cycles = 6;
        } else {
            fprintf(stderr, "CPU: $0C TSB abs is 65C02 only\n");
            cycles = 4;
        }
        break;

    /* TRB: Test and Reset Bits */
    case 0x14:  /* TRB zp */
        if (cpu->mode == 1) {
            ea = addr_zp(cpu);
            m = RD(ea);
            CLR_FLAG(FLAG_Z);
            if ((cpu->A & m) == 0) SET_FLAG(FLAG_Z);
            WR(ea, (uint8_t)(m & ~cpu->A));
            cycles = 5;
        } else {
            fprintf(stderr, "CPU: $14 TRB zp is 65C02 only\n");
            cycles = 3;
        }
        break;
    case 0x1C:  /* TRB abs */
        if (cpu->mode == 1) {
            ea = addr_abs(cpu);
            m = RD(ea);
            CLR_FLAG(FLAG_Z);
            if ((cpu->A & m) == 0) SET_FLAG(FLAG_Z);
            WR(ea, (uint8_t)(m & ~cpu->A));
            cycles = 6;
        } else {
            fprintf(stderr, "CPU: $1C TRB abs is 65C02 only\n");
            cycles = 4;
        }
        break;

    /* INC A: Increment Accumulator (65C02) */
    case 0x1A:
        if (cpu->mode == 1) {
            cpu->A++;
            set_nz(cpu, cpu->A);
            cycles = 2;
        } else {
            fprintf(stderr, "CPU: $1A INC A is 65C02 only\n");
            cycles = 2;
        }
        break;

    /* BIT zp,X: Extended BIT with indexed addressing (65C02) */
    case 0x34:
        if (cpu->mode == 1) {
            do_bit(cpu, RD(addr_zpx(cpu)));
            cycles = 4;
        } else {
            fprintf(stderr, "CPU: $34 BIT zp,X is 65C02 only\n");
            cycles = 3;
        }
        break;

    /* DEC A: Decrement Accumulator (65C02) */
    case 0x3A:
        if (cpu->mode == 1) {
            cpu->A--;
            set_nz(cpu, cpu->A);
            cycles = 2;
        } else {
            fprintf(stderr, "CPU: $3A DEC A is 65C02 only\n");
            cycles = 2;
        }
        break;

    /* BIT abs,X: Extended BIT with indexed absolute (65C02) */
    case 0x3C:
        if (cpu->mode == 1) {
            do_bit(cpu, RD(addr_abx(cpu, &extra)));
            cycles = 4 + extra;
        } else {
            fprintf(stderr, "CPU: $3C BIT abs,X is 65C02 only\n");
            cycles = 4;
        }
        break;

    /* STZ: Store Zero */
    case 0x64:  /* STZ zp */
        if (cpu->mode == 1) {
            WR(addr_zp(cpu), 0);
            cycles = 3;
        } else {
            fprintf(stderr, "CPU: $64 STZ zp is 65C02 only\n");
            cycles = 3;
        }
        break;
    case 0x74:  /* STZ zp,X */
        if (cpu->mode == 1) {
            WR(addr_zpx(cpu), 0);
            cycles = 4;
        } else {
            fprintf(stderr, "CPU: $74 STZ zp,X is 65C02 only\n");
            cycles = 4;
        }
        break;
    case 0x9C:  /* STZ abs */
        if (cpu->mode == 1) {
            WR(addr_abs(cpu), 0);
            cycles = 4;
        } else {
            fprintf(stderr, "CPU: $9C STZ abs is 65C02 only\n");
            cycles = 4;
        }
        break;
    case 0x9E:  /* STZ abs,X */
        if (cpu->mode == 1) {
            WR(addr_abx(cpu, NULL), 0);
            cycles = 5;
        } else {
            fprintf(stderr, "CPU: $9E STZ abs,X is 65C02 only\n");
            cycles = 5;
        }
        break;

    /* Push X/Y and Pull X/Y (65C02) */
    case 0x5A:  /* PHY */
        if (cpu->mode == 1) {
            PUSH(cpu->Y);
            cycles = 3;
        } else {
            fprintf(stderr, "CPU: $5A PHY is 65C02 only\n");
            cycles = 2;
        }
        break;
    case 0x7A:  /* PLY */
        if (cpu->mode == 1) {
            cpu->Y = POP();
            set_nz(cpu, cpu->Y);
            cycles = 4;
        } else {
            fprintf(stderr, "CPU: $7A PLY is 65C02 only\n");
            cycles = 2;
        }
        break;
    case 0xDA:  /* PHX */
        if (cpu->mode == 1) {
            PUSH(cpu->X);
            cycles = 3;
        } else {
            fprintf(stderr, "CPU: $DA PHX is 65C02 only\n");
            cycles = 2;
        }
        break;
    case 0xFA:  /* PLX */
        if (cpu->mode == 1) {
            cpu->X = POP();
            set_nz(cpu, cpu->X);
            cycles = 4;
        } else {
            fprintf(stderr, "CPU: $FA PLX is 65C02 only\n");
            cycles = 2;
        }
        break;

    /* WAI: Wait for Interrupt (65C02) */
    case 0xCB:
        if (cpu->mode == 1) {
            cpu->stopped = true;
            cycles = 3;
        } else {
            fprintf(stderr, "CPU: $CB WAI is 65C02 only\n");
            cycles = 2;
        }
        break;

    /* STP: Stop (65C02) */
    case 0xDB:
        if (cpu->mode == 1) {
            cpu->stopped = true;
            cycles = 3;
        } else {
            fprintf(stderr, "CPU: $DB STP is 65C02 only\n");
            cycles = 2;
        }
        break;

    /* JMP (abs,X): Indirect indexed jump (65C02 - fixes page wrap bug) */
    case 0x7C:
        if (cpu->mode == 1) {
            uint16_t base = addr_abs(cpu);
            uint16_t addr = (uint16_t)(base + cpu->X);
            if (cpu->mode == 1) {
                /* 65C02: no page wrap bug */
                cpu->PC = RD16(addr);
            } else {
                /* NMOS: has page wrap bug (shouldn't reach here) */
                cpu->PC = rd16_wrap(cpu, addr);
            }
            cycles = 6;
        } else {
            fprintf(stderr, "CPU: $7C JMP (abs,X) is 65C02 only\n");
            cycles = 3;
        }
        break;

    /* ── Illegal / unknown – treat as single-byte NOP ── */
    default:
        fprintf(stderr, "CPU: unknown opcode $%02X at $%04X\n",
                op, (uint16_t)(cpu->PC - 1));
        cycles = 2; break;
    }

    /* Profiling: update opcode statistics */
    cpu->opcode_count[op]++;
    cpu->opcode_cycles[op] += (uint64_t)cycles;

    cpu->cycles += (uint64_t)cycles;
    return cycles;
}

/* Dump CPU profiling statistics */
void cpu6502_dump_profile(const CPU6502 *cpu, void *fp)
{
    if (!fp) return;
    FILE *f = (FILE*)fp;

    fprintf(f, "\n=== CPU Profiling Statistics ===\n");
    fprintf(f, "Total cycles: %llu\n", (unsigned long long)cpu->cycles);
    fprintf(f, "\nTop 20 opcodes by cycle count:\n");
    fprintf(f, "%-8s %-20s %12s %12s %12s\n",
            "Opcode", "Mnemonic", "Count", "Total Cycles", "Avg Cycles");
    fprintf(f, "%-8s %-20s %12s %12s %12s\n",
            "--------", "--------------------", "------------", "------------", "------------");

    /* Sort by total cycles (simple bubble sort for <= 256 items) */
    uint8_t sorted[256];
    for (int i = 0; i < 256; i++) sorted[i] = i;

    for (int i = 0; i < 255; i++) {
        for (int j = i + 1; j < 256; j++) {
            if (cpu->opcode_cycles[sorted[j]] > cpu->opcode_cycles[sorted[i]]) {
                uint8_t tmp = sorted[i];
                sorted[i] = sorted[j];
                sorted[j] = tmp;
            }
        }
    }

    int printed = 0;
    for (int i = 0; i < 256 && printed < 20; i++) {
        uint8_t op = sorted[i];
        if (cpu->opcode_count[op] == 0) continue;

        char buf[64];
        /* Create a temporary read function context for disasm */
        disasm(0, cpu->read, cpu->bus_ctx, buf, sizeof(buf));

        char mnemonic[32];
        if (snprintf(mnemonic, sizeof(mnemonic), "$%02X", op) < 0)
            snprintf(mnemonic, sizeof(mnemonic), "???");

        fprintf(f, "%-8s %-20s %12llu %12llu %12.2f\n",
                mnemonic, "instr",
                (unsigned long long)cpu->opcode_count[op],
                (unsigned long long)cpu->opcode_cycles[op],
                cpu->opcode_count[op] > 0 ?
                    (double)cpu->opcode_cycles[op] / cpu->opcode_count[op] : 0.0);
        printed++;
    }
    fprintf(f, "\n");
}

/* ── Public API ─────────────────────────────────────────────── */

void cpu6502_init(CPU6502 *cpu,
                  uint8_t (*read)(void *, uint16_t),
                  void    (*write)(void *, uint16_t, uint8_t),
                  void    *ctx)
{
    cpu->A = cpu->X = cpu->Y = 0;
    cpu->SP = 0xFF;
    cpu->PC = 0;
    cpu->P  = FLAG_U | FLAG_I;
    cpu->cycles = 0;
    cpu->nmi_pending = cpu->irq_pending = cpu->reset_pending = false;
    cpu->stopped = false;
    cpu->mode = 0;
    memset(cpu->opcode_count, 0, sizeof(cpu->opcode_count));
    memset(cpu->opcode_cycles, 0, sizeof(cpu->opcode_cycles));
    cpu->trace_enabled = false;
    cpu->trace_fp = NULL;
    cpu->read    = read;
    cpu->write   = write;
    cpu->bus_ctx = ctx;
}

void cpu6502_reset(CPU6502 *cpu)
{
    cpu->reset_pending = true;
}

void cpu6502_nmi(CPU6502 *cpu)
{
    cpu->nmi_pending = true;
}

void cpu6502_irq(CPU6502 *cpu)
{
    cpu->irq_pending = true;
}

void cpu6502_irq_clear(CPU6502 *cpu)
{
    cpu->irq_pending = false;
}
