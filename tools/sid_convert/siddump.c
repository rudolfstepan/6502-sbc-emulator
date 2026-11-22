/* siddump.c — run a PSID tune through the project's 6502 core and dump the
 * SID register state once per frame (50 Hz). Foundation for converting a SID to
 * our FPGA sound chip.
 *
 * Build:  gcc -O2 -I src tools/sid_convert/siddump.c src/core/cpu/cpu6502.c src/core/cpu/disasm.c \
 *             -o tools/sid_convert/siddump
 * Usage:  siddump <file.sid> [seconds] [--raw out.bin] [--song N]
 *
 * Text output: per frame, for each of the 3 SID voices: frequency in Hz, a
 * waveform letter (T/S/P/N), the gate bit, and ADSR nibbles.
 * --raw writes a compact binary: per frame, 3 voices x {freqLo,freqHi,ctrl,ad,sr}.
 */
#include "core/cpu/cpu6502.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

static uint8_t MEM[65536];

static uint8_t rd(void *ctx, uint16_t a) { (void)ctx; return MEM[a]; }
static void    wr(void *ctx, uint16_t a, uint8_t v) { (void)ctx; MEM[a] = v; }

/* PAL C64 system clock; SID f_out = freqval * CLK / 2^24 */
#define PAL_CLK 985248.0

enum {
    PSID_V1_HEADER_SIZE = 0x76,
    PSID_HEADER_SIZE = 0x7C,
    SID_FRAME_RATE = 50,
    MAX_SECONDS = 300,
    MAX_SUBROUTINE_STEPS = 1000000
};

typedef struct {
    unsigned load;
    unsigned init;
    unsigned play;
    unsigned songs;
    unsigned song;
    size_t size;
} SidTune;

static unsigned be16(const uint8_t *bytes)
{
    return ((unsigned)bytes[0] << 8) | bytes[1];
}

static const char *load_sid(FILE *file, SidTune *tune, unsigned requested_song)
{
    uint8_t header[PSID_HEADER_SIZE];
    if (fread(header, 1, PSID_V1_HEADER_SIZE, file) != PSID_V1_HEADER_SIZE ||
        memcmp(header, "PSID", 4) != 0) {
        return "expected a PSID file";
    }
    unsigned version = be16(header + 4);
    if (version < 1 || version > 4) {
        return "unsupported PSID version";
    }
    unsigned header_size = version == 1 ? PSID_V1_HEADER_SIZE : PSID_HEADER_SIZE;
    size_t extension_size = header_size - PSID_V1_HEADER_SIZE;
    if (fread(header + PSID_V1_HEADER_SIZE, 1, extension_size, file) != extension_size) {
        return "incomplete PSID header";
    }
    if (version > 1) {
        unsigned flags = be16(header + 0x76);
        if ((flags & 3) != 0 || ((flags >> 2) & 3) == 2 ||
            (version >= 3 && header[0x7A]) || (version >= 4 && header[0x7B])) {
            return "only standard PAL tunes for a single SID are supported";
        }
    }

    tune->load = be16(header + 8);
    tune->init = be16(header + 10);
    tune->play = be16(header + 12);
    tune->songs = be16(header + 14);
    unsigned start_song = be16(header + 16);
    if (tune->songs == 0 || tune->songs > 256 ||
        start_song == 0 || start_song > tune->songs) {
        return "invalid PSID subtune count or default";
    }
    if (requested_song > tune->songs) {
        return "subtune number exceeds the number of subtunes in the SID";
    }
    tune->song = requested_song ? requested_song : start_song;
    unsigned speed_bit = tune->song > 32 ? 31 : tune->song - 1;
    uint32_t speed = ((uint32_t)be16(header + 18) << 16) | be16(header + 20);
    if ((speed & (UINT32_C(1) << speed_bit)) || !tune->play) {
        return "the subtune must use PAL VBI timing and specify a play address";
    }

    unsigned data_offset = be16(header + 6);
    if (data_offset < header_size || fseek(file, (long)data_offset, SEEK_SET) != 0) {
        return "invalid PSID data offset";
    }
    if (!tune->load) {
        int low = fgetc(file);
        int high = fgetc(file);
        if (low == EOF || high == EOF) {
            return "missing PSID load address";
        }
        tune->load = (unsigned)low | ((unsigned)high << 8);
    }
    if (!tune->init) {
        tune->init = tune->load;
    }
    tune->size = fread(MEM + tune->load, 1, sizeof(MEM) - tune->load, file);
    if (tune->size == 0 || fgetc(file) != EOF || ferror(file)) {
        return "PSID data is empty, unreadable, or exceeds 64 KiB of C64 memory";
    }
    return NULL;
}

/* Push a return address so an RTS ends this host-initiated call at $0001. */
static bool call_sub(CPU6502 *cpu, uint16_t address, uint8_t accumulator)
{
    cpu->A = accumulator;
    cpu->X = cpu->Y = 0;
    cpu->SP = 0xFD;
    MEM[0x01FE] = MEM[0x01FF] = 0;
    cpu->PC = address;
    cpu->P |= FLAG_I;
    for (unsigned step = 0; step < MAX_SUBROUTINE_STEPS && !cpu->stopped; step++) {
        cpu6502_step(cpu);
        if (cpu->PC == 1 && cpu->SP == 0xFF) {
            return true;
        }
    }
    return false;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s file.sid [seconds] [--raw out.bin] [--song N]\n", argv[0]);
        return 2;
    }
    const char *path = argv[1];
    double seconds = 8.0;
    const char *raw_path = NULL;
    unsigned song = 0;
    int arg = 2;
    if (arg < argc && argv[arg][0] != '-') {
        char *end;
        seconds = strtod(argv[arg], &end);
        if (end == argv[arg] || *end || !(seconds >= 0.02 && seconds <= MAX_SECONDS)) {
            fprintf(stderr, "duration must be between 0.02 and %d seconds\n", MAX_SECONDS);
            return 2;
        }
        arg++;
    }
    while (arg < argc) {
        if (strcmp(argv[arg], "--raw") == 0 && arg + 1 < argc && !raw_path) {
            raw_path = argv[arg + 1];
        } else if (strcmp(argv[arg], "--song") == 0 && arg + 1 < argc && !song) {
            char *end;
            unsigned long parsed = strtoul(argv[arg + 1], &end, 10);
            if (end == argv[arg + 1] || *end || parsed == 0 || parsed > 256) {
                fprintf(stderr, "subtune must be between 1 and 256\n");
                return 2;
            }
            song = (unsigned)parsed;
        } else {
            fprintf(stderr, "invalid argument: %s\n", argv[arg]);
            return 2;
        }
        arg += 2;
    }

    FILE *file = fopen(path, "rb");
    if (!file) {
        perror(path);
        return 1;
    }
    SidTune tune;
    const char *error = load_sid(file, &tune, song);
    fclose(file);
    if (error) {
        fprintf(stderr, "%s: %s\n", path, error);
        return 1;
    }
    printf("load=$%04X init=$%04X play=$%04X song=%u/%u bytes=%zu\n",
           tune.load, tune.init, tune.play, tune.song, tune.songs, tune.size);

    CPU6502 cpu;
    cpu6502_init(&cpu, rd, wr, NULL);
    cpu.nmos_rmw_writes = true;
    if (!call_sub(&cpu, (uint16_t)tune.init, (uint8_t)(tune.song - 1))) {
        fprintf(stderr, "SID init routine did not return\n");
        return 1;
    }

    int frames = (int)(seconds * SID_FRAME_RATE + 0.5);
    FILE *raw = raw_path ? fopen(raw_path, "wb") : NULL;
    if (raw_path && !raw) {
        perror(raw_path);
        return 1;
    }
    int result = 0;

    for (int fr = 0; fr < frames; fr++) {
        if (!call_sub(&cpu, (uint16_t)tune.play, 0)) {
            fprintf(stderr, "SID play routine did not return at frame %d\n", fr);
            result = 1;
            break;
        }

        uint8_t reg[0x19];
        memcpy(reg, &MEM[0xD400], sizeof(reg));

        if (raw) {
            for (int v = 0; v < 3; v++) {
                uint8_t *b = &reg[v * 7];
                uint8_t out[5] = { b[0], b[1], b[4], b[5], b[6] };
                if (fwrite(out, 1, sizeof(out), raw) != sizeof(out)) {
                    perror(raw_path);
                    fclose(raw);
                    return 1;
                }
            }
        }

        if (fr < 250 || (fr % 50) == 0) {  /* print first 5 s densely, then 1/s */
            printf("%4d:", fr);
            for (int v = 0; v < 3; v++) {
                uint8_t *b = &reg[v * 7];
                int fv  = b[0] | (b[1] << 8);
                double hz = fv * PAL_CLK / 16777216.0;
                int ctrl = b[4];
                char w = ctrl & 0x80 ? 'N' : ctrl & 0x40 ? 'P' : ctrl & 0x20 ? 'S' : ctrl & 0x10 ? 'T' : '-';
                int gate = ctrl & 1;
                int atk = b[5] >> 4, dec = b[5] & 15, sus = b[6] >> 4, rel = b[6] & 15;
                printf("  V%d %6.1fHz %c g%d A%X D%X S%X R%X", v, hz, w, gate, atk, dec, sus, rel);
            }
            printf("\n");
        }
    }
    if (raw && fclose(raw) != 0) {
        perror(raw_path);
        return 1;
    }
    if (raw_path && result == 0) {
        printf("raw frames -> %s (%d frames x 15 bytes)\n", raw_path, frames);
    }
    return result;
}
