#ifndef C64_H
#define C64_H

#include <stdbool.h>
#include <stdint.h>

#include "cia6526.h"
#include "sid_stub.h"

#define C64_RAM_SIZE 0x10000u
#define C64_PAL_CPU_HZ 985248u
#define C64_VIDEO_WIDTH 320
#define C64_VIDEO_HEIGHT 200

typedef struct {
    uint8_t ram[C64_RAM_SIZE];
    uint8_t basic[0x2000];
    uint8_t kernal[0x2000];
    uint8_t chargen[0x1000];
    uint8_t color_ram[0x400];
    uint8_t vic_regs[0x40];
    uint8_t keyboard[8];
    uint8_t joystick[2];      /* Pressed CIA1 bits for ports 1 and 2. */
    bool restore_pressed;
    uint8_t cpu_port_direction;
    uint8_t cpu_port_data;
    uint16_t raster_line;
    uint32_t raster_cycle;
    uint8_t video_frames[2][C64_VIDEO_HEIGHT][C64_VIDEO_WIDTH];
    uint8_t video_draw_frame;
    uint8_t matrix_codes[40];
    uint8_t matrix_colors[40];
    uint16_t matrix_base;
    uint8_t graphics_row;
    bool display_enabled;
    bool graphics_active;
    bool bad_line;
    bool vertical_border_open;
    uint8_t sprite_active;
    uint8_t sprite_expand_phase;
    uint8_t sprite_rows[8];
    CIA6526 cia1;
    CIA6526 cia2;
    SIDStub sid;
} C64;

/* Load three exact-size ROM images and initialize the PAL machine. */
bool c64_init(C64 *c64, const char *basic, const char *kernal, const char *chargen);

uint8_t c64_read(void *machine, uint16_t addr);
void c64_write(void *machine, uint16_t addr, uint8_t value);
void c64_tick(void *machine, uint32_t cycles);
bool c64_irq(const C64 *c64);
bool c64_nmi(const C64 *c64);

/* Matrix indices are CIA1 port A bit * 8 + CIA1 port B bit. */
void c64_set_key(C64 *c64, unsigned int index);
void c64_clear_keys(C64 *c64);
uint16_t c64_video_bank(const C64 *c64);
uint8_t c64_video_read(const C64 *c64, uint16_t addr);

#endif
