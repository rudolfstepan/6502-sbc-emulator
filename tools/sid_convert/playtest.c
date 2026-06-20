/* playtest.c — run soundsid.rom through the 6502 core and watch the player's
 * 16-bit frame counter (ZP $18/$19) to diagnose looping/restart behaviour.
 * The delay routine is patched to RTS so frames advance fast.
 *
 * gcc -O2 -I src tools/sid_convert/playtest.c src/cpu6502.c src/disasm.c -o tools/sid_convert/playtest
 */
#include "cpu6502.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint8_t MEM[65536];
static uint8_t rd(void *c, uint16_t a){ (void)c; return MEM[a]; }
static void    wr(void *c, uint16_t a, uint8_t v){ (void)c; MEM[a]=v; }

int main(int argc, char**argv)
{
    const char *rom = argc>1?argv[1]:"fpga/sw/soundsid.rom";
    FILE *f=fopen(rom,"rb"); if(!f){perror("open");return 1;}
    fread(&MEM[0xC000],1,16384,f); fclose(f);

    MEM[0xC145]=0x60;   /* patch delay: -> RTS (skip the busy loop) */

    CPU6502 cpu; cpu6502_init(&cpu,rd,wr,NULL);
    cpu.PC = 0xC000; cpu.SP=0xFF; cpu.P=0x24;

    long maxframe=-1, prev=-1, restarts=0; long first_restart_frame=-1;
    for(long i=0;i<200000000L;i++){
        cpu6502_step(&cpu);
        if((i & 0x3FFF)==0){
            long fr = MEM[0x18] | (MEM[0x19]<<8);
            if(fr>maxframe) maxframe=fr;
            if(prev>20 && fr<5){           /* dropped back to ~0 => restart */
                restarts++;
                if(first_restart_frame<0) first_restart_frame=maxframe;
                printf("restart #%ld: frame fell from ~%ld to %ld (max so far %ld)\n",
                       restarts, prev, fr, maxframe);
                if(restarts>=3) break;
            }
            prev=fr;
        }
    }
    printf("done. max frame reached=%ld  (NFRAMES should be ~2900)\n", maxframe);
    if(first_restart_frame>=0)
        printf("FIRST restart after reaching frame ~%ld (%.1f s of music)\n",
               first_restart_frame, first_restart_frame/50.0);
    return 0;
}
