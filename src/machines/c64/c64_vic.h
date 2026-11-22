#ifndef C64_VIC_H
#define C64_VIC_H

#include "c64.h"

uint8_t c64_vic_read(C64 *c64, unsigned int reg);
void c64_vic_write(C64 *c64, unsigned int reg, uint8_t value);
void c64_vic_tick(C64 *c64, uint32_t cycles);
bool c64_vic_irq(const C64 *c64);

/* CPU time unavailable for a matrix fetch at the current beam position. */
int c64_vic_cpu_stall(const C64 *c64);

/* Indexes into the sixteen-color C64 palette, from the last completed frame. */
const uint8_t (*c64_vic_frame(const C64 *c64))[C64_VIDEO_WIDTH];

#endif
