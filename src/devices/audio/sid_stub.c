#include "sid_stub.h"
#include "soundchip.h"

#include <string.h>

enum {
    SID_AUDIO_PRIME = SOUND_SAMPLE_RATE / 25,
};

static float sid_audio_sample(void *user, int sample_rate)
{
    SIDStub *sid = user;
    (void)sample_rate;
    int read = SDL_AtomicGet(&sid->samples_read);
    int written = SDL_AtomicGet(&sid->samples_written);
    unsigned buffered = ((unsigned)written - (unsigned)read) & (SID_AUDIO_BUFFER_SIZE - 1);
    if (!buffered) sid->audio_ready = false;
    if (!sid->audio_ready) {
        if (buffered < SID_AUDIO_PRIME) return 0.0f;
        sid->audio_ready = true;
    }

    int16_t sample = sid->samples[read];
    SDL_AtomicSet(&sid->samples_read, (read + 1) & (SID_AUDIO_BUFFER_SIZE - 1));
    return (float)sample / 32768.0f;
}

static void queue_sample(SIDStub *sid, int16_t sample)
{
    int written = SDL_AtomicGet(&sid->samples_written);
    int next = (written + 1) & (SID_AUDIO_BUFFER_SIZE - 1);
    if (next != SDL_AtomicGet(&sid->samples_read)) {
        sid->samples[written] = sample;
        SDL_AtomicSet(&sid->samples_written, next);
    }
}

void sid_init(SIDStub *sid)
{
    memset(sid, 0, sizeof(*sid));
    sid6581_reset(&sid->core);
    sid_set_cpu_clock(sid, SID6581_CLOCK_HZ);
    soundchip_set_sid_source(sid_audio_sample, sid);
}

void sid_set_cpu_clock(SIDStub *sid, uint32_t cpu_hz)
{
    sid->cpu_hz = cpu_hz ? cpu_hz : SID6581_CLOCK_HZ;
    sid->clock_phase = 0;
}

uint8_t sid_read(void *dev, uint16_t offset)
{
    SIDStub *sid = dev;
    return sid6581_read(&sid->core, offset);
}

void sid_write(void *dev, uint16_t offset, uint8_t value)
{
    SIDStub *sid = dev;
    sid6581_write(&sid->core, offset, value);
}

void sid_tick(void *dev, uint32_t cycles)
{
    SIDStub *sid = dev;
    if (!sid->cpu_hz) return;
    sid->clock_phase += (uint64_t)cycles * SID6581_CLOCK_HZ;
    while (sid->clock_phase >= sid->cpu_hz) {
        sid->clock_phase -= sid->cpu_hz;
        sid->sample_sum += sid6581_clock(&sid->core);
        sid->sample_count++;
        sid->sample_phase += SOUND_SAMPLE_RATE;
        if (sid->sample_phase >= SID6581_CLOCK_HZ) {
            sid->sample_phase -= SID6581_CLOCK_HZ;
            queue_sample(sid, (int16_t)(sid->sample_sum / (int32_t)sid->sample_count));
            sid->sample_sum = 0;
            sid->sample_count = 0;
        }
    }
}
