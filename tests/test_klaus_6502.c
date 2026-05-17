#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cpu6502.h"

#define KLAUS_START_PC 0x0400u
#define KLAUS_PASS_PC  0x3469u

static uint8_t g_mem[65536];

static uint8_t mem_read(void *ctx, uint16_t addr)
{
    (void)ctx;
    return g_mem[addr];
}

static void mem_write(void *ctx, uint16_t addr, uint8_t val)
{
    (void)ctx;
    g_mem[addr] = val;
}

static int load_image(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "klaus: cannot open '%s'\n", path);
        return -1;
    }

    size_t got = fread(g_mem, 1, sizeof(g_mem), f);
    fclose(f);

    if (got != sizeof(g_mem)) {
        fprintf(stderr, "klaus: expected 65536 bytes, got %zu\n", got);
        return -1;
    }
    return 0;
}

int main(void)
{
    CPU6502 cpu;
    uint16_t last_pc = 0xFFFFu;
    int same_pc = 0;

    memset(g_mem, 0, sizeof(g_mem));
    if (load_image("build/klaus/6502_functional_test.bin") != 0) {
        return 1;
    }

    cpu6502_init(&cpu, mem_read, mem_write, NULL);

    /* Klaus test binary expects execution to begin at $0400. */
    cpu.PC = KLAUS_START_PC;
    cpu.SP = 0xFD;
    cpu.P = FLAG_I | FLAG_U;

    for (uint64_t step = 0; step < 200000000ULL; step++) {
        (void)cpu6502_step(&cpu);

        if (cpu.PC == last_pc) {
            same_pc++;
            if (same_pc > 32) {
                if (cpu.PC == KLAUS_PASS_PC) {
                    puts("test_klaus_6502: ok");
                    return 0;
                }
                fprintf(stderr, "klaus: trapped at $%04X (expected pass loop at $%04X)\n",
                        cpu.PC, KLAUS_PASS_PC);
                return 1;
            }
        } else {
            last_pc = cpu.PC;
            same_pc = 0;
        }
    }

    fprintf(stderr, "klaus: step budget exhausted, last PC=$%04X\n", cpu.PC);
    return 1;
}
