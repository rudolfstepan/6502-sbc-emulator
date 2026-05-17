#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "src/bus.h"
#include "src/cpu6502.h"
#include "src/rom.h"
#include "src/sram.h"
#include "src/via6522.h"
#include "src/vic.h"

static uint8_t cpu_bus_read(void *ctx, uint16_t addr)
{
    return bus_read((Bus *)ctx, addr);
}

static void cpu_bus_write(void *ctx, uint16_t addr, uint8_t val)
{
    bus_write((Bus *)ctx, addr, val);
}

static uint8_t screen_color(Bus *bus, int row, int col)
{
    return bus_read(bus, (uint16_t)(0x8400 + row * 40 + col)) & 0x0F;
}

static uint8_t screen_background(Bus *bus, int row, int col)
{
    return (bus_read(bus, (uint16_t)(0x8400 + row * 40 + col)) >> 4) & 0x0F;
}

static uint8_t screen_char(Bus *bus, int row, int col)
{
    return bus_read(bus, (uint16_t)(0x8000 + row * 40 + col));
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

    if (sram_init(&ram, 0x8000) != 0) {
        return 1;
    }

    if (rom_load(&rom, "roms/chess.rom", 0x4000) != 0) {
        sram_free(&ram);
        return 1;
    }

    bus_register(&bus, "SRAM", &ram, 0x0000, 0x8000, sram_read, sram_write, NULL);
    bus_register(&bus, "VIC-VIDEO", NULL, 0x8000, 2048, vic_bus_read, vic_bus_write, vic_bus_tick);
    bus_register(&bus, "VIC-REGS", NULL, 0x9000, 16, vic_reg_read, vic_reg_write, NULL);
    bus_register(&bus, "VIC-BITMAP", NULL, 0x9010, 8000, vic_bitmap_read, vic_bitmap_write, NULL);
    bus_register(&bus, "VIA-6522", &via, 0x8800, 16, via_read, via_write, via_tick);
    bus_register(&bus, "ROM", &rom, 0xC000, 0x4000, rom_read, rom_write, NULL);

    cpu6502_init(&cpu, cpu_bus_read, cpu_bus_write, &bus);
    cpu6502_reset(&cpu);

    for (int step = 0; step < 2000000; step++) {
        int cycles = cpu6502_step(&cpu);
        bus_tick(&bus, (uint32_t)cycles);
    }

    via_keyboard_push(&via, 'd');
    via_keyboard_push(&via, '7');
    via_keyboard_push(&via, 'd');
    via_keyboard_push(&via, '5');
    via_keyboard_push(&via, '\r');

    for (int step = 0; step < 5000000; step++) {
        int cycles = cpu6502_step(&cpu);
        bus_tick(&bus, (uint32_t)cycles);
    }

    for (int r = 0; r < 4; r++) {
        printf("Row %d: ", r + 1);
        for (int c = 0; c < 40; c++) {
            uint8_t ch = screen_char(&bus, r, c);
            putchar(ch ? ch : ' ');
        }
        putchar('\n');
    }

    for (int r = 22; r < 24; r++) {
        printf("Row %d: ", r + 1);
        for (int c = 0; c < 40; c++) {
            uint8_t ch = screen_char(&bus, r, c);
            putchar(ch ? ch : ' ');
        }
        putchar('\n');
    }

    for (int r = 4; r < 20; r++) {
        for (int c = 0; c < 40; c++) {
            uint8_t ch = screen_char(&bus, r, c);
            if (ch != ' ' && ch != 0) {
                printf("Row %d, Col %d: Char=0x%02X, FG=%d, BG=%d\n", 
                       r + 1, c + 1, ch, screen_color(&bus, r, c), screen_background(&bus, r, c));
            }
        }
    }

    rom_free(&rom);
    sram_free(&ram);
    return 0;
}
