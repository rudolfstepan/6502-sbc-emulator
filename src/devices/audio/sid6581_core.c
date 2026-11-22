#include "sid6581_core.h"

#include <stdbool.h>
#include <string.h>

/* SID-rate equivalent of the FPGA's sid6581.vhd, before DAC resampling. */
enum {
    ENV_IDLE,
    ENV_ATTACK,
    ENV_DECAY,
    ENV_SUSTAIN,
    ENV_RELEASE,
};

enum {
    REG_CONTROL = 4,
    REG_ATTACK_DECAY = 5,
    REG_SUSTAIN_RELEASE = 6,
    REG_CUTOFF_LO = 21,
    REG_CUTOFF_HI = 22,
    REG_RESONANCE = 23,
    REG_MODE_VOLUME = 24,
    PHASE_MASK = 0xFFFFFF,
    NOISE_MASK = 0x7FFFFF,
    PHASE_MSB = 1 << 23,
    NOISE_CLOCK_BIT = 1 << 19,
    FILTER_LIMIT = 1 << 21,
    VOLUME_DAC_STEP = 512,
};

static const uint16_t envelope_periods[16] = {
    9, 32, 63, 95, 149, 220, 267, 313, 392, 977, 1954, 3126, 3907, 11720, 19532, 31251
};

static const uint16_t cutoff_endpoints[9] = {
    50, 89, 159, 282, 502, 891, 1586, 2819, 5015
};

static int32_t arithmetic_shift(int64_t value, unsigned shift)
{
    /* VHDL shift_right rounds negative values toward minus infinity. */
    int64_t divisor = INT64_C(1) << shift;
    return (int32_t)(value >= 0 ? value / divisor : -1 - (-1 - value) / divisor);
}

static uint8_t envelope_divisor(uint8_t level)
{
    if (level > 0x5D) return 1;
    if (level > 0x35) return 2;
    if (level > 0x19) return 4;
    if (level > 0x0D) return 8;
    if (level > 0x05) return 16;
    return 30;
}

static void clock_envelope(SID6581Voice *voice, const uint8_t *regs)
{
    unsigned ad = regs[REG_ATTACK_DECAY];
    unsigned sr = regs[REG_SUSTAIN_RELEASE];
    unsigned sustain = (sr >> 4) * 17;
    unsigned rate = 0;
    if (voice->envelope_state == ENV_ATTACK) {
        rate = ad >> 4;
    } else if (voice->envelope_state == ENV_DECAY || voice->envelope_state == ENV_SUSTAIN) {
        rate = ad & 15;
    } else if (voice->envelope_state == ENV_RELEASE) {
        rate = sr & 15;
    }
    if (voice->envelope_rate < envelope_periods[rate]) {
        voice->envelope_rate++;
        return;
    }
    voice->envelope_rate = 0;

    switch (voice->envelope_state) {
    case ENV_ATTACK:
        if (voice->envelope == 255) {
            voice->envelope_state = ENV_DECAY;
            voice->envelope_divider = 0;
        } else {
            voice->envelope++;
        }
        break;
    case ENV_DECAY:
        if (voice->envelope <= sustain) {
            voice->envelope = (uint8_t)sustain;
            voice->envelope_state = ENV_SUSTAIN;
            voice->envelope_divider = 0;
            break;
        }
        /* Decay and release share the exponential divider. */
        /* fall through */
    case ENV_RELEASE:
        if (voice->envelope == 0) {
            voice->envelope_state = ENV_IDLE;
        } else if (++voice->envelope_divider >= envelope_divisor(voice->envelope)) {
            voice->envelope--;
            voice->envelope_divider = 0;
        }
        break;
    case ENV_SUSTAIN:
        if (voice->envelope > sustain) voice->envelope_state = ENV_DECAY;
        break;
    default:
        voice->envelope = 0;
        break;
    }
}

static void clock_oscillators(SID6581Core *sid)
{
    uint32_t next[SID6581_VOICES];
    bool rising[SID6581_VOICES];
    for (unsigned i = 0; i < SID6581_VOICES; i++) {
        const uint8_t *regs = sid->regs + 7 * i;
        SID6581Voice *voice = &sid->voices[i];
        unsigned frequency = regs[0] | ((unsigned)regs[1] << 8);
        next[i] = (regs[REG_CONTROL] & 8) ? 0 : (voice->phase + frequency) & PHASE_MASK;
        rising[i] = !voice->oscillator_msb && (next[i] & PHASE_MSB);
    }
    for (unsigned i = 0; i < SID6581_VOICES; i++) {
        const uint8_t *regs = sid->regs + 7 * i;
        SID6581Voice *voice = &sid->voices[i];
        unsigned source = (i + SID6581_VOICES - 1) % SID6581_VOICES;
        voice->oscillator_msb = (next[i] & PHASE_MSB) != 0;
        if (regs[REG_CONTROL] & 8) {
            voice->noise = NOISE_MASK;
        } else {
            if ((regs[REG_CONTROL] & 2) && rising[source]) next[i] = 0;
            if ((next[i] & NOISE_CLOCK_BIT) && !(voice->phase & NOISE_CLOCK_BIT)) {
                unsigned feedback = ((voice->noise >> 22) ^ (voice->noise >> 17)) & 1;
                voice->noise = ((voice->noise << 1) | feedback) & NOISE_MASK;
            }
        }
        voice->phase = next[i];
        clock_envelope(voice, regs);
    }
}

static int32_t voice_level(const SID6581Core *sid, unsigned index)
{
    const SID6581Voice *voice = &sid->voices[index];
    const uint8_t *regs = sid->regs + 7 * index;
    unsigned control = regs[REG_CONTROL];
    if (!(control & 0xF0)) return 0;

    unsigned wave = 0xFFF;
    unsigned phase = voice->phase >> 12;
    if (control & 0x10) {
        unsigned source = (index + SID6581_VOICES - 1) % SID6581_VOICES;
        unsigned triangle_phase = voice->phase;
        if (control & 4) triangle_phase ^= sid->voices[source].phase & PHASE_MSB;
        unsigned lower = phase & 0x7FF;
        wave &= 2 * ((triangle_phase & PHASE_MSB) ? 2047 - lower : lower);
    }
    if (control & 0x20) wave &= phase;
    unsigned width = regs[2] | ((unsigned)(regs[3] & 15) << 8);
    if ((control & 0x40) && phase < width) wave = 0;
    if (control & 0x80) wave &= (voice->noise >> 15) << 4;
    return arithmetic_shift(((int32_t)wave - 2048) * voice->envelope, 6);
}

static int32_t clamp_filter(int32_t value)
{
    if (value > FILTER_LIMIT) return FILTER_LIMIT;
    if (value < -FILTER_LIMIT) return -FILTER_LIMIT;
    return value;
}

static int16_t mix(SID6581Core *sid)
{
    unsigned route = sid->regs[REG_RESONANCE];
    unsigned mode = sid->regs[REG_MODE_VOLUME];
    int32_t direct = 0;
    int32_t filtered = 0;
    for (unsigned i = 0; i < SID6581_VOICES; i++) {
        int32_t level = voice_level(sid, i);
        if (route & (1u << i)) {
            filtered += level;
        } else if (!(i == 2 && (mode & 0x80))) {
            direct += level;
        }
    }

    unsigned cutoff = ((unsigned)sid->regs[REG_CUTOFF_HI] << 3) |
                      (sid->regs[REG_CUTOFF_LO] & 7);
    unsigned segment = cutoff >> 8;
    unsigned low = cutoff_endpoints[segment];
    unsigned high = cutoff_endpoints[segment + 1];
    int32_t coefficient = (int32_t)(low + (((high - low) * (cutoff & 255)) >> 8));
    int32_t damping = 92000 - (int32_t)(route >> 4) * 3949;
    int32_t hp = filtered - sid->low_pass - arithmetic_shift((int64_t)damping * sid->band_pass, 16);
    sid->band_pass = clamp_filter(sid->band_pass + arithmetic_shift((int64_t)coefficient * hp, 16));
    sid->low_pass = clamp_filter(sid->low_pass + arithmetic_shift((int64_t)coefficient * sid->band_pass, 16));

    if (mode & 0x10) direct += sid->low_pass;
    if (mode & 0x20) direct += sid->band_pass;
    if (mode & 0x40) direct += hp;
    int32_t volume = (int32_t)(mode & 15);
    int32_t digi = volume * VOLUME_DAC_STEP - sid->volume_dc;
    sid->volume_dc += arithmetic_shift(digi, 12);
    int32_t sample = arithmetic_shift(direct * volume, 4) + digi;
    if (sample > INT16_MAX) return INT16_MAX;
    if (sample < INT16_MIN) return INT16_MIN;
    return (int16_t)sample;
}

void sid6581_reset(SID6581Core *sid)
{
    memset(sid, 0, sizeof(*sid));
    for (unsigned i = 0; i < SID6581_VOICES; i++) sid->voices[i].noise = NOISE_MASK;
}

uint8_t sid6581_read(const SID6581Core *sid, uint16_t offset)
{
    if (offset < sizeof(sid->regs)) return sid->regs[offset];
    if (offset == 0x1B) return (uint8_t)(sid->voices[2].phase >> 16);
    if (offset == 0x1C) return sid->voices[2].envelope;
    return 0xFF;
}

void sid6581_write(SID6581Core *sid, uint16_t offset, uint8_t value)
{
    if (offset >= sizeof(sid->regs)) return;
    if (offset % 7 == REG_CONTROL && ((sid->regs[offset] ^ value) & 1)) {
        SID6581Voice *voice = &sid->voices[offset / 7];
        voice->envelope_state = (value & 1) ? ENV_ATTACK : ENV_RELEASE;
        voice->envelope_rate = 0;
        voice->envelope_divider = 0;
    }
    sid->regs[offset] = value;
}

int16_t sid6581_clock(SID6581Core *sid)
{
    /* The FPGA mixer latches the oscillator/envelope state before this tick. */
    int16_t sample = mix(sid);
    clock_oscillators(sid);
    return sample;
}
