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

static bool screen_contains(Bus *bus, const char *needle)
{
    char screen[1001];

    for (int index = 0; index < 1000; index++) {
        screen[index] = (char)bus_read(bus, (uint16_t)(0x8000 + index));
    }
    screen[1000] = '\0';

    return strstr(screen, needle) != NULL;
}

static uint8_t screen_color(Bus *bus, int row, int col)
{
    return bus_read(bus, (uint16_t)(0x8400 + row * 40 + col)) & 0x0F;
}

static uint8_t screen_background(Bus *bus, int row, int col)
{
    return (bus_read(bus, (uint16_t)(0x8400 + row * 40 + col)) >> 4) & 0x0F;
}

int main(void)
{
    Bus bus;
    CPU6502 cpu;
    SRAM ram;
    ROM rom;
    VIA6522 via;
    uint16_t last_pc = 0xffff;
    int same_pc_count = 0;

    bus_init(&bus);
    vic_init();
    via_init(&via);

    if (sram_init(&ram, 0x8000) != 0) {
        fprintf(stderr, "failed to init SRAM\n");
        return 1;
    }

    if (rom_load(&rom, "roms/chess.rom", 0x4000) != 0) {
        fprintf(stderr, "failed to load roms/chess.rom\n");
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

    for (int step = 0; step < 300000; step++) {
        int cycles = cpu6502_step(&cpu);
        bus_tick(&bus, (uint32_t)cycles);

        if (cpu.PC == last_pc) {
            same_pc_count++;
        } else {
            last_pc = cpu.PC;
            same_pc_count = 0;
        }

        if (same_pc_count > 16) {
            break;
        }
    }

    if (!screen_contains(&bus, "SBC6502 CHESS")) {
        fprintf(stderr, "title not found in VIC output\n");
        rom_free(&rom);
        sram_free(&ram);
        return 1;
    }

    if (!screen_contains(&bus, "ENGINE MOVE ")) {
        fprintf(stderr, "move banner not found in VIC output\n");
        rom_free(&rom);
        sram_free(&ram);
        return 1;
    }

    if (!screen_contains(&bus, "TYPE MOVE LIKE E7E5")) {
        fprintf(stderr, "demo banner not found in VIC output\n");
        rom_free(&rom);
        sram_free(&ram);
        return 1;
    }

    if (!screen_contains(&bus, "A   B   C   D   E   F   G   H")) {
        fprintf(stderr, "file labels not found in VIC output\n");
        rom_free(&rom);
        sram_free(&ram);
        return 1;
    }

    if (!screen_contains(&bus, "MOVE> ____")) {
        fprintf(stderr, "move prompt not found in VIC output\n");
        rom_free(&rom);
        sram_free(&ram);
        return 1;
    }

    if (!screen_contains(&bus, "8 | R | N | B | Q | K | B | N | R | 8")) {
        fprintf(stderr, "expected board row not found in VIC output\n");
        rom_free(&rom);
        sram_free(&ram);
        return 1;
    }

    if (screen_color(&bus, 6, 6) != 0x00) {
        fprintf(stderr, "expected black rook cell color not found\n");
        rom_free(&rom);
        sram_free(&ram);
        return 1;
    }

    if (screen_color(&bus, 20, 6) != 0x01) {
        fprintf(stderr, "expected white rook cell color not found\n");
        rom_free(&rom);
        sram_free(&ram);
        return 1;
    }

    if (screen_background(&bus, 6, 6) == screen_background(&bus, 6, 10)) {
        fprintf(stderr, "expected alternating board square backgrounds not found\n");
        rom_free(&rom);
        sram_free(&ram);
        return 1;
    }

    via_keyboard_push(&via, 'e');
    via_keyboard_push(&via, '7');
    via_keyboard_push(&via, 'e');
    via_keyboard_push(&via, '5');
    via_keyboard_push(&via, '\r');

    for (int step = 0; step < 300000; step++) {
        int cycles = cpu6502_step(&cpu);
        bus_tick(&bus, (uint32_t)cycles);
    }

    if (!screen_contains(&bus, "MOVE> ____")) {
        fprintf(stderr, "move prompt missing after player move\n");
        rom_free(&rom);
        sram_free(&ram);
        return 1;
    }

    if (!screen_contains(&bus, "ENGINE MOVE D4-E5")) {
        fprintf(stderr, "expected engine response move not found in VIC output\n");
        rom_free(&rom);
        sram_free(&ram);
        return 1;
    }

    if (!screen_contains(&bus, "7 | P | P | P | P |   | P | P | P | 7")) {
        fprintf(stderr, "expected cleared E7 square not found in VIC output\n");
        rom_free(&rom);
        sram_free(&ram);
        return 1;
    }

    if (!screen_contains(&bus, "5 |   |   |   |   | P |   |   |   | 5")) {
        fprintf(stderr, "expected white pawn on E5 not found in VIC output\n");
        rom_free(&rom);
        sram_free(&ram);
        return 1;
    }

    if (screen_color(&bus, 12, 22) != 0x01) {
        fprintf(stderr, "expected white pawn color on E5 not found\n");
        rom_free(&rom);
        sram_free(&ram);
        return 1;
    }

    rom_free(&rom);
    sram_free(&ram);
    puts("test_chess_rom: ok");
    return 0;
}