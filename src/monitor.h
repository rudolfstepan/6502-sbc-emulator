#pragma once
#include "cpu6502.h"
#include "bus.h"

typedef struct {
    CPU6502 *cpu;
    Bus     *bus;
    int      breakpoints[16];
    int      num_breakpoints;
    bool     active;          /* true = in monitor mode */
    bool     step_mode;
} Monitor;

void monitor_init(Monitor *m, CPU6502 *cpu, Bus *bus);
/* Returns true if emulation should continue, false to quit */
bool monitor_run(Monitor *m);
/* Called each step; returns true to enter monitor (breakpoint hit) */
bool monitor_check(Monitor *m);
