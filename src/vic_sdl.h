#ifndef VIC_SDL_H
#define VIC_SDL_H

#include <stdint.h>
#include <stdbool.h>

#include "c64.h"
#include "config.h"

typedef void (*vic_sdl_drop_file_fn)(const char *path, void *user);

// Initialize SDL2 rendering for VIC with an integer window scale.
// Returns 0 on success, -1 on error
int vic_sdl_init(int window_scale);
void vic_sdl_set_c64(C64 *machine);
void vic_sdl_set_c64_config(Config *config, const char *filename);
bool vic_sdl_menu_open(void);
void vic_sdl_set_disk_title(unsigned int device, const char *name);

void vic_sdl_set_drop_file_handler(vic_sdl_drop_file_fn fn, void *user);

// Shutdown SDL2 rendering
void vic_sdl_shutdown(void);

// Render the VIC screen to SDL window
// Should be called periodically (e.g., 60 Hz)
void vic_sdl_render(void);

// Save the current SDL framebuffer as a BMP screenshot.
// Returns 0 on success, -1 on error.
int vic_sdl_save_screenshot(const char *path);

// Handle SDL events (keyboard, window close, etc.)
// Returns false if user wants to quit
bool vic_sdl_handle_events(void);

// Check if SDL rendering is enabled
bool vic_sdl_enabled(void);

#endif // VIC_SDL_H
