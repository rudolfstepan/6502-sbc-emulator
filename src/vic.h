#ifndef VIC_H
#define VIC_H

#include <stdint.h>

// Initialize the VIC
void vic_init();

// Bus interface functions (for bus integration)
uint8_t vic_bus_read(void *dev, uint16_t offset);
void vic_bus_write(void *dev, uint16_t offset, uint8_t val);
void vic_bus_tick(void *dev, uint32_t cycles);

// Video RAM access (dual-port: CPU and VIC can access)
void vic_write_video_ram(uint16_t address, uint8_t data);
uint8_t vic_read_video_ram(uint16_t address);

// Character ROM access
const uint8_t* vic_get_char_pattern(uint8_t char_code);

// Character output functions
void vic_write_char(char ch);
void vic_write_string(const char* str);

// Screen control
void vic_clear_screen();
void vic_scroll_up();

// Cursor control
void vic_set_cursor(uint8_t x, uint8_t y);
void vic_get_cursor(uint8_t* x, uint8_t* y);

// Rendering
void vic_render_screen();

#endif // VIC_H