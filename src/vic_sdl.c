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
#define COLOR_BG 0x0000AA       // Blue background
#define COLOR_FG 0x8888FF       // Light blue foreground

// SDL objects
static SDL_Window *window = NULL;
static SDL_Renderer *renderer = NULL;
static SDL_Texture *texture = NULL;
static uint32_t *framebuffer = NULL;
static bool sdl_initialized = false;

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
    
    SDL_Quit();
    sdl_initialized = false;
    
    printf("SDL2 VIC display shutdown\n");
}

// Render a single character to the framebuffer
static void render_char(uint8_t char_code, int x, int y) {
    const uint8_t *pattern = vic_get_char_pattern(char_code);
    
    // Render each pixel of the 8x8 character
    for (int py = 0; py < CHAR_HEIGHT; py++) {
        uint8_t row = pattern[py];
        for (int px = 0; px < CHAR_WIDTH; px++) {
            /* Font bytes are LSB-first: bit 0 = leftmost pixel. */
            uint32_t color = (row & (0x01 << px)) ? COLOR_FG : COLOR_BG;
            
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
    
    // Render each character from video RAM
    for (int row = 0; row < SCREEN_ROWS; row++) {
        for (int col = 0; col < SCREEN_COLS; col++) {
            uint8_t char_code = vic_read_video_ram(row * SCREEN_COLS + col);
            render_char(char_code, col, row);
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
                
            case SDL_KEYDOWN: {
                // Handle special keys
                if (event.key.keysym.sym == SDLK_ESCAPE) {
                    return false;  // ESC to quit
                }
                
                // Forward keyboard events to VIA
                VIA6522 *via = get_keyboard_via();
                if (via) {
                    SDL_Keycode key = event.key.keysym.sym;
                    uint8_t ascii = 0;
                    
                    // Convert SDL key to ASCII
                    if (key >= SDLK_a && key <= SDLK_z) {
                        // Letters
                        ascii = (uint8_t)key;
                        if (event.key.keysym.mod & (KMOD_LSHIFT | KMOD_RSHIFT)) {
                            ascii = (uint8_t)(key - 32);  // Convert to uppercase
                        }
                    } else if (key >= SDLK_0 && key <= SDLK_9) {
                        // Numbers (with Shift for symbols)
                        if (event.key.keysym.mod & (KMOD_LSHIFT | KMOD_RSHIFT)) {
                            // Shift + number key
                            const char shift_nums[] = "!@#$%^&*()";
                            ascii = shift_nums[key - SDLK_0];
                        } else {
                            ascii = (uint8_t)key;
                        }
                    } else if (key == SDLK_SPACE) {
                        ascii = ' ';
                    } else if (key == SDLK_RETURN) {
                        ascii = '\r';  // Carriage return
                    } else if (key == SDLK_BACKSPACE) {
                        ascii = '\b';  // Backspace
                    } else if (key >= SDLK_KP_0 && key <= SDLK_KP_9) {
                        // Keypad numbers
                        ascii = '0' + (key - SDLK_KP_0);
                    } else {
                        // Other special characters
                        bool shifted = event.key.keysym.mod & (KMOD_LSHIFT | KMOD_RSHIFT);
                        switch (key) {
                            case SDLK_PERIOD:      ascii = shifted ? '>' : '.'; break;
                            case SDLK_COMMA:       ascii = shifted ? '<' : ','; break;
                            case SDLK_SEMICOLON:   ascii = shifted ? ':' : ';'; break;
                            case SDLK_QUOTE:       ascii = shifted ? '"' : '\''; break;
                            case SDLK_SLASH:       ascii = shifted ? '?' : '/'; break;
                            case SDLK_BACKSLASH:   ascii = shifted ? '|' : '\\'; break;
                            case SDLK_LEFTBRACKET: ascii = shifted ? '{' : '['; break;
                            case SDLK_RIGHTBRACKET: ascii = shifted ? '}' : ']'; break;
                            case SDLK_MINUS:       ascii = shifted ? '_' : '-'; break;
                            case SDLK_EQUALS:      ascii = shifted ? '+' : '='; break;
                            case SDLK_BACKQUOTE:   ascii = shifted ? '~' : '`'; break;
                            default: break;
                        }
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
