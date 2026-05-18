#ifndef VIC_H
#define VIC_H

#include <stdint.h>

// Initialize the VIC
void vic_init();

// Bus interface functions (for bus integration)
uint8_t vic_bus_read(void *dev, uint16_t offset);
void vic_bus_write(void *dev, uint16_t offset, uint8_t val);
void vic_bus_tick(void *dev, uint32_t cycles);

// VIC register interface (separate bus device)
uint8_t vic_reg_read(void *dev, uint16_t offset);
void vic_reg_write(void *dev, uint16_t offset, uint8_t val);

// VIC bitmap RAM interface (separate bus device for bitmap data)
uint8_t vic_bitmap_read(void *dev, uint16_t offset);
void vic_bitmap_write(void *dev, uint16_t offset, uint8_t val);

// Video RAM access (dual-port: CPU and VIC can access)
void vic_write_video_ram(uint16_t address, uint8_t data);
uint8_t vic_read_video_ram(uint16_t address);

// Bitmap RAM access (for rendering)
uint8_t vic_read_bitmap_ram(uint16_t address);

// Character ROM access
const uint8_t* vic_get_char_pattern(uint8_t char_code);

// Character output functions
void vic_write_char(char ch);
void vic_write_string(const char* str);

// Screen control
void vic_clear_screen();
void vic_scroll_up();

// Graphics mode control
uint8_t vic_get_graphics_mode(void);  // Returns 0=text, 1=bitmap
void vic_set_graphics_mode(uint8_t mode);

// Cursor control
void vic_set_cursor(uint8_t x, uint8_t y);
void vic_get_cursor(uint8_t* x, uint8_t* y);

// Text-mode color control
void vic_set_text_color(uint8_t color);
uint8_t vic_get_text_color(void);
void vic_set_background_color(uint8_t color);
uint8_t vic_get_background_color(void);

// PETSCII mode control
void vic_set_petscii_mode(uint8_t enabled);
uint8_t vic_get_petscii_mode(void);

// Rendering
void vic_render_screen();

#endif // VIC_H