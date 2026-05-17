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

void vic_sdl_init(void) {}
void vic_sdl_shutdown(void) {}
void vic_sdl_render(uint8_t *bitmap) { (void)bitmap; }
void vic_sdl_handle_events(void) {}

static uint8_t cpu_bus_read(void *ctx, uint16_t addr)
{
    return bus_read((Bus *)ctx, addr);
}

static void cpu_bus_write(void *ctx, uint16_t addr, uint8_t val)
{
    bus_write((Bus *)ctx, addr, val);
}

static uint8_t screen_char(Bus *bus, int row, int col)
{
    return bus_read(bus, (uint16_t)(0x8000 + row * 40 + col));
}

static uint8_t screen_color(Bus *bus, int row, int col)
{
    return bus_read(bus, (uint16_t)(0x8400 + row * 40 + col)) & 0x0F;
}

static uint8_t screen_background(Bus *bus, int row, int col)
{
    return (bus_read(bus, (uint16_t)(0x8400 + row * 40 + col)) >> 4) & 0x0F;
}

static void print_screen_rows(Bus *bus, int start_row, int end_row)
{
    for (int r = start_row; r <= end_row; r++) {
        printf("Row %02d: ", r);
        for (int c = 0; c < 40; c++) {
            uint8_t ch = screen_char(bus, r, c);
            if (ch >= 32 && ch < 127) {
                putchar(ch);
            } else {
                putchar('.');
            }
        }
        printf("\n");
    }
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

    if (sram_init(&ram, 0x8000) != 0) return 1;
    if (rom_load(&rom, "roms/chess.rom", 0x4000) != 0) return 1;

    bus_register(&bus, "SRAM", &ram, 0x0000, 0x8000, sram_read, sram_write, NULL);
    bus_register(&bus, "VIC-VIDEO", NULL, 0x8000, 2048, vic_bus_read, vic_bus_write, vic_bus_tick);
    bus_register(&bus, "VIC-REGS", NULL, 0x9000, 16, vic_reg_read, vic_reg_write, NULL);
    bus_register(&bus, "VIC-BITMAP", NULL, 0x9010, 8000, vic_bitmap_read, vic_bitmap_write, NULL);
    bus_register(&bus, "VIA-6522", &via, 0x8800, 16, via_read, via_write, via_tick);
    bus_register(&bus, "ROM", &rom, 0xC000, 0x4000, rom_read, rom_write, NULL);

    cpu6502_init(&cpu, cpu_bus_read, cpu_bus_write, &bus);
    cpu6502_reset(&cpu);

    for (int step = 0; step < 1000000; step++) {
        int cycles = cpu6502_step(&cpu);
        bus_tick(&bus, (uint32_t)cycles);
    }

    via_keyboard_push(&via, 'h');
    via_keyboard_push(&via, '7');
    via_keyboard_push(&via, 'h');
    via_keyboard_push(&via, '6');
    via_keyboard_push(&via, '\r');

    for (int step = 0; step < 10000000; step++) {
        int cycles = cpu6502_step(&cpu);
        bus_tick(&bus, (uint32_t)cycles);
    }

    printf("--- Rows 1-4 ---\n");
    print_screen_rows(&bus, 1, 4);
    printf("--- Rows 23-24 ---\n");
    print_screen_rows(&bus, 23, 24);

    printf("--- Non-space cells in rows 5-20 ---\n");
    for (int r = 5; r <= 20; r++) {
        for (int c = 0; c < 40; c++) {
            uint8_t ch = screen_char(&bus, r, c);
            if (ch != 0x20) {
                printf("Row: %02d, Col: %02d, Char: 0x%02X, FG: 0x%X, BG: 0x%X\n",
                       r, c, ch, screen_color(&bus, r, c), screen_background(&bus, r, c));
            }
        }
    }

    rom_free(&rom);
    sram_free(&ram);
    return 0;
}
