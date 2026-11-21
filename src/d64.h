#ifndef D64_H
#define D64_H

#include <stdint.h>
#include <stdio.h>

#define D64_SECTOR_SIZE 256
#define D64_IMAGE_SIZE 174848
#define D64_SECTOR_COUNT (D64_IMAGE_SIZE / D64_SECTOR_SIZE)

int read_d64_sector(FILE *image, uint8_t track, uint8_t sector, uint8_t out[D64_SECTOR_SIZE]);

/* The caller owns the returned PRG, including its two-byte load address. */
int d64_load_prg(FILE *image, uint8_t track, uint8_t sector, uint8_t **out, size_t *out_len);

#endif
