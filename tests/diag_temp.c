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

static uint8_t cpu_bus_read(void *ctx, uint16_t addr) { return bus_read((Bus *)ctx, addr); }
static void cpu_bus_write(void *ctx, uint16_t addr, uint8_t val) { bus_write((Bus *)ctx, addr, val); }

void print_row(Bus *bus, int row) {
    if (row < 0 || row > 24) return;
    printf("Row %02d: ", row + 1);
    for (int col = 0; col < 40; col++) {
        uint8_t c = bus_read(bus, 0x8000 + row * 40 + col);
        if (c >= 32 && c < 127) putchar(c);
        else if (c == 0x20) putchar(' ');
        else putchar('.');
    }
    printf("\n");
}

int main(void) {
    Bus bus; CPU6502 cpu; SRAM ram; ROM rom; VIA6522 via;
    bus_init(&bus); vic_init(); via_init(via_init(&via);via); global_via = &via;
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

    for (int i = 0; i < 600000; i++) {
        int cycles = cpu6502_step(&cpu);
        bus_tick(&bus, (uint32_t)cycles);
    }

    via_keyboard_push(&via, 'h');
    via_keyboard_push(&via, '7');
    via_keyboard_push(&via, 'h');
    via_keyboard_push(&via, '6');
    via_keyboard_push(&via, '\r');

    for (int i = 0; i < 2000000; i++) {
        int cycles = cpu6502_step(&cpu);
        bus_tick(&bus, (uint32_t)cycles);
    }

    print_row(&bus, 0); print_row(&bus, 1); print_row(&bus, 22); print_row(&bus, 23);
    
    uint8_t ch = bus_read(&bus, 0x8000 + 6 * 40 + 16);
    uint8_t attr = bus_read(&bus, 0x8400 + 6 * 40 + 16);
    printf("Cell (16,6): Char=0x%02X, FG=0x%X, BG=0x%X\n", ch, attr & 0xF, (attr >> 4) & 0xF);

    // Microchess board usually at 0x50-0x5F or similar.
    // Based on test_chess_rom.c squares: 6,6 is H1 (approx), 20,6 is H8 (approx).
    // Let's print some zero-page variables that might be board/status.
    printf("Internal Board state (guessed locations):\n");
    printf("H7: 0x%02X\n", bus_read(&bus, 0x0056));
    printf("H6: 0x%02X\n", bus_read(&bus, 0x0055));
    printf("C1: 0x%02X\n", bus_read(&bus, 0x0050));
    
    return 0;
}
VIA6522* global_via;
VIA6522* get_keyboard_via(void) { return global_via; }
