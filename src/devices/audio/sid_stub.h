#ifndef SID_STUB_H
#define SID_STUB_H

#include "sid6581_core.h"

#include <stdbool.h>
#include <SDL2/SDL_atomic.h>

#define SID_AUDIO_BUFFER_SIZE 8192

typedef struct {
    SID6581Core core;
    uint32_t cpu_hz;
    uint64_t clock_phase;
    uint32_t sample_phase;
    int32_t sample_sum;
    unsigned sample_count;
    int16_t samples[SID_AUDIO_BUFFER_SIZE];
    SDL_atomic_t samples_read;
    SDL_atomic_t samples_written;
    bool audio_ready;
} SIDStub;

void sid_init(SIDStub *sid);
void sid_set_cpu_clock(SIDStub *sid, uint32_t cpu_hz);
uint8_t sid_read(void *dev, uint16_t offset);
void sid_write(void *dev, uint16_t offset, uint8_t value);
void sid_tick(void *dev, uint32_t cycles);

#endif
