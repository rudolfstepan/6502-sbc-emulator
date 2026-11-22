#pragma once
#include <stdbool.h>
#include <stdint.h>

bool disasm_is_official_6502_opcode(uint8_t opcode);

/* Disassemble one instruction at addr, write result to buf.
 * Returns instruction length in bytes.
 * read_fn is called to fetch bytes (pass bus as ctx). */
int disasm(uint16_t addr,
           uint8_t (*read_fn)(void *ctx, uint16_t addr),
           void    *ctx,
           char    *buf, int buf_size);
