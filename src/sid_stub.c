#include "sid_stub.h"
#include "soundchip.h"
#include <string.h>
#include <math.h>

#define SID_CLOCK_HZ 985248.0

enum {
    SID_ENV_IDLE = 0,
    SID_ENV_ATTACK,
    SID_ENV_DECAY,
    SID_ENV_SUSTAIN,
    SID_ENV_RELEASE,
};

static const float attack_s[16] = {
    0.002f, 0.008f, 0.016f, 0.024f, 0.038f, 0.056f, 0.068f, 0.080f,
    0.100f, 0.250f, 0.500f, 0.800f, 1.000f, 3.000f, 5.000f, 8.000f
};

static const float decay_release_s[16] = {
    0.006f, 0.024f, 0.048f, 0.072f, 0.114f, 0.168f, 0.204f, 0.240f,
    0.300f, 0.750f, 1.500f, 2.400f, 3.000f, 9.000f, 15.000f, 24.000f
};

static float clampf(float v, float lo, float hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

static uint32_t sid_noise_next(uint32_t x)
{
    if (x == 0) {
        x = 0x7FFFF8u;
    }
    uint32_t bit = ((x >> 22) ^ (x >> 17)) & 1u;
    return ((x << 1) | bit) & 0x7FFFFFu;
}

static void sid_gate_write(SIDStub *sid, int voice, uint8_t ctrl)
{
    uint8_t gate = ctrl & 0x01u;
    if (gate && !sid->gate[voice]) {
        sid->state[voice] = SID_ENV_ATTACK;
    } else if (!gate && sid->gate[voice]) {
        sid->state[voice] = SID_ENV_RELEASE;
    }
    sid->gate[voice] = gate;

    if (ctrl & 0x08u) {
        sid->phase[voice] = 0.0;
        sid->noise[voice] = 0x7FFFF8u ^ (uint32_t)(voice * 0x12345u);
        sid->noise_sample[voice] = 0.0f;
    }
}

static void sid_update_envelope(SIDStub *sid, int voice, float dt)
{
    int base = voice * 7;
    uint8_t ad = sid->regs[base + 5];
    uint8_t sr = sid->regs[base + 6];
    float sustain = (float)((sr >> 4) & 0x0F) / 15.0f;
    float *env = &sid->env[voice];

    switch (sid->state[voice]) {
    case SID_ENV_ATTACK: {
        float t = attack_s[(ad >> 4) & 0x0F];
        *env += dt / t;
        if (*env >= 1.0f) {
            *env = 1.0f;
            sid->state[voice] = SID_ENV_DECAY;
        }
        break;
    }
    case SID_ENV_DECAY: {
        float t = decay_release_s[ad & 0x0F];
        if (*env > sustain) {
            *env -= dt / t;
            if (*env <= sustain) {
                *env = sustain;
                sid->state[voice] = SID_ENV_SUSTAIN;
            }
        } else {
            sid->state[voice] = SID_ENV_SUSTAIN;
        }
        break;
    }
    case SID_ENV_SUSTAIN:
        if (!sid->gate[voice]) {
            sid->state[voice] = SID_ENV_RELEASE;
        } else if (*env > sustain) {
            sid->state[voice] = SID_ENV_DECAY;
        } else {
            *env = sustain;
        }
        break;
    case SID_ENV_RELEASE: {
        float t = decay_release_s[sr & 0x0F];
        *env -= dt / t;
        if (*env <= 0.0f) {
            *env = 0.0f;
            sid->state[voice] = SID_ENV_IDLE;
        }
        break;
    }
    default:
        *env = 0.0f;
        break;
    }
}

static float sid_voice_sample(SIDStub *sid, int voice, int sample_rate)
{
    int base = voice * 7;
    uint8_t ctrl = sid->regs[base + 4];
    if (ctrl & 0x08u) {
        return 0.0f;
    }

    uint16_t freq_reg = (uint16_t)sid->regs[base] |
                        ((uint16_t)sid->regs[base + 1] << 8);
    uint16_t pulse_reg = (uint16_t)sid->regs[base + 2] |
                         (((uint16_t)sid->regs[base + 3] & 0x0Fu) << 8);
    double step = ((double)freq_reg * SID_CLOCK_HZ) /
                  (16777216.0 * (double)sample_rate);
    double old_phase = sid->phase[voice];
    sid->phase[voice] += step;
    if (sid->phase[voice] >= 1.0) {
        sid->phase[voice] -= floor(sid->phase[voice]);
        sid->noise[voice] = sid_noise_next(sid->noise[voice]);
        sid->noise_sample[voice] =
            ((float)((int)(sid->noise[voice] & 0xFFFFu) - 32768)) / 32768.0f;
    } else if (sid->phase[voice] < old_phase) {
        sid->noise[voice] = sid_noise_next(sid->noise[voice]);
    }

    double p = sid->phase[voice];
    float mixed = 0.0f;
    int count = 0;

    if (ctrl & 0x10u) {
        mixed += p < 0.5 ? (float)(p * 4.0 - 1.0)
                         : (float)(3.0 - p * 4.0);
        count++;
    }
    if (ctrl & 0x20u) {
        mixed += (float)(p * 2.0 - 1.0);
        count++;
    }
    if (ctrl & 0x40u) {
        double pw = pulse_reg ? (double)pulse_reg / 4096.0 : 0.5;
        mixed += p < pw ? 1.0f : -1.0f;
        count++;
    }
    if (ctrl & 0x80u) {
        mixed += sid->noise_sample[voice];
        count++;
    }

    if (count == 0) {
        return 0.0f;
    }

    return (mixed / (float)count) * sid->env[voice];
}

static float sid_audio_sample(void *user, int sample_rate)
{
    SIDStub *sid = (SIDStub *)user;
    float dt = 1.0f / (float)sample_rate;
    float total = 0.0f;

    for (int v = 0; v < 3; v++) {
        sid_update_envelope(sid, v, dt);
        total += sid_voice_sample(sid, v, sample_rate);
    }

    sid->osc3 = (uint8_t)(sid->phase[2] * 255.0);
    sid->env3 = (uint8_t)clampf(sid->env[2] * 255.0f, 0.0f, 255.0f);

    float master = (float)(sid->regs[0x18] & 0x0Fu) / 15.0f;
    return total * master * 0.28f;
}

void sid_init(SIDStub *sid)
{
    memset(sid, 0, sizeof(*sid));
    for (int i = 0; i < 3; i++) {
        sid->noise[i] = 0x7FFFF8u ^ (uint32_t)(i * 0x12345u);
    }
    soundchip_set_sid_source(sid_audio_sample, sid);
}

uint8_t sid_read(void *dev, uint16_t offset)
{
    SIDStub *sid = (SIDStub *)dev;
    offset %= sizeof(sid->regs);
    if (offset == 0x1B) {
        return sid->osc3;
    }
    if (offset == 0x1C) {
        return sid->env3;
    }
    return sid->regs[offset];
}

void sid_write(void *dev, uint16_t offset, uint8_t val)
{
    SIDStub *sid = (SIDStub *)dev;
    offset %= sizeof(sid->regs);
    sid->regs[offset] = val;
    if (offset == 0x04 || offset == 0x0B || offset == 0x12) {
        sid_gate_write(sid, (int)(offset / 7), val);
    }
}

void sid_tick(void *dev, uint32_t cycles)
{
    (void)dev;
    (void)cycles;
}
