#ifndef VIC_H
#define VIC_H

#include <stdint.h>
#include <stdbool.h>

/* ---- Sprite descriptor (shared between vic.c and vic_sdl.c) ---- */
typedef struct {
    uint8_t x, y, flags, color, data_slot;
    uint8_t priority;   /* draw priority 0-255 (higher = on top) */
    uint8_t pad[2];
} VicSprite;

#define SP_FLAG_ENABLE     0x01   /* bit 0: sprite visible */
#define SP_FLAG_SIZE16     0x02   /* bit 1: 16×16 instead of 8×8 */
#define SP_FLAG_FLIPH      0x08   /* bit 3: flip horizontally */
#define SP_FLAG_FLIPV      0x10   /* bit 4: flip vertically */
#define SP_FLAG_XHIBIT     0x80   /* bit 7: X bit 8 (for X 256-319) */
#define SP_FLAG_MULTICOLOR 0x04   /* bit 2: use 2bpp multicolor mode */

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
uint8_t vic_read_bitmap_ram(uint32_t address);

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
uint8_t vic_get_mode_raw(void);
uint8_t vic_get_text_attr_mode(void);

// Cursor control
void vic_set_cursor(uint8_t x, uint8_t y);
void vic_get_cursor(uint8_t* x, uint8_t* y);

// Text-mode color control
void vic_set_text_color(uint8_t color);
uint8_t vic_get_text_color(void);
void vic_set_background_color(uint8_t color);
uint8_t vic_get_background_color(void);

/* C64-compatible VIC-II register block ($D000-$D03F) */
uint8_t vicii_read(void *dev, uint16_t offset);
void vicii_write(void *dev, uint16_t offset, uint8_t val);

// Rendering
void vic_render_screen();

/* ── Blitter bus interface ($8840-$884F) ── */
uint8_t vic_blitter_read(void *dev, uint16_t offset);
void    vic_blitter_write(void *dev, uint16_t offset, uint8_t val);

/* ── Sprite register bus interface ($8850-$888F, 8×8 bytes) ── */
uint8_t vic_sprite_reg_read(void *dev, uint16_t offset);
void    vic_sprite_reg_write(void *dev, uint16_t offset, uint8_t val);

/* ── Sprite pixel data bus interface ($8900-$89FF, 8×32 bytes) ── */
uint8_t vic_sprite_data_read(void *dev, uint16_t offset);
void    vic_sprite_data_write(void *dev, uint16_t offset, uint8_t val);

/* ── Sprite access for renderer ── */
bool       vic_sprites_enabled(void);
VicSprite *vic_get_sprite(int i);
uint8_t    vic_read_sprite_data(uint16_t offset);

/* ── Frame counter (call from renderer each frame) ── */
void vic_increment_frame(void);

/* ── Scrolling ── */
uint8_t vic_get_scroll_x(void);
uint8_t vic_get_scroll_y(void);

/* ── Collision detection ── */
void vic_detect_collisions(const uint8_t sprite_mask[320*200]);

/* ── Interrupt system ── */

/* ISR / IER bit definitions */
#define VIC_IRQ_RASTER  0x01   /* bit 0: raster line compare match */
#define VIC_IRQ_FRAME   0x02   /* bit 1: new frame (vsync) */
#define VIC_IRQ_SS      0x04   /* bit 2: sprite-sprite collision (future) */
#define VIC_IRQ_SB      0x08   /* bit 3: sprite-background collision (future) */

/* Returns true if any enabled interrupt is pending (wire to CPU IRQ line) */
bool vic_irq(void);

#endif // VIC_H
