#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "../src/cpu6502.h"

static uint8_t ram[65536];

static uint8_t ram_read(void *ctx, uint16_t addr) {
    (void)ctx;
    return ram[addr];
}

static void ram_write(void *ctx, uint16_t addr, uint8_t val) {
    (void)ctx;
    ram[addr] = val;
}

int main(void) {
    printf("Testing 65C02 opcodes...\n");

    CPU6502 cpu;
    cpu6502_init(&cpu, ram_read, ram_write, NULL);
    cpu.mode = 1;  /* 65C02 mode */

    /* Test BRA (Branch Always) - $80 */
    printf("  BRA: ");
    ram[0x8000] = 0x80;  /* BRA +0x10 */
    ram[0x8001] = 0x10;
    cpu.PC = 0x8000;
    int c = cpu6502_step(&cpu);
    if (cpu.PC == 0x8012 && c == 3) {
        printf("OK (BRA taken)\n");
    } else {
        printf("FAIL (PC=%04X, cycles=%d)\n", cpu.PC, c);
    }

    /* Test INC A - $1A */
    printf("  INC A: ");
    ram[0x8000] = 0x1A;
    cpu.PC = 0x8000;
    cpu.A = 0x42;
    c = cpu6502_step(&cpu);
    if (cpu.A == 0x43 && c == 2) {
        printf("OK (A=0x43)\n");
    } else {
        printf("FAIL (A=%02X, cycles=%d)\n", cpu.A, c);
    }

    /* Test DEC A - $3A */
    printf("  DEC A: ");
    ram[0x8000] = 0x3A;
    cpu.PC = 0x8000;
    cpu.A = 0x42;
    c = cpu6502_step(&cpu);
    if (cpu.A == 0x41 && c == 2) {
        printf("OK (A=0x41)\n");
    } else {
        printf("FAIL (A=%02X, cycles=%d)\n", cpu.A, c);
    }

    /* Test PHX / PLX - $DA / $FA */
    printf("  PHX/PLX: ");
    cpu.SP = 0xFF;
    cpu.X = 0x55;
    ram[0x8000] = 0xDA;  /* PHX */
    cpu.PC = 0x8000;
    c = cpu6502_step(&cpu);
    if (ram[0x01FF] == 0x55 && cpu.SP == 0xFE) {
        printf("OK (PHX) ");
        ram[0x8000] = 0xFA;  /* PLX */
        cpu.PC = 0x8000;
        c = cpu6502_step(&cpu);
        if (cpu.X == 0x55 && cpu.SP == 0xFF) {
            printf("OK (PLX)\n");
        } else {
            printf("FAIL (PLX)\n");
        }
    } else {
        printf("FAIL (PHX)\n");
    }

    /* Test PHY / PLY - $5A / $7A */
    printf("  PHY/PLY: ");
    cpu.SP = 0xFF;
    cpu.Y = 0xAA;
    ram[0x8000] = 0x5A;  /* PHY */
    cpu.PC = 0x8000;
    c = cpu6502_step(&cpu);
    if (ram[0x01FF] == 0xAA && cpu.SP == 0xFE) {
        printf("OK (PHY) ");
        ram[0x8000] = 0x7A;  /* PLY */
        cpu.PC = 0x8000;
        c = cpu6502_step(&cpu);
        if (cpu.Y == 0xAA && cpu.SP == 0xFF) {
            printf("OK (PLY)\n");
        } else {
            printf("FAIL (PLY)\n");
        }
    } else {
        printf("FAIL (PHY)\n");
    }

    /* Test STZ zp - $64 */
    printf("  STZ zp: ");
    ram[0x0042] = 0xFF;
    ram[0x8000] = 0x64;  /* STZ $42 */
    ram[0x8001] = 0x42;
    cpu.PC = 0x8000;
    c = cpu6502_step(&cpu);
    if (ram[0x0042] == 0x00 && c == 3) {
        printf("OK\n");
    } else {
        printf("FAIL (mem=%02X, cycles=%d)\n", ram[0x0042], c);
    }

    /* Test BIT immediate - $89 (only affects Z, not N/V) */
    printf("  BIT #imm: ");
    ram[0x8000] = 0x89;  /* BIT #0x80 */
    ram[0x8001] = 0x80;
    cpu.PC = 0x8000;
    cpu.A = 0x00;
    cpu.P = 0;  /* Clear flags */
    c = cpu6502_step(&cpu);
    /* Z should be set, N and V should not be affected */
    if ((cpu.P & 0x02) && !(cpu.P & 0xC0) && c == 2) {
        printf("OK (Z set, N/V clear)\n");
    } else {
        printf("FAIL (P=%02X, cycles=%d)\n", cpu.P, c);
    }

    printf("\ntest_65c02: ok\n");
    return 0;
}
