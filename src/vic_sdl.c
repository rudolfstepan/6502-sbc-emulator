#include "vic_sdl.h"
#include "vic.h"
#include "keyboard.h"
#include "simd.h"
#include <SDL2/SDL.h>
#include <stdio.h>
#include <string.h>

// SDL configuration
#define SCREEN_SCALE 2          // 2x scaling for better visibility
#if SCREEN_SCALE != 2
#  error "SIMD render path requires SCREEN_SCALE == 2"
#endif
#define WINDOW_SCALE 2          // QEMU-style integer scaling of the SBC image
#define CHAR_WIDTH 8
#define CHAR_HEIGHT 8
#define SCREEN_COLS 40
#define SCREEN_ROWS 25
#define COLOR_RAM_OFFSET 1024
#define WINDOW_WIDTH  (SCREEN_COLS * CHAR_WIDTH * SCREEN_SCALE)
#define WINDOW_HEIGHT (SCREEN_ROWS * CHAR_HEIGHT * SCREEN_SCALE)
#define SDL_WINDOW_WIDTH  (WINDOW_WIDTH * WINDOW_SCALE)
#define SDL_WINDOW_HEIGHT (WINDOW_HEIGHT * WINDOW_SCALE)

/* Sprite mask for collision detection: which sprites cover each pixel */
static uint8_t sprite_mask[320 * 200];

static bool full_redraw = true;  /* force full redraw on mode change, etc. */

static const uint32_t vic_palette[16] = {
    0xFF000000, // 0 black
    0xFFFFFFFF, // 1 white
    0xFF813338, // 2 red
    0xFF75CEC8, // 3 cyan
    0xFF8E3C97, // 4 purple
    0xFF003B16, // 5 green / dark terminal background
    0xFF2E2C9B, // 6 blue
    0xFFEDF171, // 7 yellow
    0xFF8E5029, // 8 orange
    0xFF553800, // 9 brown
    0xFFC46C71, // 10 light red
    0xFF4A4A4A, // 11 dark gray
    0xFF7B7B7B, // 12 gray
    0xFFA9FF9F, // 13 light green
    0xFF706DEB, // 14 light blue
    0xFFB2B2B2  // 15 light gray
};

static uint32_t rgb332_to_argb(uint8_t v)
{
    uint8_t r = (uint8_t)(((v >> 5) & 0x07) * 255 / 7);
    uint8_t g = (uint8_t)(((v >> 2) & 0x07) * 255 / 7);
    uint8_t b = (uint8_t)((v & 0x03) * 255 / 3);
    return 0xFF000000u | ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
}

static uint32_t rgb565_to_argb(uint8_t lo, uint8_t hi)
{
    uint16_t v = (uint16_t)lo | ((uint16_t)hi << 8);
    uint8_t r = (uint8_t)(((v >> 11) & 0x1F) * 255 / 31);
    uint8_t g = (uint8_t)(((v >> 5) & 0x3F) * 255 / 63);
    uint8_t b = (uint8_t)((v & 0x1F) * 255 / 31);
    return 0xFF000000u | ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
}

// SDL objects
static SDL_Window *window = NULL;
static SDL_Renderer *renderer = NULL;
static SDL_Texture *texture = NULL;
static uint32_t *framebuffer = NULL;
static bool sdl_initialized = false;
static vic_sdl_drop_file_fn drop_file_handler = NULL;
static void *drop_file_user = NULL;

#define CURSOR_BLINK_MS 500

void vic_sdl_set_drop_file_handler(vic_sdl_drop_file_fn fn, void *user)
{
    drop_file_handler = fn;
    drop_file_user = user;
}

// Initialize SDL2 rendering
int vic_sdl_init(void) {
    if (sdl_initialized) {
        return 0;  // Already initialized
    }

    // Initialize SDL
    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return -1;
    }

    // Create window
    window = SDL_CreateWindow(
        "6502 SBC - VIC Display",
        SDL_WINDOWPOS_CENTERED,
        SDL_WINDOWPOS_CENTERED,
        SDL_WINDOW_WIDTH,
        SDL_WINDOW_HEIGHT,
        SDL_WINDOW_SHOWN
    );

    if (!window) {
        fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
        SDL_Quit();
        return -1;
    }

    // Create renderer
    renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
    if (!renderer) {
        renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_SOFTWARE);
    }
    if (!renderer) {
        fprintf(stderr, "SDL_CreateRenderer failed: %s\n", SDL_GetError());
        SDL_DestroyWindow(window);
        SDL_Quit();
        return -1;
    }

    // Create texture for framebuffer
    texture = SDL_CreateTexture(
        renderer,
        SDL_PIXELFORMAT_ARGB8888,
        SDL_TEXTUREACCESS_STREAMING,
        WINDOW_WIDTH,
        WINDOW_HEIGHT
    );

    if (!texture) {
        fprintf(stderr, "SDL_CreateTexture failed: %s\n", SDL_GetError());
        SDL_DestroyRenderer(renderer);
        SDL_DestroyWindow(window);
        SDL_Quit();
        return -1;
    }

    // Allocate framebuffer
    framebuffer = (uint32_t *)malloc(WINDOW_WIDTH * WINDOW_HEIGHT * sizeof(uint32_t));
    if (!framebuffer) {
        fprintf(stderr, "Failed to allocate framebuffer\n");
        SDL_DestroyTexture(texture);
        SDL_DestroyRenderer(renderer);
        SDL_DestroyWindow(window);
        SDL_Quit();
        return -1;
    }

    sdl_initialized = true;

    // Enable text input for international keyboard support
    SDL_StartTextInput();
    SDL_EventState(SDL_DROPFILE, SDL_ENABLE);

    printf("SDL2 VIC display initialized: %dx%d framebuffer, %dx%d window (%dx)\n",
           WINDOW_WIDTH, WINDOW_HEIGHT,
           SDL_WINDOW_WIDTH, SDL_WINDOW_HEIGHT,
           WINDOW_SCALE);

    return 0;
}

// Shutdown SDL2 rendering
void vic_sdl_shutdown(void) {
    if (!sdl_initialized) {
        return;
    }

    if (framebuffer) {
        free(framebuffer);
        framebuffer = NULL;
    }

    if (texture) {
        SDL_DestroyTexture(texture);
        texture = NULL;
    }

    if (renderer) {
        SDL_DestroyRenderer(renderer);
        renderer = NULL;
    }

    if (window) {
        SDL_DestroyWindow(window);
        window = NULL;
    }

    SDL_StopTextInput();
    SDL_Quit();
    sdl_initialized = false;

    printf("SDL2 VIC display shutdown\n");
}

/* Render a single 8x8 character at 2x scale into the framebuffer.
   Each source pixel becomes a 2x2 block; SIMD expands all 8 pixels of one
   font row in a single pass and writes both scaled rows at once. */
static void render_char_at(uint8_t char_code, int px, int py, uint8_t text_attr, bool invert) {
    const uint8_t *pattern = vic_get_char_pattern(char_code);
    uint32_t tc = vic_palette[text_attr & 0x0F];
    uint32_t bc = vic_palette[(text_attr >> 4) & 0x0F];
    uint32_t fg = invert ? bc : tc;
    uint32_t bg = invert ? tc : bc;

    int fb_x = px * SCREEN_SCALE;
    int fb_y = py * SCREEN_SCALE;

    for (int row = 0; row < CHAR_HEIGHT; row++) {
        uint8_t pat = pattern[row];
        int src_y = fb_y + row * SCREEN_SCALE;
        if (src_y < 0 || src_y + SCREEN_SCALE > WINDOW_HEIGHT) continue;

        for (int bit = 0; bit < CHAR_WIDTH; bit++) {
            uint32_t color = (pat & (1u << bit)) ? fg : bg;
            int src_x = fb_x + bit * SCREEN_SCALE;
            if (src_x < 0 || src_x + SCREEN_SCALE > WINDOW_WIDTH) continue;

            for (int dy = 0; dy < SCREEN_SCALE; dy++) {
                for (int dx = 0; dx < SCREEN_SCALE; dx++) {
                    int fx = src_x + dx;
                    int fy = src_y + dy;
                    if (fx >= 0 && fx < WINDOW_WIDTH && fy >= 0 && fy < WINDOW_HEIGHT)
                        framebuffer[fy * WINDOW_WIDTH + fx] = color;
                }
            }
        }
    }
}

static void render_char_80_at(uint8_t char_code, int px, int py,
                              uint32_t fg, uint32_t bg, bool invert,
                              bool underline) {
    const uint8_t *pattern = vic_get_char_pattern(char_code);
    if (invert) {
        uint32_t tmp = fg;
        fg = bg;
        bg = tmp;
    }

    for (int row = 0; row < CHAR_HEIGHT; row++) {
        uint8_t pat = pattern[row];
        if (underline && row == CHAR_HEIGHT - 1) pat = 0xFF;  /* solid bottom row */
        for (int vrep = 0; vrep < 2; vrep++) {
            int fy = py + row * 2 + vrep;
            if ((unsigned)fy >= WINDOW_HEIGHT) continue;
            for (int bit = 0; bit < CHAR_WIDTH; bit++) {
                int fx = px + bit;
                if ((unsigned)fx >= WINDOW_WIDTH) continue;
                framebuffer[fy * WINDOW_WIDTH + fx] =
                    (pat & (1u << bit)) ? fg : bg;
            }
        }
    }
}


// Render the VIC screen to SDL window
void vic_sdl_render(void) {
    if (!sdl_initialized) {
        return;
    }

    vic_increment_frame();

    /* Track mode/scroll changes for dirty tracking */
    static uint8_t last_gfx_mode = 0xFF;
    static uint8_t last_scroll_x = 0xFF;
    static uint8_t last_scroll_y = 0xFF;

    // Check graphics mode
    uint8_t gfx_mode = vic_get_graphics_mode();
    uint8_t scroll_x = vic_get_scroll_x();
    uint8_t scroll_y = vic_get_scroll_y();

    if (gfx_mode != last_gfx_mode || scroll_x != last_scroll_x || scroll_y != last_scroll_y) {
        full_redraw = true;
        last_gfx_mode = gfx_mode;
        last_scroll_x = scroll_x;
        last_scroll_y = scroll_y;
    } else {
        full_redraw = false;
    }

    if (gfx_mode == 0) {
        simd_fill_u32(framebuffer, vic_palette[vic_get_background_color() & 0x0F],
                      (size_t)WINDOW_WIDTH * WINDOW_HEIGHT);

        // Text mode: 40x25 or FPGA 80x25 characters
        uint8_t cursor_x = 0;
        uint8_t cursor_y = 0;
        bool cursor_visible = ((SDL_GetTicks() / CURSOR_BLINK_MS) & 1u) == 0;
        vic_get_cursor(&cursor_x, &cursor_y);

        uint8_t scroll_x = vic_get_scroll_x();
        uint8_t scroll_y = vic_get_scroll_y();
        uint8_t text_attr_mode = vic_get_text_attr_mode();

        if (text_attr_mode & 0x02) {
            uint32_t fg = vic_palette[vic_get_text_color() & 0x0F];
            uint32_t bg = vic_palette[vic_get_background_color() & 0x0F];
            bool ul_attr = (text_attr_mode & 0x04) != 0;
            for (int row = 0; row < SCREEN_ROWS; row++) {
                for (int col = 0; col < 80; col++) {
                    uint8_t raw = vic_read_video_ram((uint16_t)(row * 80 + col));
                    /* With the underline attribute enabled, bit 7 underlines the
                     * character and the glyph index is the low 7 bits. */
                    bool underline = ul_attr && (raw & 0x80);
                    uint8_t char_code = ul_attr ? (uint8_t)(raw & 0x7F) : raw;
                    bool invert = cursor_visible && col == cursor_x && row == cursor_y;
                    render_char_80_at(char_code, col * 8, row * 16, fg, bg, invert, underline);
                }
            }
        } else {
            for (int row = 0; row < SCREEN_ROWS; row++) {
            int render_row = row - (scroll_y >> 3);  /* coarse scroll by character rows */
            if (render_row < 0) render_row += SCREEN_ROWS;  /* wrap */
            for (int col = 0; col < SCREEN_COLS; col++) {
                int render_col = col - (scroll_x >> 3);  /* coarse scroll by character cols */
                if (render_col < 0) render_col += SCREEN_COLS;  /* wrap */
                uint8_t char_code = vic_read_video_ram(render_row * SCREEN_COLS + render_col);
                uint8_t text_attr = vic_read_video_ram(COLOR_RAM_OFFSET + render_row * SCREEN_COLS + render_col);
                if ((text_attr_mode & 0x01) == 0) {
                    text_attr = (uint8_t)((text_attr & 0x0F) |
                                ((vic_get_background_color() & 0x0F) << 4));
                }
                bool invert = cursor_visible && render_col == cursor_x && render_row == cursor_y;
                /* Apply fine scroll offset to rendering position */
                int render_x = col * CHAR_WIDTH - (scroll_x & 7);
                int render_y = row * CHAR_HEIGHT - (scroll_y & 7);
                render_char_at(char_code, render_x, render_y, text_attr, invert);
            }
        }
        }
    } else {
        uint8_t mode = vic_get_mode_raw();
        if (mode & 0x40) {
            /* Tang FPGA: 320x200 RGB565, centred vertically in the 640x400 window. */
            for (int y = 0; y < 200; y++) {
                for (int x = 0; x < 320; x++) {
                    uint32_t byte_addr = (uint32_t)(y * 320 + x) * 2u;
                    uint32_t c = rgb565_to_argb(vic_read_bitmap_ram(byte_addr),
                                                vic_read_bitmap_ram(byte_addr + 1));
                    int fx0 = x * 2;
                    int fy0 = y * 2;
                    framebuffer[fy0 * WINDOW_WIDTH + fx0] = c;
                    framebuffer[fy0 * WINDOW_WIDTH + fx0 + 1] = c;
                    framebuffer[(fy0 + 1) * WINDOW_WIDTH + fx0] = c;
                    framebuffer[(fy0 + 1) * WINDOW_WIDTH + fx0 + 1] = c;
                }
            }
        } else if (mode & 0x20) {
            /* Tang FPGA: 640x400 RGB332, 1 byte per pixel. */
            for (int y = 0; y < 400; y++) {
                for (int x = 0; x < 640; x++) {
                    framebuffer[y * WINDOW_WIDTH + x] =
                        rgb332_to_argb(vic_read_bitmap_ram((uint32_t)y * 640u + (uint32_t)x));
                }
            }
        } else if (mode & 0x10) {
            /* Tang FPGA: 320x200 RGB332, scaled 2x to the emulator window. */
            for (int y = 0; y < 200; y++) {
                uint32_t *row0 = framebuffer + (size_t)(y * 2) * WINDOW_WIDTH;
                uint32_t *row1 = row0 + WINDOW_WIDTH;
                for (int x = 0; x < 320; x++) {
                    uint32_t c = rgb332_to_argb(
                        vic_read_bitmap_ram((uint32_t)y * 320u + (uint32_t)x));
                    row0[x * 2] = c;
                    row0[x * 2 + 1] = c;
                    row1[x * 2] = c;
                    row1[x * 2 + 1] = c;
                }
            }
        } else {
        /* Legacy bitmap mode with per-cell colours from colour RAM.
           Each 8×8 cell picks fg/bg from the same colour RAM used in text mode,
           enabling full multicolour bitmap graphics without extra hardware.
           One SIMD call per bitmap byte = 8x fewer iterations vs per-pixel. */
        for (int y = 0; y < 200; y++) {
            uint32_t * restrict row_ptr =
                framebuffer + (size_t)(y * SCREEN_SCALE) * WINDOW_WIDTH;
            int cell_row = y / CHAR_HEIGHT;
            for (int bx = 0; bx < 40; bx++) {
                uint8_t attr = vic_read_video_ram(
                    (uint16_t)(COLOR_RAM_OFFSET + cell_row * SCREEN_COLS + bx));
                uint32_t bit_fg = vic_palette[attr & 0x0F];
                uint32_t bit_bg = vic_palette[(attr >> 4) & 0x0F];
                uint8_t  byte   = vic_read_bitmap_ram((uint16_t)(y * 40 + bx));
                simd_render_char_row_x2(
                    row_ptr + (size_t)(bx * CHAR_WIDTH * SCREEN_SCALE),
                    WINDOW_WIDTH, byte, bit_fg, bit_bg);
            }
        }
        }
    }

    /* ── Hardware sprites (rendered on top) ── */
    if (vic_sprites_enabled()) {
        /* Clear sprite collision mask */
        memset(sprite_mask, 0, sizeof(sprite_mask));

        /* Sort sprites by priority (lowest to highest = drawn bottom to top) */
        int sprite_order[8] = {0, 1, 2, 3, 4, 5, 6, 7};
        for (int i = 0; i < 7; i++) {
            for (int j = i + 1; j < 8; j++) {
                VicSprite *sp_i = vic_get_sprite(sprite_order[i]);
                VicSprite *sp_j = vic_get_sprite(sprite_order[j]);
                if (sp_j->priority < sp_i->priority) {
                    int tmp = sprite_order[i];
                    sprite_order[i] = sprite_order[j];
                    sprite_order[j] = tmp;
                }
            }
        }

        for (int ii = 0; ii < 8; ii++) {
            int i = sprite_order[ii];
            VicSprite *sp = vic_get_sprite(i);
            if (!(sp->flags & SP_FLAG_ENABLE)) continue;
            if (!sp->color) continue;              /* colour 0 = transparent */

            int sx    = (int)sp->x + ((sp->flags & SP_FLAG_XHIBIT) ? 256 : 0);
            int sy    = (int)sp->y;
            int sw    = (sp->flags & SP_FLAG_SIZE16) ? 16 : 8;
            int sh    = sw;
            int bytes_per_row = sw / 8;
            uint32_t sp_color = vic_palette[sp->color & 0x0F];
            uint32_t sp_color2 = vic_palette[sp->pad[0] & 0x0F];  /* secondary color */
            int data_base = (int)(sp->data_slot & 7) * 32;
            bool multicolor = (sp->flags & SP_FLAG_MULTICOLOR) != 0;

            for (int py = 0; py < sh; py++) {
                int src_row = (sp->flags & SP_FLAG_FLIPV) ? (sh - 1 - py) : py;
                if (multicolor) {
                    /* 2bpp multicolor mode: 2 bits per pixel, 4 pixels per byte */
                    int bytes_per_mc_row = sw / 4;
                    for (int px = 0; px < sw; px++) {
                        int src_col = (sp->flags & SP_FLAG_FLIPH) ? (sw - 1 - px) : px;
                        int byte_idx = src_row * bytes_per_mc_row + src_col / 4;
                        uint8_t byte_pix = vic_read_sprite_data((uint16_t)(data_base + byte_idx));
                        uint8_t bits = (byte_pix >> ((src_col & 3) * 2)) & 3;
                        uint32_t color;
                        if (bits == 0) continue;  /* 00 = transparent */
                        else if (bits == 1) color = sp_color;        /* 01 = sprite color */
                        else if (bits == 2) color = sp_color2;       /* 10 = secondary color */
                        else color = vic_palette[15];                /* 11 = white (placeholder) */

                        int px_unscaled = sx + px;
                        int py_unscaled = sy + py;
                        if (px_unscaled >= 0 && px_unscaled < 320 && py_unscaled >= 0 && py_unscaled < 200)
                            sprite_mask[py_unscaled * 320 + px_unscaled] |= (1u << i);

                        int fb_x = (sx + px) * SCREEN_SCALE;
                        int fb_y = (sy + py) * SCREEN_SCALE;
                        for (int dy = 0; dy < SCREEN_SCALE; dy++) {
                            for (int dx = 0; dx < SCREEN_SCALE; dx++) {
                                unsigned fx = (unsigned)(fb_x + dx);
                                unsigned fy = (unsigned)(fb_y + dy);
                                if (fx < (unsigned)WINDOW_WIDTH && fy < (unsigned)WINDOW_HEIGHT)
                                    framebuffer[fy * WINDOW_WIDTH + fx] = color;
                            }
                        }
                    }
                } else {
                    /* 1bpp monochrome mode */
                    for (int px = 0; px < sw; px++) {
                        int src_col = (sp->flags & SP_FLAG_FLIPH) ? (sw - 1 - px) : px;
                        int byte_idx = src_row * bytes_per_row + src_col / 8;
                        uint8_t pix  = vic_read_sprite_data(
                            (uint16_t)(data_base + byte_idx));
                        if (!(pix & (1u << (src_col & 7)))) continue; /* transparent */

                        int px_unscaled = sx + px;
                        int py_unscaled = sy + py;
                        if (px_unscaled >= 0 && px_unscaled < 320 && py_unscaled >= 0 && py_unscaled < 200) {
                            /* Update sprite mask for collision detection */
                            sprite_mask[py_unscaled * 320 + px_unscaled] |= (1u << i);
                        }

                        int fb_x = (sx + px) * SCREEN_SCALE;
                        int fb_y = (sy + py) * SCREEN_SCALE;
                        for (int dy = 0; dy < SCREEN_SCALE; dy++) {
                            for (int dx = 0; dx < SCREEN_SCALE; dx++) {
                                unsigned fx = (unsigned)(fb_x + dx);
                                unsigned fy = (unsigned)(fb_y + dy);
                                if (fx < (unsigned)WINDOW_WIDTH &&
                                    fy < (unsigned)WINDOW_HEIGHT)
                                    framebuffer[fy * WINDOW_WIDTH + fx] = sp_color;
                            }
                        }
                    }
                }
            }
        }

        /* Detect sprite collisions after rendering */
        vic_detect_collisions(sprite_mask);
    }

    // Update texture
    SDL_UpdateTexture(texture, NULL, framebuffer, WINDOW_WIDTH * sizeof(uint32_t));

    // Render to screen
    SDL_RenderClear(renderer);
    SDL_RenderCopy(renderer, texture, NULL, NULL);
    SDL_RenderPresent(renderer);
}

int vic_sdl_save_screenshot(const char *path)
{
    if (!sdl_initialized || !framebuffer || !path) {
        return -1;
    }

    SDL_Surface *surface = SDL_CreateRGBSurfaceWithFormatFrom(
        framebuffer,
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        32,
        WINDOW_WIDTH * (int)sizeof(uint32_t),
        SDL_PIXELFORMAT_ARGB8888);
    if (!surface) {
        fprintf(stderr, "screenshot: SDL_CreateRGBSurfaceWithFormatFrom failed: %s\n",
                SDL_GetError());
        return -1;
    }

    int rc = SDL_SaveBMP(surface, path);
    if (rc != 0) {
        fprintf(stderr, "screenshot: SDL_SaveBMP '%s' failed: %s\n",
                path, SDL_GetError());
    } else {
        printf("screenshot: saved '%s'\n", path);
    }

    SDL_FreeSurface(surface);
    return rc == 0 ? 0 : -1;
}

// Handle SDL events
bool vic_sdl_handle_events(void) {
    if (!sdl_initialized) {
        return true;
    }

    SDL_Event event;
    while (SDL_PollEvent(&event)) {
        switch (event.type) {
            case SDL_QUIT:
                return false;  // User wants to quit

            case SDL_DROPFILE:
                if (drop_file_handler && event.drop.file) {
                    drop_file_handler(event.drop.file, drop_file_user);
                }
                if (event.drop.file) {
                    SDL_free(event.drop.file);
                }
                break;

            case SDL_TEXTINPUT: {
                // Handle text input (works with all keyboard layouts)
                VIA6522 *via = get_keyboard_via();
                KeyboardRegs *kbd = get_keyboard_regs();
                if (via && event.text.text[0] != 0) {
                    // SDL_TEXTINPUT gives us the actual character typed
                    uint8_t ascii = (uint8_t)event.text.text[0];
                    // Only accept printable ASCII (0x20-0x7E)
                    if (ascii >= 0x20 && ascii <= 0x7E) {
                        if (kbd) {
                            keyboard_regs_push_ascii(kbd, ascii);
                        }
                        via_keyboard_push(via, ascii);
                    }
                }
                break;
            }

            case SDL_KEYDOWN: {
                // Handle special keys (non-printable)
                if (event.key.keysym.sym == SDLK_ESCAPE) {
                    return false;  // ESC to quit
                }

                VIA6522 *via = get_keyboard_via();
                KeyboardRegs *kbd = get_keyboard_regs();
                if (via) {
                    SDL_Keycode key = event.key.keysym.sym;
                    SDL_Keymod mod = SDL_GetModState();
                    uint8_t ascii = 0;

                    // Only handle non-printable keys here
                    switch (key) {
                        case SDLK_LEFT:
                            ascii = 0x9D;  // PETSCII/SBC cursor left
                            break;
                        case SDLK_RIGHT:
                            ascii = 0x1D;  // PETSCII/SBC cursor right
                            break;
                        case SDLK_UP:
                            ascii = 0x91;  // PETSCII/SBC cursor up
                            break;
                        case SDLK_DOWN:
                            ascii = 0x11;  // PETSCII/SBC cursor down
                            break;
                        case SDLK_RETURN:
                        case SDLK_KP_ENTER:
                            ascii = '\r';  // Carriage return
                            break;
                        case SDLK_BACKSPACE:
                            ascii = '\b';  // Backspace
                            break;
                        case SDLK_HOME:
                            if (mod & KMOD_SHIFT) {
                                ascii = 0x93;  // Clear/Home
                            } else {
                                ascii = 0x13;  // Home
                            }
                            break;
                        case SDLK_l:
                            if (mod & KMOD_CTRL) {
                                vic_clear_screen();
                            }
                            break;
                        case SDLK_c:
                            if (mod & KMOD_CTRL) {
                                ascii = 0x03;  // BASIC STOP / Ctrl-C
                            }
                            break;
                        case SDLK_PAUSE:
                        case SDLK_CANCEL:
                            ascii = 0x03;      // Pause/Break as RUN-STOP
                            break;
                        default:
                            break;
                    }

                    // Push to VIA keyboard buffer
                    if (ascii != 0) {
                        if (kbd) {
                            keyboard_regs_push_ascii(kbd, ascii);
                        }
                        via_keyboard_push(via, ascii);
                    }
                }
                break;
            }

            default:
                break;
        }
    }

    return true;  // Continue running
}

// Check if SDL rendering is enabled
bool vic_sdl_enabled(void) {
    return sdl_initialized;
}
