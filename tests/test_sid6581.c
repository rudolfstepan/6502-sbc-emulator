#include "devices/audio/sid6581_core.h"

#include <assert.h>
#include <stddef.h>
#include <stdio.h>

typedef struct {
    unsigned tick;
    uint8_t reg;
    uint8_t value;
} SidWrite;

int main(void)
{
    /* This trace and checksum were cross-checked with sid6581.vhd in GHDL.
       It exercises the envelope, pulse width, noise, ring/sync, filtering
       and volume DAC, including parameter changes while voices are active. */
    static const SidWrite writes[] = {
        {2, 24, 0x0F}, {3, 1, 0x21}, {4, 3, 0x08},
        {5, 5, 0x21}, {6, 6, 0xB3}, {7, 4, 0x61},
        {8, 8, 0x47}, {9, 13, 0xC3}, {10, 11, 0x81},
        {11, 15, 0x36}, {12, 20, 0xE4}, {13, 18, 0x17},
        {3500, 2, 0x33}, {10000, 22, 0xD0}, {10001, 21, 0x05},
        {10002, 23, 0xE5}, {10003, 24, 0x1F}, {20000, 24, 0x57},
        {22000, 24, 0x3F}, {23000, 18, 0x1F}, {24000, 18, 0x17},
        {26000, 4, 0x60}, {30000, 11, 0x80}, {32000, 18, 0x16},
        {45000, 24, 0x00}, {45010, 24, 0x0F}, {49000, 24, 0x86},
    };

    SID6581Core sid;
    sid6581_reset(&sid);
    assert(sid6581_read(&sid, 0x19) == 0xFF);
    assert(sid6581_read(&sid, 0x1B) == 0);
    uint32_t checksum = UINT32_C(2166136261);
    size_t write = 0;
    for (unsigned tick = 0; tick < 50000; tick++) {
        if (write < sizeof(writes) / sizeof(writes[0]) && writes[write].tick == tick) {
            sid6581_write(&sid, writes[write].reg, writes[write].value);
            write++;
        }
        checksum = (checksum ^ (uint16_t)sid6581_clock(&sid)) * UINT32_C(16777619);
    }
    assert(checksum == UINT32_C(0x5B4E1ED6));
    puts("test_sid6581: 50000 FPGA reference samples matched");
    return 0;
}
