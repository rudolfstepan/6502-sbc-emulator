#include "vic.h"
#include "bus.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// Video RAM size and base address
#define VIDEO_RAM_SIZE 2048   // 2KB for text mode
#define TEXT_RAM_SIZE 2048    // 2KB for 40x25 text mode
#define BITMAP_WINDOW_SIZE 8192
#define LEGACY_BITMAP_RAM_SIZE 8000
#define BITMAP_RAM_SIZE (640 * 400)  // Largest Tang DDR3 bitmap mode: 640x400 8bpp
#define TEXT_CELL_COUNT (VIC_SCREEN_COLS * VIC_SCREEN_ROWS)
#define COLOR_RAM_OFFSET 1024

#define VIDEO_RAM_BASE 0x8000

// Character ROM base address
#define CHAR_ROM_BASE 0x9000

// VIC registers
#define VIC_SCREEN_COLS 40
#define VIC_SCREEN_ROWS 25
#define VIC_DEFAULT_CYCLES_PER_LINE 2252u  /* 27 MHz / 59.94 Hz / 200 logical lines */

// VIC Bitmap mode
#define VIC_BITMAP_WIDTH 320
#define VIC_BITMAP_HEIGHT 200

// Video RAM (dual-port RAM)
static uint8_t video_ram[VIDEO_RAM_SIZE];    // Text mode: 2KB
static uint8_t bitmap_ram[BITMAP_RAM_SIZE];
static uint8_t vicii_regs[0x40];

static uint8_t vic_frame_lo = 0;  /* incremented by renderer each frame */

// VIC control registers
static struct {
    uint8_t enabled;
    uint8_t graphics_mode;  // 0=text, 1=bitmap
    uint16_t cursor_x;
    uint16_t cursor_y;
    uint8_t text_color;
    uint8_t background_color;
    uint8_t text_attr_mode;
    uint8_t bitmap_bank_ext;

    /* Interrupt system */
    uint8_t  irq_status;       /* ISR: pending interrupt flags */
    uint8_t  irq_enable;       /* IER: enabled interrupt sources */
    uint8_t  raster_compare;   /* raster line that triggers RASTER irq */
    uint8_t  raster_line;      /* current raster line (0..VIC_BITMAP_HEIGHT-1) */
    uint16_t cycles_per_line;  /* CPU cycles per logical raster line */
    uint32_t raster_cycle_acc; /* accumulated cycles within current line */

    /* Scrolling */
    uint8_t  scroll_x;         /* fine scroll X: 0-7 pixels left shift */
    uint8_t  scroll_y;         /* fine scroll Y: 0-7 pixels up shift */

    /* Collision detection */
    uint8_t  ss_collision;     /* sprite-sprite collision bitmask */
    uint8_t  sb_collision;     /* sprite-background collision bitmask */
} vic_state;

static uint8_t default_text_attr(void)
{
    return (uint8_t)(((vic_state.background_color & 0x0F) << 4) |
                     (vic_state.text_color & 0x0F));
}

static void refresh_text_attr_foreground(void)
{
    uint8_t * restrict ap = video_ram + COLOR_RAM_OFFSET;
    const uint8_t fg = vic_state.text_color & 0x0F;
    for (int i = 0; i < TEXT_CELL_COUNT; i++)
        ap[i] = (uint8_t)((ap[i] & 0xF0) | fg);
}

static void refresh_text_attr_background(void)
{
    uint8_t * restrict ap = video_ram + COLOR_RAM_OFFSET;
    const uint8_t bg = (uint8_t)((vic_state.background_color & 0x0F) << 4);
    for (int i = 0; i < TEXT_CELL_COUNT; i++)
        ap[i] = (uint8_t)(bg | (ap[i] & 0x0F));
}

// Character ROM (8x8 pixel font for 256 ASCII characters)
// Font data is LSB-first (bit 0 = leftmost pixel)
static const uint8_t char_rom[256][8] = {
    // ASCII 0x00 - 0x1F: Control characters (empty patterns)
    [0x00 ... 0x1F] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},

    // ASCII 0x20: Space
    [0x20] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},

    // ASCII 0x21-0x7E: Printable characters
    [0x21] = {0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x18, 0x00}, // !
    [0x22] = {0x36, 0x36, 0x36, 0x00, 0x00, 0x00, 0x00, 0x00}, // "
    [0x23] = {0x36, 0x36, 0x7F, 0x36, 0x7F, 0x36, 0x36, 0x00}, // #
    [0x24] = {0x0C, 0x3E, 0x03, 0x1E, 0x30, 0x1F, 0x0C, 0x00}, // $
    [0x25] = {0x00, 0x63, 0x33, 0x18, 0x0C, 0x66, 0x63, 0x00}, // %
    [0x26] = {0x1C, 0x36, 0x1C, 0x6E, 0x3B, 0x33, 0x6E, 0x00}, // &
    [0x27] = {0x0C, 0x0C, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00}, // '
    [0x28] = {0x18, 0x0C, 0x06, 0x06, 0x06, 0x0C, 0x18, 0x00}, // (
    [0x29] = {0x06, 0x0C, 0x18, 0x18, 0x18, 0x0C, 0x06, 0x00}, // )
    [0x2A] = {0x00, 0x66, 0x3C, 0xFF, 0x3C, 0x66, 0x00, 0x00}, // *
    [0x2B] = {0x00, 0x0C, 0x0C, 0x3F, 0x0C, 0x0C, 0x00, 0x00}, // +
    [0x2C] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C, 0x06}, // ,
    [0x2D] = {0x00, 0x00, 0x00, 0x3F, 0x00, 0x00, 0x00, 0x00}, // -
    [0x2E] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C, 0x00}, // .
    [0x2F] = {0x60, 0x30, 0x18, 0x0C, 0x06, 0x03, 0x01, 0x00}, // /
    [0x30] = {0x3E, 0x63, 0x73, 0x7B, 0x6F, 0x67, 0x3E, 0x00}, // 0
    [0x31] = {0x0C, 0x0E, 0x0C, 0x0C, 0x0C, 0x0C, 0x3F, 0x00}, // 1
    [0x32] = {0x1E, 0x33, 0x30, 0x1C, 0x06, 0x33, 0x3F, 0x00}, // 2
    [0x33] = {0x1E, 0x33, 0x30, 0x1C, 0x30, 0x33, 0x1E, 0x00}, // 3
    [0x34] = {0x38, 0x3C, 0x36, 0x33, 0x7F, 0x30, 0x78, 0x00}, // 4
    [0x35] = {0x3F, 0x03, 0x1F, 0x30, 0x30, 0x33, 0x1E, 0x00}, // 5
    [0x36] = {0x1C, 0x06, 0x03, 0x1F, 0x33, 0x33, 0x1E, 0x00}, // 6
    [0x37] = {0x3F, 0x33, 0x30, 0x18, 0x0C, 0x0C, 0x0C, 0x00}, // 7
    [0x38] = {0x1E, 0x33, 0x33, 0x1E, 0x33, 0x33, 0x1E, 0x00}, // 8
    [0x39] = {0x1E, 0x33, 0x33, 0x3E, 0x30, 0x18, 0x0E, 0x00}, // 9
    [0x3A] = {0x00, 0x0C, 0x0C, 0x00, 0x00, 0x0C, 0x0C, 0x00}, // :
    [0x3B] = {0x00, 0x0C, 0x0C, 0x00, 0x00, 0x0C, 0x0C, 0x06}, // ;
    [0x3C] = {0x18, 0x0C, 0x06, 0x03, 0x06, 0x0C, 0x18, 0x00}, // <
    [0x3D] = {0x00, 0x00, 0x3F, 0x00, 0x00, 0x3F, 0x00, 0x00}, // =
    [0x3E] = {0x06, 0x0C, 0x18, 0x30, 0x18, 0x0C, 0x06, 0x00}, // >
    [0x3F] = {0x1E, 0x33, 0x30, 0x18, 0x0C, 0x00, 0x0C, 0x00}, // ?
    [0x40] = {0x3E, 0x63, 0x7B, 0x7B, 0x7B, 0x03, 0x1E, 0x00}, // @
    [0x41] = {0x0C, 0x1E, 0x33, 0x33, 0x3F, 0x33, 0x33, 0x00}, // A
    [0x42] = {0x3F, 0x66, 0x66, 0x3E, 0x66, 0x66, 0x3F, 0x00}, // B
    [0x43] = {0x3C, 0x66, 0x03, 0x03, 0x03, 0x66, 0x3C, 0x00}, // C
    [0x44] = {0x1F, 0x36, 0x66, 0x66, 0x66, 0x36, 0x1F, 0x00}, // D
    [0x45] = {0x7F, 0x46, 0x16, 0x1E, 0x16, 0x46, 0x7F, 0x00}, // E
    [0x46] = {0x7F, 0x46, 0x16, 0x1E, 0x16, 0x06, 0x0F, 0x00}, // F
    [0x47] = {0x3C, 0x66, 0x03, 0x03, 0x73, 0x66, 0x7C, 0x00}, // G
    [0x48] = {0x33, 0x33, 0x33, 0x3F, 0x33, 0x33, 0x33, 0x00}, // H
    [0x49] = {0x1E, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x1E, 0x00}, // I
    [0x4A] = {0x78, 0x30, 0x30, 0x30, 0x33, 0x33, 0x1E, 0x00}, // J
    [0x4B] = {0x67, 0x66, 0x36, 0x1E, 0x36, 0x66, 0x67, 0x00}, // K
    [0x4C] = {0x0F, 0x06, 0x06, 0x06, 0x46, 0x66, 0x7F, 0x00}, // L
    [0x4D] = {0x63, 0x77, 0x7F, 0x7F, 0x6B, 0x63, 0x63, 0x00}, // M
    [0x4E] = {0x63, 0x67, 0x6F, 0x7B, 0x73, 0x63, 0x63, 0x00}, // N
    [0x4F] = {0x1C, 0x36, 0x63, 0x63, 0x63, 0x36, 0x1C, 0x00}, // O
    [0x50] = {0x3F, 0x66, 0x66, 0x3E, 0x06, 0x06, 0x0F, 0x00}, // P
    [0x51] = {0x1E, 0x33, 0x33, 0x33, 0x3B, 0x1E, 0x38, 0x00}, // Q
    [0x52] = {0x3F, 0x66, 0x66, 0x3E, 0x36, 0x66, 0x67, 0x00}, // R
    [0x53] = {0x1E, 0x33, 0x07, 0x0E, 0x38, 0x33, 0x1E, 0x00}, // S
    [0x54] = {0x3F, 0x2D, 0x0C, 0x0C, 0x0C, 0x0C, 0x1E, 0x00}, // T
    [0x55] = {0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x3F, 0x00}, // U
    [0x56] = {0x33, 0x33, 0x33, 0x33, 0x33, 0x1E, 0x0C, 0x00}, // V
    [0x57] = {0x63, 0x63, 0x63, 0x6B, 0x7F, 0x77, 0x63, 0x00}, // W
    [0x58] = {0x63, 0x63, 0x36, 0x1C, 0x1C, 0x36, 0x63, 0x00}, // X
    [0x59] = {0x33, 0x33, 0x33, 0x1E, 0x0C, 0x0C, 0x1E, 0x00}, // Y
    [0x5A] = {0x7F, 0x63, 0x31, 0x18, 0x4C, 0x66, 0x7F, 0x00}, // Z
    [0x5B] = {0x1E, 0x06, 0x06, 0x06, 0x06, 0x06, 0x1E, 0x00}, // [
    [0x5C] = {0x03, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x40, 0x00}, // backslash
    [0x5D] = {0x1E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x1E, 0x00}, // ]
    [0x5E] = {0x08, 0x1C, 0x36, 0x63, 0x00, 0x00, 0x00, 0x00}, // ^
    [0x5F] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF}, // _
    // PETSCII-style block and line graphics (0x60-0x7F)
    [0x60] = {0x00, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00}, // hline
    [0x61] = {0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18}, // vline
    [0x62] = {0x18, 0x18, 0x18, 0xFF, 0xFF, 0x18, 0x18, 0x18}, // cross
    [0x63] = {0x00, 0x00, 0x00, 0x1F, 0x1F, 0x18, 0x18, 0x18}, // upper-left joint
    [0x64] = {0x00, 0x00, 0x00, 0xF8, 0xF8, 0x18, 0x18, 0x18}, // upper-right joint
    [0x65] = {0x18, 0x18, 0x18, 0x1F, 0x1F, 0x00, 0x00, 0x00}, // lower-left joint
    [0x66] = {0x18, 0x18, 0x18, 0xF8, 0xF8, 0x00, 0x00, 0x00}, // lower-right joint
    [0x67] = {0x00, 0x00, 0x00, 0xFF, 0xFF, 0x18, 0x18, 0x18}, // tee down
    [0x68] = {0x18, 0x18, 0x18, 0xFF, 0xFF, 0x00, 0x00, 0x00}, // tee up
    [0x69] = {0x18, 0x18, 0x18, 0x1F, 0x1F, 0x18, 0x18, 0x18}, // tee right
    [0x6A] = {0x18, 0x18, 0x18, 0xF8, 0xF8, 0x18, 0x18, 0x18}, // tee left
    [0x6B] = {0x80, 0xC0, 0xE0, 0xF0, 0x78, 0x3C, 0x1E, 0x0F}, // diagonal
    [0x6C] = {0x01, 0x03, 0x07, 0x0F, 0x1E, 0x3C, 0x78, 0xF0}, // diagonal
    [0x6D] = {0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55}, // checker
    [0x6E] = {0xCC, 0xCC, 0x33, 0x33, 0xCC, 0xCC, 0x33, 0x33}, // checker
    [0x6F] = {0xF0, 0xF0, 0xF0, 0xF0, 0x0F, 0x0F, 0x0F, 0x0F}, // split
    [0x70] = {0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0}, // left half
    [0x71] = {0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F}, // right half
    [0x72] = {0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00}, // top half
    [0x73] = {0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF}, // bottom half
    [0x74] = {0xF0, 0xF0, 0xF0, 0xF0, 0x00, 0x00, 0x00, 0x00}, // quadrant
    [0x75] = {0x0F, 0x0F, 0x0F, 0x0F, 0x00, 0x00, 0x00, 0x00}, // quadrant
    [0x76] = {0x00, 0x00, 0x00, 0x00, 0xF0, 0xF0, 0xF0, 0xF0}, // quadrant
    [0x77] = {0x00, 0x00, 0x00, 0x00, 0x0F, 0x0F, 0x0F, 0x0F}, // quadrant
    [0x78] = {0x81, 0x42, 0x24, 0x18, 0x18, 0x24, 0x42, 0x81}, // X
    [0x79] = {0x18, 0x3C, 0x7E, 0xFF, 0xFF, 0x7E, 0x3C, 0x18}, // diamond
    [0x7A] = {0x18, 0x3C, 0x7E, 0xDB, 0xFF, 0x24, 0x5A, 0xA5}, // ball
    [0x7B] = {0x00, 0x3C, 0x7E, 0x7E, 0x7E, 0x7E, 0x3C, 0x00}, // disk
    [0x7C] = {0x18, 0x3C, 0x7E, 0x18, 0x18, 0x7E, 0x3C, 0x18}, // arrows
    [0x7D] = {0x18, 0x18, 0x18, 0xFF, 0xFF, 0x18, 0x18, 0x18}, // plus line
    [0x7E] = {0x76, 0xDC, 0x00, 0x76, 0xDC, 0x00, 0x00, 0x00}, // waves
    [0x7F] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}, // full block

    // Extended ASCII / custom VIC symbols
    [0x80] = {0x00, 0x18, 0x18, 0x3C, 0x18, 0x3C, 0x7E, 0x00}, // chess pawn
    [0x81] = {0x00, 0x3C, 0x66, 0x60, 0x7C, 0x38, 0x7E, 0x00}, // chess knight
    [0x82] = {0x00, 0x18, 0x24, 0x18, 0x3C, 0x5A, 0x7E, 0x00}, // chess bishop
    [0x83] = {0x00, 0x7E, 0x66, 0x66, 0x7E, 0x3C, 0x7E, 0x00}, // chess rook
    [0x84] = {0x00, 0x6E, 0x7E, 0x3C, 0x7E, 0x7E, 0x7E, 0x00}, // chess queen
    [0x85] = {0x00, 0x18, 0x7E, 0x18, 0x3C, 0x7E, 0x7E, 0x00}, // chess king
    [0x86 ... 0xFF] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
};

// Initialize the VIC
void vic_init() {
    // Clear video RAM
    memset(video_ram, 0x20, VIDEO_RAM_SIZE);  // Fill with spaces
    memset(bitmap_ram, 0x00, BITMAP_RAM_SIZE); // Clear bitmap RAM
    memset(vicii_regs, 0x00, sizeof(vicii_regs));

    // Initialize VIC state
    vic_state.enabled = 1;
    vic_state.graphics_mode = 0;  // Start in text mode
    vic_state.cursor_x = 0;
    vic_state.cursor_y = 0;
    vic_state.text_color = 15;        // brighter startup text
    vic_state.background_color = 6;   // C64-style blue
    vic_state.text_attr_mode = 0;
    vic_state.bitmap_bank_ext = 0;
    vicii_regs[0x21] = vic_state.background_color & 0x0F;
    memset(video_ram + COLOR_RAM_OFFSET, default_text_attr(), TEXT_CELL_COUNT);

    vic_state.irq_status      = 0;
    vic_state.irq_enable      = 0;
    vic_state.raster_compare  = 0;
    vic_state.raster_line     = 0;
    vic_state.cycles_per_line = VIC_DEFAULT_CYCLES_PER_LINE;
    vic_state.raster_cycle_acc = 0;

    printf("VIC initialized: %dx%d text mode\n", VIC_SCREEN_COLS, VIC_SCREEN_ROWS);
}

// Bus interface: read from VIC video RAM
uint8_t vic_bus_read(void *dev, uint16_t offset) {
    (void)dev;  // Unused
    return vic_read_video_ram(offset);
}

// Bus interface: write to VIC video RAM
void vic_bus_write(void *dev, uint16_t offset, uint8_t val) {
    (void)dev;  // Unused
    vic_write_video_ram(offset, val);
}

// Bus interface: tick — advances raster line counter and raises interrupts
void vic_bus_tick(void *dev, uint32_t cycles) {
    (void)dev;

    vic_state.raster_cycle_acc += cycles;

    while (vic_state.cycles_per_line > 0 &&
           vic_state.raster_cycle_acc >= vic_state.cycles_per_line) {
        vic_state.raster_cycle_acc -= vic_state.cycles_per_line;
        vic_state.raster_line++;

        if (vic_state.raster_line >= VIC_BITMAP_HEIGHT) {
            vic_state.raster_line = 0;
            vic_state.irq_status |= VIC_IRQ_FRAME;
        }

        if (vic_state.raster_line == vic_state.raster_compare) {
            vic_state.irq_status |= VIC_IRQ_RASTER;
        }
    }
}

// VIC register interface: read from VIC control registers
uint8_t vic_reg_read(void *dev, uint16_t offset) {
    (void)dev;

    switch (offset) {
        case 0: return vic_state.graphics_mode;
        case 1: return (uint8_t)vic_state.cursor_x;
        case 2: return (uint8_t)vic_state.cursor_y;
        case 3: return vic_state.text_color & 0x0F;
        case 4: return vic_state.background_color & 0x0F;
        case 5: return vic_state.text_attr_mode;
        case 6: return vic_state.bitmap_bank_ext;
        case 7: {  /* ISR: interrupt status; bit 7 = any active */
            uint8_t isr = vic_state.irq_status;
            if (isr & vic_state.irq_enable) isr |= 0x80;
            return isr;
        }
        case 8: return vic_state.irq_enable;
        case 9: return vic_state.raster_compare;
        case 10: return vic_state.raster_line;   /* read-only */
        case 11: return (uint8_t)(vic_state.cycles_per_line & 0xFF);
        case 12: return (uint8_t)(vic_state.cycles_per_line >> 8);
        case 13: return vic_state.scroll_x;
        case 14: return vic_state.scroll_y;
        case 15: {
            uint8_t val = vic_state.ss_collision;
            vic_state.ss_collision = 0;  /* read clears */
            if (val) vic_state.irq_status &= ~VIC_IRQ_SS;  /* ACK IRQ */
            return val;
        }
        default: return 0;
    }
}

// VIC register interface: write to VIC control registers
void vic_reg_write(void *dev, uint16_t offset, uint8_t val) {
    (void)dev;

    switch (offset) {
        case 0:
            vic_state.graphics_mode = val;
            break;
        case 1:
            vic_state.cursor_x = val;
            break;
        case 2:
            vic_state.cursor_y = val;
            break;
        case 3:
            vic_state.text_color = val & 0x0F;
            refresh_text_attr_foreground();
            break;
        case 4:
            vic_state.background_color = val & 0x0F;
            refresh_text_attr_background();
            break;
        case 5:
            vic_state.text_attr_mode = val & 0x03;
            break;
        case 6:
            vic_state.bitmap_bank_ext = val & 0x1F;
            break;
        case 7:
            /* Writing a 1 to any bit clears that interrupt flag (ACK) */
            vic_state.irq_status &= (uint8_t)~val;
            break;
        case 8:
            vic_state.irq_enable = val & 0x0F;
            break;
        case 9:
            if (val < VIC_BITMAP_HEIGHT)
                vic_state.raster_compare = val;
            break;
        /* case 10: raster_line is read-only */
        case 11:
            vic_state.cycles_per_line =
                (uint16_t)((vic_state.cycles_per_line & 0xFF00) | val);
            break;
        case 12:
            vic_state.cycles_per_line =
                (uint16_t)((vic_state.cycles_per_line & 0x00FF) | ((uint16_t)val << 8));
            break;
        case 13:
            vic_state.scroll_x = val & 0x07;  /* only 3 bits valid */
            break;
        case 14:
            vic_state.scroll_y = val & 0x07;  /* only 3 bits valid */
            break;
        default:
            break;
    }
}

static uint32_t bitmap_window_to_addr(uint16_t offset)
{
    uint8_t bank;

    if (vic_state.graphics_mode & 0x60) {
        bank = vic_state.bitmap_bank_ext & 0x1F;
    } else {
        bank = (uint8_t)((vic_state.graphics_mode >> 5) & 0x07);
    }

    return (uint32_t)bank * BITMAP_WINDOW_SIZE +
           (uint32_t)(offset & (BITMAP_WINDOW_SIZE - 1));
}

// VIC bitmap RAM interface: read from bitmap RAM
uint8_t vic_bitmap_read(void *dev, uint16_t offset) {
    (void)dev;  // Unused

    uint32_t addr = bitmap_window_to_addr(offset);
    if (addr < BITMAP_RAM_SIZE) {
        return bitmap_ram[addr];
    }
    return 0;
}

// VIC bitmap RAM interface: write to bitmap RAM
void vic_bitmap_write(void *dev, uint16_t offset, uint8_t val) {
    (void)dev;  // Unused

    uint32_t addr = bitmap_window_to_addr(offset);
    if (addr < BITMAP_RAM_SIZE) {
        bitmap_ram[addr] = val;
    }
}

// Write to video RAM (CPU access)
void vic_write_video_ram(uint16_t address, uint8_t data) {
    if (address < VIDEO_RAM_SIZE) {
        video_ram[address] = data;
    }
}

// Read from video RAM (CPU access)
uint8_t vic_read_video_ram(uint16_t address) {
    if (address < VIDEO_RAM_SIZE) {
        return video_ram[address];
    }
    return 0;
}

// Read from bitmap RAM (for rendering)
uint8_t vic_read_bitmap_ram(uint32_t address) {
    if (address < BITMAP_RAM_SIZE) {
        return bitmap_ram[address];
    }
    return 0;
}

// Read from character ROM
const uint8_t* vic_get_char_pattern(uint8_t char_code) {
    return char_rom[char_code];
}

// Write character at current cursor position
void vic_write_char(char ch) {
    if (!vic_state.enabled) {
        return;
    }

    uint16_t pos = vic_state.cursor_y * VIC_SCREEN_COLS + vic_state.cursor_x;

    if (ch == '\n' || ch == '\r') {
        // Newline / Carriage return - both start a new line
        vic_state.cursor_x = 0;
        vic_state.cursor_y++;
    } else if (ch == '\b') {
        // Backspace
        if (vic_state.cursor_x > 0) {
            vic_state.cursor_x--;
        }
    } else {
        // Regular character
        if (pos < TEXT_CELL_COUNT) {
            video_ram[pos] = (uint8_t)ch;
            video_ram[COLOR_RAM_OFFSET + pos] = default_text_attr();
        }
        vic_state.cursor_x++;

        // Wrap to next line
        if (vic_state.cursor_x >= VIC_SCREEN_COLS) {
            vic_state.cursor_x = 0;
            vic_state.cursor_y++;
        }
    }

    // Scroll if needed
    if (vic_state.cursor_y >= VIC_SCREEN_ROWS) {
        vic_scroll_up();
        vic_state.cursor_y = VIC_SCREEN_ROWS - 1;
    }
}

// Write string to screen
void vic_write_string(const char* str) {
    while (*str) {
        vic_write_char(*str++);
    }
}

// Clear screen
void vic_clear_screen() {
    memset(video_ram, 0x20, TEXT_RAM_SIZE);  // Fill with spaces
    memset(video_ram + COLOR_RAM_OFFSET, default_text_attr(), TEXT_CELL_COUNT);
    vic_state.cursor_x = 0;
    vic_state.cursor_y = 0;
}

// Scroll screen up by one line
void vic_scroll_up() {
    // Move all lines up
    memmove(video_ram, video_ram + VIC_SCREEN_COLS,
            VIC_SCREEN_COLS * (VIC_SCREEN_ROWS - 1));
    memmove(video_ram + COLOR_RAM_OFFSET,
        video_ram + COLOR_RAM_OFFSET + VIC_SCREEN_COLS,
        VIC_SCREEN_COLS * (VIC_SCREEN_ROWS - 1));

    // Clear bottom line
    memset(video_ram + VIC_SCREEN_COLS * (VIC_SCREEN_ROWS - 1),
           0x20, VIC_SCREEN_COLS);
    memset(video_ram + COLOR_RAM_OFFSET + VIC_SCREEN_COLS * (VIC_SCREEN_ROWS - 1),
            default_text_attr(), VIC_SCREEN_COLS);
}

// Set cursor position
void vic_set_cursor(uint8_t x, uint8_t y) {
    if (x < VIC_SCREEN_COLS && y < VIC_SCREEN_ROWS) {
        vic_state.cursor_x = x;
        vic_state.cursor_y = y;
    }
}

// Get cursor position
void vic_get_cursor(uint8_t* x, uint8_t* y) {
    if (x) *x = vic_state.cursor_x;
    if (y) *y = vic_state.cursor_y;
}

void vic_set_text_color(uint8_t color) {
    vic_state.text_color = color & 0x0F;
}

uint8_t vic_get_text_color(void) {
    return vic_state.text_color & 0x0F;
}

void vic_set_background_color(uint8_t color) {
    vic_state.background_color = color & 0x0F;
}

uint8_t vic_get_background_color(void) {
    return vic_state.background_color & 0x0F;
}

// Render the screen (called periodically)
void vic_render_screen() {
    if (!vic_state.enabled) {
        return;
    }

    // This would typically render to actual display hardware
    // For now, we can output to terminal for debugging
    static int frame_count = 0;
    if (++frame_count % 60 == 0) {  // Print every 60 frames
        printf("\n=== VIC Screen ===\n");
        for (int row = 0; row < VIC_SCREEN_ROWS; row++) {
            for (int col = 0; col < VIC_SCREEN_COLS; col++) {
                uint8_t ch = video_ram[row * VIC_SCREEN_COLS + col];
                putchar(ch >= 0x20 && ch < 0x7F ? ch : '.');
            }
            putchar('\n');
        }
        printf("==================\n");
    }
}

// Get current graphics mode
uint8_t vic_get_graphics_mode(void) {
    return (vic_state.graphics_mode & 0x71) ? 1 : 0;
}

// Set graphics mode
void vic_set_graphics_mode(uint8_t mode) {
    vic_state.graphics_mode = (vic_state.graphics_mode & ~0x01) | (mode & 0x01);
}

uint8_t vic_get_mode_raw(void) {
    return vic_state.graphics_mode;
}

uint8_t vic_get_text_attr_mode(void) {
    return vic_state.text_attr_mode;
}

/* ──────────────────────────────────────────────────────────────────
 * Blitter + Sprites
 * ────────────────────────────────────────────────────────────────── */

/* Forward declaration */
static void blit_execute(void);

/* ---- pixel helpers (operate on bitmap_ram) ---- */

static void bitmap_set_pixel(int x, int y, int color)
{
    if ((unsigned)x >= VIC_BITMAP_WIDTH || (unsigned)y >= VIC_BITMAP_HEIGHT) return;
    uint8_t bit = (uint8_t)(1u << (x & 7));
    if (color) bitmap_ram[y * 40 + x / 8] |=  bit;
    else        bitmap_ram[y * 40 + x / 8] &= (uint8_t)~bit;
}

/* ---- Blitter state ---- */

static struct {
    uint16_t x, src_x;
    uint8_t  y, src_y;
    uint8_t  w, h;
    uint8_t  color;
    uint8_t  op;
} blit;

/* BLIT_OP codes */
#define BLIT_FILL       0
#define BLIT_COPY       1
#define BLIT_CLEAR      2
#define BLIT_LINE       3
#define BLIT_CIRCLE     4
#define BLIT_SCROLL_UP  5
#define BLIT_FILL_CIRC  6
#define BLIT_INVERT     7

static void blit_line_draw(int x0, int y0, int x1, int y1, int c)
{
    int dx = abs(x1 - x0), dy = -abs(y1 - y0);
    int sx = (x0 < x1) ? 1 : -1, sy = (y0 < y1) ? 1 : -1;
    int err = dx + dy;
    for (;;) {
        bitmap_set_pixel(x0, y0, c);
        if (x0 == x1 && y0 == y1) break;
        int e2 = 2 * err;
        if (e2 >= dy) { if (x0 == x1) break; err += dy; x0 += sx; }
        if (e2 <= dx) { if (y0 == y1) break; err += dx; y0 += sy; }
    }
}

static void blit_circle_draw(int cx, int cy, int r, int c)
{
    if (r <= 0) { bitmap_set_pixel(cx, cy, c); return; }
    int x = r, y = 0, p = 1 - r;
#define P8(ox, oy) do { \
    bitmap_set_pixel(cx+(ox), cy+(oy), c); bitmap_set_pixel(cx-(ox), cy+(oy), c); \
    bitmap_set_pixel(cx+(ox), cy-(oy), c); bitmap_set_pixel(cx-(ox), cy-(oy), c); \
    } while(0)
    P8(x, 0); P8(0, x);
    while (x > y) {
        y++;
        if (p <= 0) p += 2 * y + 1;
        else { x--; p += 2 * (y - x) + 1; }
        P8(x, y);
        if (x != y) P8(y, x);
    }
#undef P8
}

static void blit_fill_circle(int cx, int cy, int r, int c)
{
    for (int dy = -r; dy <= r; dy++) {
        int r2 = r * r - dy * dy, hw = r;
        while (hw > 0 && hw * hw > r2) hw--;
        for (int dx = -hw; dx <= hw; dx++)
            bitmap_set_pixel(cx + dx, cy + dy, c);
    }
}

static void blit_execute(void)
{
    int x  = (int)blit.x, y  = (int)blit.y;
    int sx = (int)blit.src_x, sy = (int)blit.src_y;
    int w  = blit.w  ? blit.w  : 256;
    int h  = blit.h  ? blit.h  : 256;
    int c  = blit.color & 1;

    switch (blit.op) {
    case BLIT_FILL:
        for (int dy = 0; dy < h; dy++)
            for (int dx = 0; dx < w; dx++)
                bitmap_set_pixel(x + dx, y + dy, c);
        break;
    case BLIT_COPY:
        for (int dy = 0; dy < h; dy++)
            for (int dx = 0; dx < w; dx++) {
                int bx = sx + dx, by = sy + dy;
                int bit = 0;
                if ((unsigned)bx < VIC_BITMAP_WIDTH && (unsigned)by < VIC_BITMAP_HEIGHT)
                    bit = (bitmap_ram[by * 40 + bx / 8] >> (bx & 7)) & 1;
                bitmap_set_pixel(x + dx, y + dy, bit);
            }
        break;
    case BLIT_CLEAR:
        memset(bitmap_ram, 0, BITMAP_RAM_SIZE);
        break;
    case BLIT_LINE:
        blit_line_draw(x, y, w, h, c);  /* w,h = x2,y2 */
        break;
    case BLIT_CIRCLE:
        blit_circle_draw(x, y, w, c);   /* w = radius */
        break;
    case BLIT_SCROLL_UP: {
        int sh = blit.h ? blit.h : 8;
        if (sh >= VIC_BITMAP_HEIGHT) { memset(bitmap_ram, 0, BITMAP_RAM_SIZE); break; }
        memmove(bitmap_ram, bitmap_ram + sh * 40,
                (size_t)(VIC_BITMAP_HEIGHT - sh) * 40);
        memset(bitmap_ram + (VIC_BITMAP_HEIGHT - sh) * 40, 0, (size_t)sh * 40);
        break;
    }
    case BLIT_FILL_CIRC:
        blit_fill_circle(x, y, w, c);
        break;
    case BLIT_INVERT:
        for (int dy = 0; dy < h; dy++)
            for (int dx = 0; dx < w; dx++) {
                int bx = x + dx, by = y + dy;
                if ((unsigned)bx < VIC_BITMAP_WIDTH && (unsigned)by < VIC_BITMAP_HEIGHT)
                    bitmap_ram[by * 40 + bx / 8] ^= (uint8_t)(1u << (bx & 7));
            }
        break;
    }
}

/* Blitter bus interface */
uint8_t vic_blitter_read(void *dev, uint16_t offset)
{
    (void)dev;
    switch (offset) {
    case 0: return (uint8_t)(blit.x & 0xFF);
    case 1: return (uint8_t)((blit.x >> 8) & 1);
    case 2: return blit.y;
    case 3: return blit.w;
    case 4: return blit.h;
    case 5: return (uint8_t)(blit.src_x & 0xFF);
    case 6: return (uint8_t)((blit.src_x >> 8) & 1);
    case 7: return blit.src_y;
    case 8: return blit.color;
    case 9: return blit.op;
    default: return 0;           /* $0F = status: always idle */
    }
}

void vic_blitter_write(void *dev, uint16_t offset, uint8_t val)
{
    (void)dev;
    switch (offset) {
    case 0: blit.x = (uint16_t)((blit.x & 0x100) | val); break;
    case 1: blit.x = (uint16_t)((blit.x & 0x0FF) | ((val & 1) << 8)); break;
    case 2: blit.y     = val; break;
    case 3: blit.w     = val; break;
    case 4: blit.h     = val; break;
    case 5: blit.src_x = (uint16_t)((blit.src_x & 0x100) | val); break;
    case 6: blit.src_x = (uint16_t)((blit.src_x & 0x0FF) | ((val & 1) << 8)); break;
    case 7: blit.src_y = val; break;
    case 8: blit.color = val; break;
    case 9: blit.op    = val; break;
    case 15: blit_execute(); break;    /* any write to $884F = TRIGGER */
    }
}

/* ---- Sprites ---- */

#define VIC_SPRITE_COUNT 8

static VicSprite vic_sprites[VIC_SPRITE_COUNT];
static uint8_t  sprite_pix_data[VIC_SPRITE_COUNT * 32]; /* 8 slots × 32 B */

bool vic_sprites_enabled(void)
{
    return (vic_state.graphics_mode & 0x02) != 0;
}

VicSprite *vic_get_sprite(int i)
{
    if ((unsigned)i < VIC_SPRITE_COUNT) return &vic_sprites[i];
    return NULL;
}

uint8_t vic_read_sprite_data(uint16_t offset)
{
    if (offset < sizeof(sprite_pix_data)) return sprite_pix_data[offset];
    return 0;
}

/* Sprite register bus interface (8 sprites × 8 bytes = 64 bytes) */
uint8_t vic_sprite_reg_read(void *dev, uint16_t offset)
{
    (void)dev;
    int sp = offset / 8, reg = offset & 7;
    if (sp >= VIC_SPRITE_COUNT) return 0;
    switch (reg) {
    case 0: return vic_sprites[sp].x;
    case 1: return vic_sprites[sp].y;
    case 2: return vic_sprites[sp].flags;
    case 3: return vic_sprites[sp].color;
    case 4: return vic_sprites[sp].data_slot;
    case 5: return vic_sprites[sp].priority;
    default: return 0;
    }
}

void vic_sprite_reg_write(void *dev, uint16_t offset, uint8_t val)
{
    (void)dev;
    int sp = offset / 8, reg = offset & 7;
    if (sp >= VIC_SPRITE_COUNT) return;
    switch (reg) {
    case 0: vic_sprites[sp].x         = val; break;
    case 1: vic_sprites[sp].y         = val; break;
    case 2: vic_sprites[sp].flags     = val; break;
    case 3: vic_sprites[sp].color     = val & 0x0F; break;
    case 4: vic_sprites[sp].data_slot = val &  0x07; break;
    case 5: vic_sprites[sp].priority  = val; break;
    }
}

/* Sprite pixel data bus interface */
uint8_t vic_sprite_data_read(void *dev, uint16_t offset)
{
    (void)dev;
    return vic_read_sprite_data(offset);
}

void vic_sprite_data_write(void *dev, uint16_t offset, uint8_t val)
{
    (void)dev;
    if (offset < sizeof(sprite_pix_data)) sprite_pix_data[offset] = val;
}

void vic_increment_frame(void) { vic_frame_lo++; }

uint8_t vic_get_scroll_x(void) { return vic_state.scroll_x; }
uint8_t vic_get_scroll_y(void) { return vic_state.scroll_y; }

/* Process sprite collision detection.
   Call once per frame after sprite rendering.
   sprite_mask[y*320+x] = bitmask of which sprites (0-7) cover pixel (x,y).
   For each pixel, if mask has >1 bit set: sprite-sprite collision.
   For bitmap pixels: check against bitmap_ram for sprite-background collision. */
void vic_detect_collisions(const uint8_t sprite_mask[320*200])
{
    if (!sprite_mask) return;

    vic_state.ss_collision = 0;
    vic_state.sb_collision = 0;

    /* Sprite-sprite collision: scan mask for pixels with multiple sprites */
    for (int y = 0; y < 200; y++) {
        for (int x = 0; x < 320; x++) {
            uint8_t mask = sprite_mask[y * 320 + x];
            /* Count bits set in mask */
            int count = 0;
            uint8_t involved = 0;
            for (int i = 0; i < 8; i++) {
                if (mask & (1u << i)) {
                    count++;
                    involved |= (1u << i);
                }
            }
            if (count > 1) {
                vic_state.ss_collision |= involved;
                vic_state.irq_status |= VIC_IRQ_SS;
            }
        }
    }

    /* Sprite-background collision: check sprites against bitmap RAM */
    for (int si = 0; si < 8; si++) {
        VicSprite *sp = &vic_sprites[si];
        if (!(sp->flags & SP_FLAG_ENABLE) || !sp->color) continue;

        int sx = (int)sp->x + ((sp->flags & SP_FLAG_XHIBIT) ? 256 : 0);
        int sy = (int)sp->y;
        int sw = (sp->flags & SP_FLAG_SIZE16) ? 16 : 8;
        int sh = sw;
        int bytes_per_row = sw / 8;
        int data_base = (int)(sp->data_slot & 7) * 32;

        for (int py = 0; py < sh; py++) {
            int src_row = (sp->flags & SP_FLAG_FLIPV) ? (sh - 1 - py) : py;
            for (int px = 0; px < sw; px++) {
                int src_col = (sp->flags & SP_FLAG_FLIPH) ? (sw - 1 - px) : px;
                int byte_idx = src_row * bytes_per_row + src_col / 8;
                uint8_t pix = vic_read_sprite_data((uint16_t)(data_base + byte_idx));
                if (!(pix & (1u << (src_col & 7)))) continue;  /* transparent */

                int bx = sx + px;
                int by = sy + py;
                if (bx >= 0 && bx < 320 && by >= 0 && by < 200) {
                    /* Check bitmap RAM at this position */
                    int bitmap_byte = (by * 40) + (bx / 8);
                    if (bitmap_byte >= 0 && bitmap_byte < BITMAP_RAM_SIZE) {
                        uint8_t bitmap_pix = bitmap_ram[bitmap_byte];
                        if (bitmap_pix & (1u << (bx & 7))) {
                            vic_state.sb_collision |= (1u << si);
                            vic_state.irq_status |= VIC_IRQ_SB;
                        }
                    }
                }
            }
        }
    }
}

/* Returns true when any enabled interrupt is pending — wire to CPU IRQ */
bool vic_irq(void)
{
    return (vic_state.irq_status & vic_state.irq_enable) != 0;
}

uint8_t vicii_read(void *dev, uint16_t offset)
{
    (void)dev;
    offset &= 0x3F;

    if (offset == 0x11) {
        return (uint8_t)((vicii_regs[offset] & 0x7F) |
                         ((vic_state.raster_line & 0x100) ? 0x80 : 0x00));
    }
    if (offset == 0x12) {
        return (uint8_t)(vic_state.raster_line & 0xFF);
    }
    return vicii_regs[offset];
}

void vicii_write(void *dev, uint16_t offset, uint8_t val)
{
    (void)dev;
    offset &= 0x3F;

    if (offset == 0x20 || offset == 0x21) {
        val &= 0x0F;
    }
    vicii_regs[offset] = val;

    if (offset == 0x21) {
        vic_state.background_color = val;
        refresh_text_attr_background();
    }
}
