#include "vic_sdl.h"
#include "vic.h"
#include "keyboard.h"
#include <SDL2/SDL.h>
#include <stdio.h>
#include <string.h>

// SDL configuration
#define SCREEN_SCALE 2          // 2x scaling for better visibility
#define CHAR_WIDTH 8
#define CHAR_HEIGHT 8
#define SCREEN_COLS 40
#define SCREEN_ROWS 25
#define WINDOW_WIDTH  (SCREEN_COLS * CHAR_WIDTH * SCREEN_SCALE)
#define WINDOW_HEIGHT (SCREEN_ROWS * CHAR_HEIGHT * SCREEN_SCALE)

// Colors (C64-inspired)
#define COLOR_BG    0x0000AA    // Blue background (text mode)
#define COLOR_FG    0x8888FF    // Light blue foreground (text mode)
#define COLOR_BLACK 0x000000    // Black (bitmap mode)
#define COLOR_WHITE 0xFFFFFF    // White (bitmap mode)

// SDL objects
static SDL_Window *window = NULL;
static SDL_Renderer *renderer = NULL;
static SDL_Texture *texture = NULL;
static uint32_t *framebuffer = NULL;
static bool sdl_initialized = false;

#define CURSOR_BLINK_MS 500

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

// Render a single character to the framebuffer
static void render_char(uint8_t char_code, int x, int y, bool invert) {
    const uint8_t *pattern = vic_get_char_pattern(char_code);
    uint32_t fg = invert ? COLOR_BG : COLOR_FG;
    uint32_t bg = invert ? COLOR_FG : COLOR_BG;
    
    // Render each pixel of the 8x8 character
    for (int py = 0; py < CHAR_HEIGHT; py++) {
        uint8_t row = pattern[py];
        for (int px = 0; px < CHAR_WIDTH; px++) {
            /* Font bytes are LSB-first: bit 0 = leftmost pixel. */
            uint32_t color = (row & (0x01 << px)) ? fg : bg;
            
            // Draw with 2x scaling
            int screen_x = (x * CHAR_WIDTH + px) * SCREEN_SCALE;
            int screen_y = (y * CHAR_HEIGHT + py) * SCREEN_SCALE;
            
            for (int sy = 0; sy < SCREEN_SCALE; sy++) {
                for (int sx = 0; sx < SCREEN_SCALE; sx++) {
                    int fb_x = screen_x + sx;
                    int fb_y = screen_y + sy;
                    if (fb_x < WINDOW_WIDTH && fb_y < WINDOW_HEIGHT) {
                        framebuffer[fb_y * WINDOW_WIDTH + fb_x] = color;
                    }
                }
            }
        }
    }
}

// Render the VIC screen to SDL window
void vic_sdl_render(void) {
    if (!sdl_initialized) {
        return;
    }
    
    // Clear framebuffer
    memset(framebuffer, 0, WINDOW_WIDTH * WINDOW_HEIGHT * sizeof(uint32_t));
    
    // Check graphics mode
    uint8_t gfx_mode = vic_get_graphics_mode();
    
    if (gfx_mode == 0) {
        // Text mode: 40x25 characters
        uint8_t cursor_x = 0;
        uint8_t cursor_y = 0;
        bool cursor_visible = ((SDL_GetTicks() / CURSOR_BLINK_MS) & 1u) == 0;
        vic_get_cursor(&cursor_x, &cursor_y);

        for (int row = 0; row < SCREEN_ROWS; row++) {
            for (int col = 0; col < SCREEN_COLS; col++) {
                uint8_t char_code = vic_read_video_ram(row * SCREEN_COLS + col);
                bool invert = cursor_visible && col == cursor_x && row == cursor_y;
                render_char(char_code, col, row, invert);
            }
        }
    } else {
        // Bitmap mode: 320x200 pixels
        for (int y = 0; y < 200; y++) {
            for (int x = 0; x < 320; x++) {
                // Calculate byte and bit position
                uint16_t byte_offset = y * 40 + x / 8;
                uint8_t bit_mask = 0x01 << (x & 7);  // LSB-first
                
                uint8_t pixel_byte = vic_read_bitmap_ram(byte_offset);
                bool pixel_on = (pixel_byte & bit_mask) != 0;
                
                // Scale to window size (2x2 pixels per bitmap pixel)
                int screen_x = x * 2;
                int screen_y = y * 2;
                
                uint32_t color = pixel_on ? COLOR_WHITE : COLOR_BLACK;
                
                // Draw 2x2 block
                for (int dy = 0; dy < 2; dy++) {
                    for (int dx = 0; dx < 2; dx++) {
                        int px = screen_x + dx;
                        int py = screen_y + dy;
                        if (px < WINDOW_WIDTH && py < WINDOW_HEIGHT) {
                            framebuffer[py * WINDOW_WIDTH + px] = color;
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
                            }
                            break;
                        }
                        case SDLK_RIGHT: {
                            uint8_t cursor_x;
                            uint8_t cursor_y;
                            vic_get_cursor(&cursor_x, &cursor_y);
                            if (cursor_x + 1 < SCREEN_COLS) {
                                vic_set_cursor((uint8_t)(cursor_x + 1), cursor_y);
                            }
                            break;
                        }
                        case SDLK_UP: {
                            uint8_t cursor_x;
                            uint8_t cursor_y;
                            vic_get_cursor(&cursor_x, &cursor_y);
                            if (cursor_y > 0) {
                                vic_set_cursor(cursor_x, (uint8_t)(cursor_y - 1));
                            }
                            break;
                        }
                        case SDLK_DOWN: {
                            uint8_t cursor_x;
                            uint8_t cursor_y;
                            vic_get_cursor(&cursor_x, &cursor_y);
                            if (cursor_y + 1 < SCREEN_ROWS) {
                                vic_set_cursor(cursor_x, (uint8_t)(cursor_y + 1));
                            }
                            break;
                        }
                        case SDLK_RETURN:
                        case SDLK_KP_ENTER:
                            ascii = '\r';  // Carriage return
                            break;
                        case SDLK_BACKSPACE:
                            ascii = '\b';  // Backspace
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
