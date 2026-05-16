#pragma once
#include <stdint.h>

/* Disassemble one instruction at addr, write result to buf.
 * Returns instruction length in bytes.
 * read_fn is called to fetch bytes (pass bus as ctx). */
int disasm(uint16_t addr,
           uint8_t (*read_fn)(void *ctx, uint16_t addr),
           void    *ctx,
           char    *buf, int buf_size);
