#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bus.h"
#include "cpu6502.h"
#include "rom.h"
#include "sram.h"
#include "via6522.h"
#include "vic.h"

static uint8_t cpu_bus_read(void *ctx, uint16_t addr)
{
    return bus_read((Bus *)ctx, addr);
}

static void cpu_bus_write(void *ctx, uint16_t addr, uint8_t val)
{
    bus_write((Bus *)ctx, addr, val);
}

int main(void)
{
    Bus bus;
    CPU6502 cpu;
    SRAM ram;
    ROM rom;
    VIA6522 via;

    bus_init(&bus);
    vic_init();
    via_init(&via);

    sram_init(&ram, 0x8000);
    rom_load(&rom, "roms/chess.rom", 0x4000);

    bus_register(&bus, "RAM", &ram, 0x0000, 0x8000, sram_read, sram_write, NULL);
    bus_register(&bus, "VIC-VIDEO", NULL, 0x8000, 2048, vic_bus_read, vic_bus_write, vic_bus_tick);
    bus_register(&bus, "VIC-REGS", NULL, 0x9000, 16, vic_reg_read, vic_reg_write, NULL);
    bus_register(&bus, "VIA", &via, 0x8800, 16, via_read, via_write, via_tick);
    bus_register(&bus, "ROM", &rom, 0xC000, 0x4000, rom_read, rom_write, NULL);

    cpu6502_init(&cpu, cpu_bus_read, cpu_bus_write, &bus);
    cpu6502_reset(&cpu);

    // Skip the opening move
    for (int step = 0; step < 1000000; step++) {
        int cycles = cpu6502_step(&cpu);
        bus_tick(&bus, (uint32_t)cycles);
    }

    // Try a different move or just wait longer
    char *input = "D7D5\r";
    for (int i = 0; input[i]; i++) {
        via_keyboard_push(&via, input[i]);
        for (int step = 0; step < 5000000; step++) {
            int cycles = cpu6502_step(&cpu);
            bus_tick(&bus, (uint32_t)cycles);
        }
    }

    for (int step = 0; step < 10000000; step++) {
        int cycles = cpu6502_step(&cpu);
        bus_tick(&bus, (uint32_t)cycles);
    }

    for (int row = 0; row < 25; row++) {
        if ((row >= 0 && row <= 4) || (row >= 17 && row <= 24)) {
            char line[41];
            for (int col = 0; col < 40; col++) {
                uint8_t c = bus_read(&bus, (uint16_t)(0x8000 + row * 40 + col));
                line[col] = (c >= 32 && c <= 126) ? (char)c : ' ';
            }
            line[40] = '\0';
            printf("Row %02d: %s\n", row, line);
        }
    }

    char screen[1001];
    for (int index = 0; index < 1000; index++) {
        uint8_t c = bus_read(&bus, (uint16_t)(0x8000 + index));
        screen[index] = (c >= 32 && c <= 126) ? (char)c : ' ';
    }
    screen[1000] = '\0';

    char *last_eng = NULL;
    char *p = screen;
    while ((p = strstr(p, "ENGINE MOVE "))) {
        last_eng = p;
        p += 12;
    }

    if (last_eng) {
        char move_line[41];
        strncpy(move_line, last_eng, 40);
        move_line[40] = '\0';
        printf("RESULT: %s\n", move_line);
    } else {
        printf("RESULT: NOT FOUND\n");
    }

    return 0;
}
