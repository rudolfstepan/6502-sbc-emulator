#include "soundchip.h"
#include <SDL2/SDL.h>
#include <stdbool.h>
#include <math.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

/* ── Constants ─────────────────────────────────────────────── */
#define SAMPLE_RATE     44100
#define ADSR_MS_PER_UNIT 8
static const float TWO_PI = 6.28318530717958647692f;
static const float PI_F   = 3.14159265358979323846f;
static const float INV_PI = 0.31830988618379067154f;

/* ── Per-voice state ────────────────────────────────────────── */
typedef struct {
    uint8_t regs[SOUND_REG_COUNT];   /* writable per-voice registers */

    /* note parameters — captured at trigger time, read by callback */
    float frequency;
    float duration_ms;
    float peak;                      /* max amplitude (0..1), per-voice volume */
    float atk_ms, dec_ms, sus_amp, rel_ms;

    /* oscillator state — written exclusively by the audio callback */
    float    phase;
    float    time_ms;
    bool     active;
    uint8_t  waveform;      /* 0=sine 1=square 2=sawtooth 3=triangle 4=noise */
    uint32_t noise_state;   /* xorshift32 LFSR for noise waveform */
} SoundVoice;

static SoundVoice    voices[SOUND_VOICES];
static SDL_AudioDeviceID audio_device;
static int           initialized = 0;
static int           sample_rate = SAMPLE_RATE;
static soundchip_sample_source_fn sid_source = NULL;
static void *sid_source_user = NULL;

/* ── Envelope helper ────────────────────────────────────────── */
static float envelope_at(float t, float dur,
                          float atk, float dec,
                          float sus, float rel)
{
    float rel_start = dur - rel;
    if (rel_start < atk + dec) rel_start = atk + dec;

    if (t < atk)           return atk > 0.0f ? t / atk : 1.0f;
    if (t < atk + dec) {
        float f = dec > 0.0f ? (t - atk) / dec : 1.0f;
        return 1.0f - (1.0f - sus) * f;
    }
    if (t < rel_start)     return sus;
    if (t < dur) {
        float f = rel > 0.0f ? (t - rel_start) / rel : 1.0f;
        return sus * (1.0f - f);
    }
    return 0.0f;
}

/* ── SDL Audio callback — mixes all active voices ───────────── */
static void audio_callback(void *userdata, uint8_t *stream, int len)
{
    (void)userdata;
    float *out        = (float *)stream;
    int    nsamples   = len / (int)sizeof(float);
    float  dt_ms      = 1000.0f / (float)sample_rate;

    memset(out, 0, (size_t)len);

    for (int vi = 0; vi < SOUND_VOICES; vi++) {
        SoundVoice *v = &voices[vi];
        if (!v->active) continue;

        float step = TWO_PI * v->frequency / (float)sample_rate;

        for (int i = 0; i < nsamples; i++) {
            if (v->time_ms >= v->duration_ms) { v->active = false; break; }

            float env = envelope_at(v->time_ms, v->duration_ms,
                                    v->atk_ms, v->dec_ms,
                                    v->sus_amp, v->rel_ms);
            float s;
            switch (v->waveform) {
            case 1: /* square */
                s = v->phase < PI_F ? 1.0f : -1.0f;
                break;
            case 2: /* sawtooth — falls 1→−1 over 0→2π */
                s = 1.0f - v->phase * INV_PI;
                break;
            case 3: /* triangle — ramps −1→1 then 1→−1 */
                s = (v->phase < PI_F)
                  ? (2.0f * v->phase * INV_PI - 1.0f)
                  : (3.0f - 2.0f * v->phase * INV_PI);
                break;
            case 4: /* noise — xorshift32 LFSR */
                v->noise_state ^= v->noise_state << 13;
                v->noise_state ^= v->noise_state >> 17;
                v->noise_state ^= v->noise_state << 5;
                s = (float)(int32_t)v->noise_state * (1.0f / 2147483648.0f);
                break;
            default: /* 0 = sine */
                s = sinf(v->phase);
                break;
            }
            out[i]    += v->peak * env * s;
            v->phase  += step;
            if (v->phase >= TWO_PI) v->phase -= TWO_PI;
            v->time_ms += dt_ms;
        }
    }

    if (sid_source) {
        for (int i = 0; i < nsamples; i++) {
            out[i] += sid_source(sid_source_user, sample_rate);
        }
    }

    /* hard clip — prevent output overflow when voices stack */
    for (int i = 0; i < nsamples; i++) {
        if      (out[i] >  1.0f) out[i] =  1.0f;
        else if (out[i] < -1.0f) out[i] = -1.0f;
    }
}

/* ── Internal trigger (called with audio device locked) ─────── */
static void trigger_voice(int vi)
{
    SoundVoice *v = &voices[vi];

    uint16_t raw_freq = (uint16_t)v->regs[SOUND_FREQ_LO]
                      | (uint16_t)((uint16_t)v->regs[SOUND_FREQ_HI] << 8);
    uint16_t raw_dur  = (uint16_t)v->regs[SOUND_DUR_LO]
                      | (uint16_t)((uint16_t)v->regs[SOUND_DUR_HI] << 8);

    float freq = raw_freq == 0 ? 440.0f : (float)raw_freq;
    float dur  = raw_dur  == 0 ? 120.0f : (float)raw_dur;

    if (freq < 20.0f)    freq = 20.0f;
    if (freq > 12000.0f) freq = 12000.0f;

    /* 0.25 peak per voice so 4 simultaneous voices clip-free at max volume */
    SDL_LockAudioDevice(audio_device);
    v->frequency   = freq;
    v->duration_ms = dur;
    v->peak        = ((float)v->regs[SOUND_VOL]) / 255.0f * 0.25f;
    v->sus_amp     = ((float)v->regs[SOUND_SUSTAIN]) / 255.0f;
    v->atk_ms      = (float)v->regs[SOUND_ATTACK]  * ADSR_MS_PER_UNIT;
    v->dec_ms      = (float)v->regs[SOUND_DECAY]   * ADSR_MS_PER_UNIT;
    v->rel_ms      = (float)v->regs[SOUND_RELEASE] * ADSR_MS_PER_UNIT;
    v->phase       = 0.0f;
    v->time_ms     = 0.0f;
    v->active      = true;
    v->waveform    = (v->regs[SOUND_CTRL] >> 4) & 0x07u;
    if (!v->noise_state)
        v->noise_state = (uint32_t)(vi + 1) * 0x9E3779B9u;
    SDL_UnlockAudioDevice(audio_device);
}

/* ── Public API ─────────────────────────────────────────────── */

void soundchip_init(void)
{
    if (initialized) return;

    memset(voices, 0, sizeof(voices));
    for (int i = 0; i < SOUND_VOICES; i++) {
        voices[i].regs[SOUND_VOL]     = 200;
        voices[i].regs[SOUND_SUSTAIN] = 255;  /* flat envelope by default */
    }

    if ((SDL_WasInit(SDL_INIT_AUDIO) & SDL_INIT_AUDIO) == 0) {
        if (SDL_WasInit(0) == 0) {
            if (SDL_Init(SDL_INIT_AUDIO) != 0) {
                fprintf(stderr, "soundchip: SDL_Init failed: %s\n", SDL_GetError());
                return;
            }
        } else if (SDL_InitSubSystem(SDL_INIT_AUDIO) != 0) {
            fprintf(stderr, "soundchip: SDL_InitSubSystem failed: %s\n", SDL_GetError());
            return;
        }
    }

    SDL_AudioSpec want, obtained;
    SDL_zero(want);
    want.freq     = SAMPLE_RATE;
    want.format   = AUDIO_F32SYS;
    want.channels = 1;
    want.samples  = 1024;
    want.callback = audio_callback;
    want.userdata = NULL;

    SDL_zero(obtained);
    audio_device = SDL_OpenAudioDevice(NULL, 0, &want, &obtained,
                                       SDL_AUDIO_ALLOW_FREQUENCY_CHANGE |
                                       SDL_AUDIO_ALLOW_SAMPLES_CHANGE);
    if (audio_device == 0) {
        fprintf(stderr, "soundchip: failed to open audio: %s\n", SDL_GetError());
        return;
    }

    sample_rate = obtained.freq > 0 ? obtained.freq : SAMPLE_RATE;
    SDL_PauseAudioDevice(audio_device, 0);
    initialized = 1;
}

/* Legacy convenience wrapper — triggers voice 0 directly */
void soundchip_beep(float frequency, int duration_ms)
{
    if (!initialized || audio_device == 0) return;

    SoundVoice *v = &voices[0];
    uint16_t freq = (uint16_t)(frequency < 20.0f ? 20 :
                               frequency > 12000.0f ? 12000 : (int)frequency);
    uint16_t dur  = (uint16_t)(duration_ms <= 0 ? 120 : duration_ms);
    v->regs[SOUND_FREQ_LO] = (uint8_t)(freq & 0xFF);
    v->regs[SOUND_FREQ_HI] = (uint8_t)(freq >> 8);
    v->regs[SOUND_DUR_LO]  = (uint8_t)(dur  & 0xFF);
    v->regs[SOUND_DUR_HI]  = (uint8_t)(dur  >> 8);
    trigger_voice(0);
}

void soundchip_shutdown(void)
{
    if (!initialized) return;
    SDL_CloseAudioDevice(audio_device);
    audio_device = 0;
    initialized  = 0;
}

void soundchip_set_sid_source(soundchip_sample_source_fn fn, void *user)
{
    sid_source = fn;
    sid_source_user = user;
}

/* ── Bus interface (dev = voice index as uintptr_t) ─────────── */

uint8_t soundchip_voice_read(void *dev, uint16_t offset)
{
    int vi = (int)(uintptr_t)dev;
    if ((unsigned)vi >= SOUND_VOICES)
        return 0xFF;
    if (vi == 0 && offset == SOUND_TIME_MS)
        return (uint8_t)SDL_GetTicks();
    if (offset >= SOUND_REG_COUNT)
        return 0xFF;
    return voices[vi].regs[offset];
}

void soundchip_voice_write(void *dev, uint16_t offset, uint8_t val)
{
    int vi = (int)(uintptr_t)dev;
    if ((unsigned)vi >= SOUND_VOICES || offset >= SOUND_REG_COUNT)
        return;
    voices[vi].regs[offset] = val;
    if (offset == SOUND_CTRL && (val & 0x01u))
        trigger_voice(vi);
}
