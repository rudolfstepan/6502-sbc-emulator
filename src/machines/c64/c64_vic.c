#include "c64_vic.h"

#include <string.h>

enum {
    SPRITE_X_HIGH = 0x10,
    CONTROL_Y = 0x11,
    RASTER_LOW = 0x12,
    SPRITE_ENABLE = 0x15,
    CONTROL_X = 0x16,
    SPRITE_EXPAND_Y = 0x17,
    MEMORY = 0x18,
    IRQ_FLAGS = 0x19,
    IRQ_MASK = 0x1A,
    SPRITE_PRIORITY = 0x1B,
    SPRITE_MULTICOLOR = 0x1C,
    SPRITE_EXPAND_X = 0x1D,
    COLLIDE_SPRITES = 0x1E,
    COLLIDE_GRAPHICS = 0x1F,
    BORDER_COLOR = 0x20,
    BACKGROUND_COLOR = 0x21,
    SPRITE_SHARED_COLOR = 0x25,
    SPRITE_COLOR = 0x27,
    IRQ_RASTER = 1,
    IRQ_GRAPHICS = 2,
    IRQ_SPRITES = 4,
    PAL_CYCLES_PER_LINE = 63,
    PAL_LINES_PER_FRAME = 312,
    MATRIX_FIRST_LINE = 0x30,
    MATRIX_LAST_LINE = 0xF7,
    MATRIX_FETCH_START = 14,
    MATRIX_FETCH_END = MATRIX_FETCH_START + 40,
    SCREEN_TOP = 51,
    SCREEN_X = 24,
    VIC_COLUMNS = 40,
    SPRITE_COUNT = 8,
    SPRITE_HEIGHT = 21
};

bool c64_vic_irq(const C64 *c64)
{
    return (c64->vic_regs[IRQ_FLAGS] & c64->vic_regs[IRQ_MASK] & 0x0F) != 0;
}

static unsigned int raster_compare(const C64 *c64)
{
    return ((c64->vic_regs[CONTROL_Y] & 0x80u) << 1) | c64->vic_regs[RASTER_LOW];
}

uint8_t c64_vic_read(C64 *c64, unsigned int reg)
{
    uint8_t *regs = c64->vic_regs;
    switch (reg) {
    case CONTROL_Y:
        return (regs[reg] & 0x7F) | ((c64->raster_line >> 1) & 0x80);
    case RASTER_LOW:
        return (uint8_t)c64->raster_line;
    case CONTROL_X:
        return regs[reg] | 0xC0;
    case MEMORY:
        return regs[reg] | 1;
    case IRQ_FLAGS:
        return 0x70 | regs[reg] | (c64_vic_irq(c64) ? 0x80 : 0);
    case IRQ_MASK:
        return 0xF0 | regs[reg];
    case COLLIDE_SPRITES:
    case COLLIDE_GRAPHICS: {
        uint8_t value = regs[reg];
        regs[reg] = 0;
        return value;
    }
    default:
        if (reg >= 0x2F) {
            return 0xFF;
        }
        return reg >= BORDER_COLOR ? regs[reg] | 0xF0 : regs[reg];
    }
}

void c64_vic_write(C64 *c64, unsigned int reg, uint8_t value)
{
    if (reg == IRQ_FLAGS) {
        c64->vic_regs[reg] &= (uint8_t)~value;
    } else if (reg < 0x2F && reg != COLLIDE_SPRITES && reg != COLLIDE_GRAPHICS &&
               reg != 0x13 && reg != 0x14) {
        unsigned int previous = raster_compare(c64);
        c64->vic_regs[reg] = value;
        if (previous != c64->raster_line && raster_compare(c64) == c64->raster_line) {
            c64->vic_regs[IRQ_FLAGS] |= IRQ_RASTER;
        }
    }
}

static unsigned int screen_address(const C64 *c64, unsigned int bank)
{
    return bank + ((c64->vic_regs[MEMORY] & 0xF0) << 6);
}

static void fetch_matrix(C64 *c64)
{
    uint8_t control = c64->vic_regs[CONTROL_Y];
    if (c64->raster_line == MATRIX_FIRST_LINE) {
        c64->display_enabled = (control & 0x10) != 0;
    }

    c64->bad_line = c64->display_enabled && c64->raster_line >= MATRIX_FIRST_LINE &&
                    c64->raster_line <= MATRIX_LAST_LINE &&
                    (c64->raster_line & 7) == (control & 7);
    if (!c64->bad_line) {
        return;
    }

    c64->graphics_active = true;
    c64->graphics_row = 0;
    unsigned int screen = screen_address(c64, c64_video_bank(c64));
    for (unsigned int col = 0; col < VIC_COLUMNS; col++) {
        unsigned int index = (c64->matrix_base + col) & 0x3FF;
        c64->matrix_codes[col] = c64_video_read(c64, (uint16_t)(screen + index));
        c64->matrix_colors[col] = c64->color_ram[index];
    }
}

int c64_vic_cpu_stall(const C64 *c64)
{
    if (c64->bad_line && c64->raster_cycle < MATRIX_FETCH_END) {
        return (int)(MATRIX_FETCH_END - c64->raster_cycle);
    }
    return 0;
}

static void render_graphics(const C64 *c64, unsigned int bank, uint8_t *pixels, bool *foreground)
{
    const uint8_t *regs = c64->vic_regs;
    bool bitmap = (regs[CONTROL_Y] & 0x20) != 0;
    bool extended = (regs[CONTROL_Y] & 0x40) != 0;
    bool multicolor = (regs[CONTROL_X] & 0x10) != 0;
    bool invalid_mode = extended && (bitmap || multicolor);
    unsigned int scroll = regs[CONTROL_X] & 7;
    unsigned int graphics = bank + ((regs[MEMORY] & (bitmap ? 0x08 : 0x0E)) << 10);
    memset(pixels, c64->graphics_active ? regs[BACKGROUND_COLOR] & 0x0F : 0, C64_VIDEO_WIDTH);
    if (!c64->graphics_active) {
        return;
    }

    for (unsigned int col = 0; col < VIC_COLUMNS; col++) {
        uint8_t code = c64->matrix_codes[col];
        uint8_t color = c64->matrix_colors[col];
        bool paired = multicolor && (bitmap || (color & 8));
        unsigned int index = bitmap ? (c64->matrix_base + col) & 0x3FF
                                    : code & (extended ? 0x3F : 0xFF);
        uint8_t bits = c64_video_read(c64, (uint16_t)(graphics + index * 8 + c64->graphics_row));
        const uint8_t *background = regs + BACKGROUND_COLOR;
        uint8_t colors[4];
        if (paired) {
            colors[0] = background[0] & 0x0F;
            colors[1] = bitmap ? code >> 4 : background[1] & 0x0F;
            colors[2] = bitmap ? code & 0x0F : background[2] & 0x0F;
            colors[3] = bitmap ? color : color & 7;
        } else {
            colors[0] = bitmap ? code & 0x0F : background[extended ? code >> 6 : 0] & 0x0F;
            colors[1] = bitmap ? code >> 4 : color;
        }

        for (unsigned int x = 0; x < 8; x++) {
            unsigned int dest = col * 8 + x + scroll;
            if (dest >= C64_VIDEO_WIDTH) {
                break;
            }
            unsigned int pixel = paired ? (bits >> (6 - 2 * (x / 2))) & 3 : (bits >> (7 - x)) & 1;
            pixels[dest] = invalid_mode ? 0 : colors[pixel];
            /* In MCM the left bit of each graphics pair selects foreground priority. */
            unsigned int priority_bit = multicolor ? x & ~1u : x;
            foreground[dest] = (bits & (0x80u >> priority_bit)) != 0;
        }
    }
}

static void set_collision(C64 *c64, unsigned int reg, unsigned int irq, uint8_t sprites)
{
    if (!c64->vic_regs[reg]) {
        c64->vic_regs[IRQ_FLAGS] |= irq;
    }
    c64->vic_regs[reg] |= sprites;
}

static void render_sprites(C64 *c64, unsigned int bank, uint8_t *pixels, const bool *foreground)
{
    const uint8_t *regs = c64->vic_regs;
    unsigned int pointers = screen_address(c64, bank) + 0x3F8;
    uint8_t occupied[C64_VIDEO_WIDTH] = {0};

    for (unsigned int sprite = 0; sprite < SPRITE_COUNT; sprite++) {
        uint8_t mask = (uint8_t)(1u << sprite);
        if (!(c64->sprite_active & mask)) {
            continue;
        }
        int left = regs[sprite * 2] + ((regs[SPRITE_X_HIGH] & mask) ? 256 : 0) - SCREEN_X;
        unsigned int scale = (regs[SPRITE_EXPAND_X] & mask) ? 2 : 1;
        unsigned int pointer = c64_video_read(c64, (uint16_t)(pointers + sprite));
        unsigned int address = bank + pointer * 64 + c64->sprite_rows[sprite] * 3;
        bool multicolor = (regs[SPRITE_MULTICOLOR] & mask) != 0;
        const uint8_t sprite_colors[] = {0, regs[SPRITE_SHARED_COLOR] & 0x0F,
                                        regs[SPRITE_COLOR + sprite] & 0x0F,
                                        regs[SPRITE_SHARED_COLOR + 1] & 0x0F};

        for (unsigned int byte = 0; byte < 3; byte++) {
            uint8_t bits = c64_video_read(c64, (uint16_t)(address + byte));
            for (unsigned int x = 0; x < 8; x++) {
                unsigned int color = multicolor ? (bits >> (6 - 2 * (x / 2))) & 3
                                               : ((bits & (0x80u >> x)) ? 2 : 0);
                if (!color) {
                    continue;
                }
                for (unsigned int repeat = 0; repeat < scale; repeat++) {
                    int dest = left + (int)((byte * 8 + x) * scale + repeat);
                    if (dest < 0 || dest >= C64_VIDEO_WIDTH) {
                        continue;
                    }
                    if (foreground[dest]) {
                        set_collision(c64, COLLIDE_GRAPHICS, IRQ_GRAPHICS, mask);
                    }
                    if (occupied[dest]) {
                        set_collision(c64, COLLIDE_SPRITES, IRQ_SPRITES, occupied[dest] | mask);
                    } else if (!(foreground[dest] && (regs[SPRITE_PRIORITY] & mask))) {
                        pixels[dest] = sprite_colors[color];
                    }
                    occupied[dest] |= mask;
                }
            }
        }
    }
}

static void update_vertical_border(C64 *c64)
{
    uint8_t control = c64->vic_regs[CONTROL_Y];
    unsigned int top = (control & 8) ? SCREEN_TOP : 55;
    unsigned int bottom = (control & 8) ? SCREEN_TOP + C64_VIDEO_HEIGHT : 247;
    if (c64->raster_line == bottom) {
        c64->vertical_border_open = false;
    } else if (c64->raster_line == top && (control & 0x10)) {
        c64->vertical_border_open = true;
    }
}

static void render_line(C64 *c64)
{
    update_vertical_border(c64);
    if (c64->raster_line < SCREEN_TOP || c64->raster_line >= SCREEN_TOP + C64_VIDEO_HEIGHT) {
        return;
    }

    const uint8_t *regs = c64->vic_regs;
    unsigned int y = c64->raster_line - SCREEN_TOP;
    uint8_t *pixels = c64->video_frames[c64->video_draw_frame][y];
    bool foreground[C64_VIDEO_WIDTH] = {false};
    unsigned int bank = c64_video_bank(c64);
    if (c64->vertical_border_open) {
        render_graphics(c64, bank, pixels, foreground);
    }
    render_sprites(c64, bank, pixels, foreground);

    uint8_t border = regs[BORDER_COLOR] & 0x0F;
    if (!c64->vertical_border_open) {
        memset(pixels, border, C64_VIDEO_WIDTH);
    } else if (!(regs[CONTROL_X] & 8)) {
        memset(pixels, border, 7);
        memset(pixels + 311, border, C64_VIDEO_WIDTH - 311);
    }
}

static void advance_sprites(C64 *c64)
{
    const uint8_t *regs = c64->vic_regs;
    for (unsigned int sprite = 0; sprite < SPRITE_COUNT; sprite++) {
        uint8_t mask = (uint8_t)(1u << sprite);
        if (c64->sprite_active & mask) {
            if (regs[SPRITE_EXPAND_Y] & mask) {
                c64->sprite_expand_phase ^= mask;
            } else {
                c64->sprite_expand_phase &= (uint8_t)~mask;
            }
            if (!(c64->sprite_expand_phase & mask) && ++c64->sprite_rows[sprite] == SPRITE_HEIGHT) {
                c64->sprite_active &= (uint8_t)~mask;
            }
        }
        if ((regs[SPRITE_ENABLE] & mask) && (uint8_t)c64->raster_line == regs[sprite * 2 + 1] &&
            !(c64->sprite_active & mask)) {
            c64->sprite_active |= mask;
            c64->sprite_expand_phase &= (uint8_t)~mask;
            c64->sprite_rows[sprite] = 0;
        }
    }
}

void c64_vic_tick(C64 *c64, uint32_t cycles)
{
    while (cycles) {
        unsigned int next = PAL_CYCLES_PER_LINE;
        if (c64->raster_cycle < MATRIX_FETCH_START) {
            next = MATRIX_FETCH_START;
        } else if (c64->raster_cycle < MATRIX_FETCH_END) {
            next = MATRIX_FETCH_END;
        }

        unsigned int remaining = next - c64->raster_cycle;
        if (cycles < remaining) {
            c64->raster_cycle += cycles;
            break;
        }
        cycles -= remaining;
        c64->raster_cycle = next;
        if (next == MATRIX_FETCH_START) {
            fetch_matrix(c64);
        } else if (next == MATRIX_FETCH_END) {
            render_line(c64);
        } else {
            update_vertical_border(c64);
            advance_sprites(c64);
            if (c64->graphics_active && c64->graphics_row++ == 7) {
                c64->matrix_base = (c64->matrix_base + VIC_COLUMNS) & 0x3FF;
                c64->graphics_active = false;
            }
            c64->raster_cycle = 0;
            c64->bad_line = false;
            if (++c64->raster_line == PAL_LINES_PER_FRAME) {
                c64->raster_line = 0;
                c64->matrix_base = 0;
                c64->graphics_active = false;
                c64->display_enabled = false;
                c64->video_draw_frame ^= 1;
            }
            if (raster_compare(c64) == c64->raster_line) {
                c64->vic_regs[IRQ_FLAGS] |= IRQ_RASTER;
            }
        }
    }
}

const uint8_t (*c64_vic_frame(const C64 *c64))[C64_VIDEO_WIDTH]
{
    return c64->video_frames[c64->video_draw_frame ^ 1];
}
