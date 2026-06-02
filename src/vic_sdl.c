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
#define CHAR_WIDTH 8
#define CHAR_HEIGHT 8
#define SCREEN_COLS 40
#define SCREEN_ROWS 25
#define COLOR_RAM_OFFSET 1024
#define WINDOW_WIDTH  (SCREEN_COLS * CHAR_WIDTH * SCREEN_SCALE)
#define WINDOW_HEIGHT (SCREEN_ROWS * CHAR_HEIGHT * SCREEN_SCALE)

static const uint32_t vic_palette[16] = {
    0xFF000000, // 0 black
    0xFFFFFFFF, // 1 white
    0xFF813338, // 2 red
    0xFF75CEC8, // 3 cyan
    0xFF8E3C97, // 4 purple
    0xFF56AC4D, // 5 green
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

// SDL objects
static SDL_Window *window = NULL;
static SDL_Renderer *renderer = NULL;
static SDL_Texture *texture = NULL;
static uint32_t *framebuffer = NULL;
static bool sdl_initialized = false;
static bool screen_edit_mode = false;

#define CURSOR_BLINK_MS 500

static bool push_key_sequence(VIA6522 *via, const uint8_t *bytes, size_t len) {
    for (size_t i = 0; i < len; i++) {
        if (!via_keyboard_push(via, bytes[i])) {
            return false;
        }
    }
    return true;
}

static bool inject_current_screen_line(VIA6522 *via) {
    uint8_t cursor_x = 0;
    uint8_t cursor_y = 0;
    uint8_t line[SCREEN_COLS + 2];
    size_t len = 0;
    size_t trimmed_len;

    vic_get_cursor(&cursor_x, &cursor_y);
    (void)cursor_x;

    for (int col = 0; col < SCREEN_COLS; col++) {
        line[len++] = vic_read_video_ram((uint16_t)(cursor_y * SCREEN_COLS + col));
    }

    trimmed_len = len;
    while (trimmed_len > 0 && line[trimmed_len - 1] == ' ') {
        trimmed_len--;
    }

    if (trimmed_len == 0) {
        uint8_t cr = '\r';
        return push_key_sequence(via, &cr, 1);
    }

    /* Move to a fresh input line first, then retype the recalled line and execute it. */
    line[trimmed_len++] = '\r';
    if (!push_key_sequence(via, line + (trimmed_len - 1), 1)) {
        return false;
    }
    if (!push_key_sequence(via, line, trimmed_len - 1)) {
        return false;
    }
    line[0] = '\r';
    return push_key_sequence(via, line, 1);
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
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
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

    printf("SDL2 VIC display initialized: %dx%d\n", WINDOW_WIDTH, WINDOW_HEIGHT);

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
static void render_char(uint8_t char_code, int x, int y, uint8_t text_attr, bool invert) {
    const uint8_t *pattern = vic_get_char_pattern(char_code);
    uint32_t tc = vic_palette[text_attr & 0x0F];
    uint32_t bc = vic_palette[(text_attr >> 4) & 0x0F];
    uint32_t fg = invert ? bc : tc;
    uint32_t bg = invert ? tc : bc;

    uint32_t * restrict base = framebuffer
        + (size_t)(y * CHAR_HEIGHT * SCREEN_SCALE) * WINDOW_WIDTH
        + (size_t)(x * CHAR_WIDTH  * SCREEN_SCALE);

    for (int py = 0; py < CHAR_HEIGHT; py++)
        simd_render_char_row_x2(base + (size_t)(py * SCREEN_SCALE) * WINDOW_WIDTH,
                                 WINDOW_WIDTH, pattern[py], fg, bg);
}

// Render the VIC screen to SDL window
void vic_sdl_render(void) {
    if (!sdl_initialized) {
        return;
    }

    vic_increment_frame();

    // Check graphics mode
    uint8_t gfx_mode = vic_get_graphics_mode();

    if (gfx_mode == 0) {
        simd_fill_u32(framebuffer, vic_palette[vic_get_background_color() & 0x0F],
                      (size_t)WINDOW_WIDTH * WINDOW_HEIGHT);

        // Text mode: 40x25 characters
        uint8_t cursor_x = 0;
        uint8_t cursor_y = 0;
        bool cursor_visible = ((SDL_GetTicks() / CURSOR_BLINK_MS) & 1u) == 0;
        vic_get_cursor(&cursor_x, &cursor_y);

        for (int row = 0; row < SCREEN_ROWS; row++) {
            for (int col = 0; col < SCREEN_COLS; col++) {
                uint8_t char_code = vic_read_video_ram(row * SCREEN_COLS + col);
                uint8_t text_attr = vic_read_video_ram(COLOR_RAM_OFFSET + row * SCREEN_COLS + col);
                bool invert = cursor_visible && col == cursor_x && row == cursor_y;
                render_char(char_code, col, row, text_attr, invert);
            }
        }
    } else {
        /* Bitmap mode with per-cell colours from colour RAM.
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

    /* ── Hardware sprites (rendered on top) ── */
    if (vic_sprites_enabled()) {
        for (int i = 0; i < 8; i++) {
            VicSprite *sp = vic_get_sprite(i);
            if (!(sp->flags & SP_FLAG_ENABLE)) continue;
            if (!sp->color) continue;              /* colour 0 = transparent */

            int sx    = (int)sp->x + ((sp->flags & SP_FLAG_XHIBIT) ? 256 : 0);
            int sy    = (int)sp->y;
            int sw    = (sp->flags & SP_FLAG_SIZE16) ? 16 : 8;
            int sh    = sw;
            int bytes_per_row = sw / 8;
            uint32_t sp_color = vic_palette[sp->color & 0x0F];
            int data_base = (int)(sp->data_slot & 7) * 32;

            for (int py = 0; py < sh; py++) {
                int src_row = (sp->flags & SP_FLAG_FLIPV) ? (sh - 1 - py) : py;
                for (int px = 0; px < sw; px++) {
                    int src_col = (sp->flags & SP_FLAG_FLIPH) ? (sw - 1 - px) : px;
                    int byte_idx = src_row * bytes_per_row + src_col / 8;
                    uint8_t pix  = vic_read_sprite_data(
                        (uint16_t)(data_base + byte_idx));
                    if (!(pix & (1u << (src_col & 7)))) continue; /* transparent */

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

    // Update texture
    SDL_UpdateTexture(texture, NULL, framebuffer, WINDOW_WIDTH * sizeof(uint32_t));

    // Render to screen
    SDL_RenderClear(renderer);
    SDL_RenderCopy(renderer, texture, NULL, NULL);
    SDL_RenderPresent(renderer);
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

            case SDL_TEXTINPUT: {
                // Handle text input (works with all keyboard layouts)
                VIA6522 *via = get_keyboard_via();
                if (via && event.text.text[0] != 0) {
                    // SDL_TEXTINPUT gives us the actual character typed
                    uint8_t ascii = (uint8_t)event.text.text[0];
                    // Only accept printable ASCII (0x20-0x7E)
                    if (ascii >= 0x20 && ascii <= 0x7E) {
                        if (screen_edit_mode) {
                            vic_write_char((char)ascii);
                        } else {
                            via_keyboard_push(via, ascii);
                        }
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
                if (via) {
                    SDL_Keycode key = event.key.keysym.sym;
                    uint8_t ascii = 0;

                    // Only handle non-printable keys here
                    switch (key) {
                        case SDLK_LEFT: {
                            uint8_t cursor_x;
                            uint8_t cursor_y;
                            vic_get_cursor(&cursor_x, &cursor_y);
                            if (cursor_x > 0) {
                                vic_set_cursor((uint8_t)(cursor_x - 1), cursor_y);
                                screen_edit_mode = true;
                            }
                            break;
                        }
                        case SDLK_RIGHT: {
                            uint8_t cursor_x;
                            uint8_t cursor_y;
                            vic_get_cursor(&cursor_x, &cursor_y);
                            if (cursor_x + 1 < SCREEN_COLS) {
                                vic_set_cursor((uint8_t)(cursor_x + 1), cursor_y);
                                screen_edit_mode = true;
                            }
                            break;
                        }
                        case SDLK_UP: {
                            uint8_t cursor_x;
                            uint8_t cursor_y;
                            vic_get_cursor(&cursor_x, &cursor_y);
                            if (cursor_y > 0) {
                                vic_set_cursor(cursor_x, (uint8_t)(cursor_y - 1));
                                screen_edit_mode = true;
                            }
                            break;
                        }
                        case SDLK_DOWN: {
                            uint8_t cursor_x;
                            uint8_t cursor_y;
                            vic_get_cursor(&cursor_x, &cursor_y);
                            if (cursor_y + 1 < SCREEN_ROWS) {
                                vic_set_cursor(cursor_x, (uint8_t)(cursor_y + 1));
                                screen_edit_mode = true;
                            }
                            break;
                        }
                        case SDLK_RETURN:
                        case SDLK_KP_ENTER:
                            if (screen_edit_mode) {
                                inject_current_screen_line(via);
                                screen_edit_mode = false;
                            } else {
                                ascii = '\r';  // Carriage return
                            }
                            break;
                        case SDLK_BACKSPACE:
                            if (screen_edit_mode) {
                                vic_write_char('\b');
                            } else {
                                ascii = '\b';  // Backspace
                            }
                            break;
                        default:
                            break;
                    }

                    // Push to VIA keyboard buffer
                    if (ascii != 0) {
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
