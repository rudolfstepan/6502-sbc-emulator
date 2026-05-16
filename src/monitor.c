#include "monitor.h"
#include "disasm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

void monitor_init(Monitor *m, CPU6502 *cpu, Bus *bus)
{
    memset(m, 0, sizeof(*m));
    m->cpu = cpu;
    m->bus = bus;
    for (int i = 0; i < 16; i++) m->breakpoints[i] = -1;
}

static void print_regs(const CPU6502 *cpu)
{
    printf("  PC:%04X  A:%02X  X:%02X  Y:%02X  SP:%02X  "
           "P:%c%c-%c%c%c%c%c  cycles:%llu\n",
           cpu->PC, cpu->A, cpu->X, cpu->Y, cpu->SP,
           (cpu->P & FLAG_N) ? 'N' : 'n',
           (cpu->P & FLAG_V) ? 'V' : 'v',
           (cpu->P & FLAG_B) ? 'B' : 'b',
           (cpu->P & FLAG_D) ? 'D' : 'd',
           (cpu->P & FLAG_I) ? 'I' : 'i',
           (cpu->P & FLAG_Z) ? 'Z' : 'z',
           (cpu->P & FLAG_C) ? 'C' : 'c',
           (unsigned long long)cpu->cycles);
}

static void dump_mem(Monitor *m, uint16_t addr, int count)
{
    for (int row = 0; row < count; row += 16) {
        printf("  %04X: ", (uint16_t)(addr + row));
        for (int col = 0; col < 16; col++) {
            if (row + col < count)
                printf("%02X ", bus_read(m->bus, (uint16_t)(addr + row + col)));
            else
                printf("   ");
        }
        printf(" |");
        for (int col = 0; col < 16 && row + col < count; col++) {
            uint8_t c = bus_read(m->bus, (uint16_t)(addr + row + col));
            printf("%c", isprint(c) ? c : '.');
        }
        printf("|\n");
    }
}

static void help(void)
{
    printf("  Monitor commands:\n"
           "  r          - show registers\n"
           "  d [addr]   - disassemble 16 instructions\n"
           "  m addr [n] - hex dump n bytes (default 64)\n"
           "  b addr     - set breakpoint\n"
           "  bl         - list breakpoints\n"
           "  bc n       - clear breakpoint n\n"
           "  s          - step one instruction\n"
           "  c          - continue\n"
           "  q          - quit emulator\n");
}

bool monitor_run(Monitor *m)
{
    static char line[256];
    static uint16_t last_d_addr = 0;

    printf("\n[monitor] ");
    fflush(stdout);

    if (!fgets(line, sizeof(line), stdin)) {
        return false; /* EOF */
    }

    /* strip newline */
    line[strcspn(line, "\n\r")] = 0;
    char *p = line;
    while (*p == ' ') p++;

    if (*p == 'q') { return false; }
    if (*p == 'c') { m->active = false; m->step_mode = false; return true; }
    if (*p == 's') { m->step_mode = true; m->active = false; return true; }
    if (*p == 'r') { print_regs(m->cpu); return true; }
    if (*p == '?') { help(); return true; }

    if (*p == 'd') {
        p++; while (*p == ' ') p++;
        uint16_t addr = *p ? (uint16_t)strtol(p, NULL, 16) : last_d_addr;
        /* We need a proper read wrapper: use bus_read */
        for (int i = 0; i < 16; i++) {
            char buf[64];
            int len = disasm(addr, (uint8_t(*)(void*,uint16_t))bus_read,
                             m->bus, buf, sizeof(buf));
            printf("  %s%s\n", buf, addr == m->cpu->PC ? "  <<" : "");
            addr = (uint16_t)(addr + len);
        }
        last_d_addr = addr;
        return true;
    }

    if (*p == 'm') {
        p++; while (*p == ' ') p++;
        if (!*p) { printf("  usage: m <addr> [count]\n"); return true; }
        char *end;
        uint16_t addr = (uint16_t)strtol(p, &end, 16);
        int count = 64;
        while (*end == ' ') end++;
        if (*end) count = (int)strtol(end, NULL, 0);
        dump_mem(m, addr, count);
        return true;
    }

    if (p[0] == 'b' && p[1] == 'l') {
        printf("  Breakpoints:\n");
        for (int i = 0; i < 16; i++)
            if (m->breakpoints[i] >= 0)
                printf("    %d: $%04X\n", i, (uint16_t)m->breakpoints[i]);
        return true;
    }

    if (p[0] == 'b' && p[1] == 'c') {
        p += 2; while (*p == ' ') p++;
        int n = atoi(p);
        if (n >= 0 && n < 16) { m->breakpoints[n] = -1; printf("  bp%d cleared\n", n); }
        return true;
    }

    if (*p == 'b') {
        p++; while (*p == ' ') p++;
        if (!*p) { printf("  usage: b <addr>\n"); return true; }
        uint16_t addr = (uint16_t)strtol(p, NULL, 16);
        for (int i = 0; i < 16; i++) {
            if (m->breakpoints[i] < 0) {
                m->breakpoints[i] = addr;
                printf("  bp%d set at $%04X\n", i, addr);
                if (i >= m->num_breakpoints) m->num_breakpoints = i + 1;
                return true;
            }
        }
        printf("  no free breakpoint slots\n");
        return true;
    }

    if (*p) printf("  unknown command '%s', type ? for help\n", p);
    return true;
}

bool monitor_check(Monitor *m)
{
    if (m->step_mode) {
        print_regs(m->cpu);
        m->active = true;
        m->step_mode = false;
        return true;
    }
    for (int i = 0; i < m->num_breakpoints; i++) {
        if (m->breakpoints[i] == (int)m->cpu->PC) {
            printf("\n  *** Breakpoint %d hit at $%04X ***\n", i, m->cpu->PC);
            print_regs(m->cpu);
            m->active = true;
            return true;
        }
    }
    return false;
}
