/* siddump.c — run a PSID tune through the project's 6502 core and dump the
 * SID register state once per frame (50 Hz). Foundation for converting a SID to
 * our FPGA sound chip.
 *
 * Build:  gcc -O2 -I src tools/sid_convert/siddump.c src/cpu6502.c src/disasm.c \
 *             -o tools/sid_convert/siddump
 * Usage:  siddump <file.sid> [seconds] [--raw out.bin]
 *
 * Text output: per frame, for each of the 3 SID voices: frequency in Hz, a
 * waveform letter (T/S/P/N), the gate bit, and ADSR nibbles.
 * --raw writes a compact binary: per frame, 3 voices x {freqLo,freqHi,ctrl,ad,sr}.
 */
#include "cpu6502.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

static uint8_t MEM[65536];

static uint8_t rd(void *ctx, uint16_t a) { (void)ctx; return MEM[a]; }
static void    wr(void *ctx, uint16_t a, uint8_t v) { (void)ctx; MEM[a] = v; }

/* PAL C64 system clock; SID f_out = freqval * CLK / 2^24 */
#define PAL_CLK 985248.0

/* Call a 6502 subroutine at addr via an RTS sentinel: returns when SP unwinds. */
static void call_sub(CPU6502 *cpu, uint16_t addr, uint8_t a)
{
    cpu->A = a; cpu->X = 0; cpu->Y = 0;
    cpu->SP = 0xFF;
    MEM[0x0100 + cpu->SP--] = 0x00;  /* push return hi */
    MEM[0x0100 + cpu->SP--] = 0x00;  /* push return lo -> RTS goes to $0001 */
    cpu->PC = addr;
    cpu->P |= FLAG_I;
    long guard = 0;
    while (cpu->SP != 0xFF && guard++ < 20000000)
        cpu6502_step(cpu);
}

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "usage: %s file.sid [seconds] [--raw out.bin]\n", argv[0]); return 2; }
    const char *path = argv[1];
    double seconds = (argc >= 3 && argv[2][0] != '-') ? atof(argv[2]) : 8.0;
    const char *rawpath = NULL;
    for (int i = 2; i < argc; i++)
        if (!strcmp(argv[i], "--raw") && i + 1 < argc) rawpath = argv[i + 1];

    FILE *f = fopen(path, "rb");
    if (!f) { perror("open"); return 1; }
    uint8_t hdr[0x7e];
    fread(hdr, 1, sizeof(hdr), f);
    int dataOff  = (hdr[6] << 8) | hdr[7];
    int loadAddr = (hdr[8] << 8) | hdr[9];
    int initAddr = (hdr[10] << 8) | hdr[11];
    int playAddr = (hdr[12] << 8) | hdr[13];
    int songs    = (hdr[14] << 8) | hdr[15];
    int startSong= (hdr[16] << 8) | hdr[17];

    fseek(f, dataOff, SEEK_SET);
    uint8_t body[65536];
    int n = (int)fread(body, 1, sizeof(body), f);
    fclose(f);

    int off = 0;
    if (loadAddr == 0) { loadAddr = body[0] | (body[1] << 8); off = 2; }
    memcpy(&MEM[loadAddr], &body[off], n - off);

    printf("load=$%04X init=$%04X play=$%04X songs=%d start=%d  bytes=%d\n",
           loadAddr, initAddr, playAddr, songs, startSong, n - off);

    CPU6502 cpu;
    cpu6502_init(&cpu, rd, wr, NULL);
    cpu6502_reset(&cpu);
    call_sub(&cpu, initAddr, (uint8_t)(startSong - 1));

    int frames = (int)(seconds * 50.0 + 0.5);
    FILE *raw = rawpath ? fopen(rawpath, "wb") : NULL;

    const char wf[] = "?TS?P?N?";  /* index by (ctrl>>4)&7-ish; printed manually */
    (void)wf;

    for (int fr = 0; fr < frames; fr++) {
        call_sub(&cpu, playAddr, 0);

        uint8_t reg[0x19];
        memcpy(reg, &MEM[0xD400], sizeof(reg));

        if (raw) {
            for (int v = 0; v < 3; v++) {
                uint8_t *b = &reg[v * 7];
                uint8_t out[5] = { b[0], b[1], b[4], b[5], b[6] };
                fwrite(out, 1, 5, raw);
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
    if (raw) { fclose(raw); printf("raw frames -> %s (%d frames x 15 bytes)\n", rawpath, frames); }
    return 0;
}
