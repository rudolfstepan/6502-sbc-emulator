#ifndef C64_FLOPPY_H
#define C64_FLOPPY_H

#include <stdio.h>

#include "c64.h"
#include "core/cpu/cpu6502.h"

#define C64_FLOPPY_DEFAULT_DEVICE 8

typedef struct {
    FILE *image;
    unsigned int device;
} C64Floppy;

bool c64_floppy_mount(C64Floppy *floppy, const char *path);
void c64_floppy_close(C64Floppy *floppy);

/* Service a KERNAL LOAD/VERIFY for the mounted device and return its cycles. */
int c64_floppy_step(C64Floppy *floppy, C64 *c64, CPU6502 *cpu);

#endif
