#include "soundchip.h"
#include <SDL2/SDL.h>
#include <math.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

static SDL_AudioDeviceID audio_device;
static SDL_AudioSpec obtained_spec;
static uint8_t regs[6];
static int initialized = 0;

enum {
    SOUND_FREQ_LO = 0,
    SOUND_FREQ_HI = 1,
    SOUND_DUR_LO = 2,
    SOUND_DUR_HI = 3,
    SOUND_VOL    = 4,
    SOUND_CTRL   = 5
};

static void beep_from_regs(void)
{
    uint16_t freq = (uint16_t)regs[SOUND_FREQ_LO]
                  | (uint16_t)((uint16_t)regs[SOUND_FREQ_HI] << 8);
    uint16_t dur = (uint16_t)regs[SOUND_DUR_LO]
                 | (uint16_t)((uint16_t)regs[SOUND_DUR_HI] << 8);

    if (freq == 0) {
        freq = 440;
    }
    if (dur == 0) {
        dur = 120;
    }

    soundchip_beep((float)freq, (int)dur);
}

void soundchip_init() {
    if (initialized) return;

    memset(regs, 0, sizeof(regs));
    regs[SOUND_VOL] = 200;

    if ((SDL_WasInit(SDL_INIT_AUDIO) & SDL_INIT_AUDIO) == 0) {
        if (SDL_WasInit(0) == 0) {
            if (SDL_Init(SDL_INIT_AUDIO) != 0) {
                fprintf(stderr, "soundchip: SDL_Init(audio) failed: %s\n", SDL_GetError());
                return;
            }
        } else if (SDL_InitSubSystem(SDL_INIT_AUDIO) != 0) {
            fprintf(stderr, "soundchip: SDL_InitSubSystem(audio) failed: %s\n", SDL_GetError());
            return;
        }
    }

    SDL_AudioSpec want;
    SDL_zero(want);
    want.freq = 44100;
    want.format = AUDIO_F32SYS;
    want.channels = 1;
    want.samples = 1024;
    want.callback = NULL;

    SDL_zero(obtained_spec);
    audio_device = SDL_OpenAudioDevice(NULL, 0, &want, &obtained_spec, 0);
    if (audio_device == 0) {
        fprintf(stderr, "soundchip: failed to open audio device: %s\n", SDL_GetError());
        return;
    }

    SDL_PauseAudioDevice(audio_device, 0);
    initialized = 1;
}

void soundchip_beep(float frequency, int duration_ms) {
    if (!initialized || audio_device == 0) {
        return;
    }

    if (duration_ms <= 0) duration_ms = 120;
    if (frequency < 20.0f) frequency = 20.0f;
    if (frequency > 12000.0f) frequency = 12000.0f;

    const float pi = 3.14159265358979323846f;
    const int sample_rate = obtained_spec.freq > 0 ? obtained_spec.freq : 44100;
    const int sample_count = (sample_rate * duration_ms) / 1000;
    const float gain = ((float)regs[SOUND_VOL]) / 255.0f;

    float *buffer = (float *)malloc((size_t)sample_count * sizeof(float));

    if (!buffer || sample_count <= 0) {
        free(buffer);
        return;
    }

    for (int i = 0; i < sample_count; i++) {
        float phase = (2.0f * pi * frequency * (float)i) / (float)sample_rate;
        buffer[i] = gain * 0.30f * sinf(phase);
    }

    SDL_QueueAudio(audio_device, buffer, (uint32_t)((size_t)sample_count * sizeof(float)));
    SDL_PauseAudioDevice(audio_device, 0);

    free(buffer);
}

void soundchip_shutdown() {
    if (!initialized) {
        return;
    }

    SDL_ClearQueuedAudio(audio_device);
    SDL_CloseAudioDevice(audio_device);
    audio_device = 0;
    initialized = 0;
}

uint8_t soundchip_bus_read(void *dev, uint16_t offset)
{
    (void)dev;
    if (offset < sizeof(regs)) {
        return regs[offset];
    }
    return 0xFF;
}

void soundchip_bus_write(void *dev, uint16_t offset, uint8_t val)
{
    (void)dev;
    if (offset >= sizeof(regs)) {
        return;
    }

    regs[offset] = val;
    if (offset == SOUND_CTRL && (val & 0x01u) != 0) {
        beep_from_regs();
    }
}