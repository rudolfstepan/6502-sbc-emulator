#ifndef SID_STUB_H
#define SID_STUB_H

#include <stdint.h>

typedef struct {
    uint8_t regs[0x1D];
    uint8_t osc3;
    uint8_t env3;
    double  phase[3];
    float   env[3];
    uint8_t gate[3];
    uint8_t state[3];
    uint32_t noise[3];
    float   noise_sample[3];
} SIDStub;

void sid_init(SIDStub *sid);
uint8_t sid_read(void *dev, uint16_t offset);
void sid_write(void *dev, uint16_t offset, uint8_t val);
void sid_tick(void *dev, uint32_t cycles);

#endif
