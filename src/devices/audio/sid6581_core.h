#ifndef SID6581_CORE_H
#define SID6581_CORE_H

#include <stdint.h>

#define SID6581_CLOCK_HZ 985248u
#define SID6581_VOICES 3

typedef struct {
    uint32_t phase;
    uint32_t noise;
    uint16_t envelope_rate;
    uint8_t envelope;
    uint8_t envelope_divider;
    uint8_t envelope_state;
    uint8_t oscillator_msb;
} SID6581Voice;

typedef struct {
    uint8_t regs[25];
    SID6581Voice voices[SID6581_VOICES];
    int32_t low_pass;
    int32_t band_pass;
    int32_t volume_dc;
} SID6581Core;

void sid6581_reset(SID6581Core *sid);
uint8_t sid6581_read(const SID6581Core *sid, uint16_t offset);
void sid6581_write(SID6581Core *sid, uint16_t offset, uint8_t value);
int16_t sid6581_clock(SID6581Core *sid);

#endif
