#ifndef SOUNDCHIP_H
#define SOUNDCHIP_H

#include <stdint.h>

/*
 * 4-Voice Sound Chip with ADSR Envelopes
 *
 * Each voice has 10 registers at its base address:
 *
 *  +0  FREQ_LO     frequency low byte
 *  +1  FREQ_HI     frequency high byte  (Hz, 20–12000)
 *  +2  DUR_LO      duration low byte
 *  +3  DUR_HI      duration high byte   (ms)
 *  +4  VOLUME      peak amplitude       (0–255)
 *  +5  CONTROL     bits 6-4 = waveform (0=sine 1=square 2=sawtooth 3=triangle 4=noise)
 *                  bit    0 = trigger note
 *  +6  ATTACK      attack time          (0–255, units of 8 ms → 0..2040 ms)
 *  +7  DECAY       decay time           (0–255, units of 8 ms)
 *  +8  SUSTAIN     sustain level        (0–255, fraction of VOLUME peak)
 *  +9  RELEASE     release time         (0–255, units of 8 ms)
 *
 * Voice base addresses:
 *  Voice 0:  $8830  (backward-compatible)
 *  Voice 1:  $8890
 *  Voice 2:  $889A
 *  Voice 3:  $88A4
 *
 * All 4 voices are mixed in real-time by an SDL audio callback.
 * Maximum simultaneous amplitude: 4 × (VOLUME/255 × 0.25) ≤ 1.0
 */

#define SOUND_VOICES    4
#define SOUND_REG_COUNT 10

/* Voice base addresses (for memory-map documentation / assembly code) */
#define SOUND_VOICE0_BASE  0x8830U
#define SOUND_VOICE1_BASE  0x8890U
#define SOUND_VOICE2_BASE  0x889AU
#define SOUND_VOICE3_BASE  0x88A4U

enum {
    SOUND_FREQ_LO = 0,
    SOUND_FREQ_HI = 1,
    SOUND_DUR_LO  = 2,
    SOUND_DUR_HI  = 3,
    SOUND_VOL     = 4,
    SOUND_CTRL    = 5,
    SOUND_ATTACK  = 6,
    SOUND_DECAY   = 7,
    SOUND_SUSTAIN = 8,
    SOUND_RELEASE = 9,
};

void    soundchip_init(void);
void    soundchip_beep(float frequency, int duration_ms); /* legacy: triggers voice 0 */
void    soundchip_shutdown(void);

/* Bus callbacks — pass voice index (0–3) as dev pointer */
uint8_t soundchip_voice_read(void *dev, uint16_t offset);
void    soundchip_voice_write(void *dev, uint16_t offset, uint8_t val);

#endif /* SOUNDCHIP_H */
