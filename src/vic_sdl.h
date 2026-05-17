#ifndef VIC_SDL_H
#define VIC_SDL_H

#include <stdint.h>
#include <stdbool.h>

// Initialize SDL2 rendering for VIC
// Returns 0 on success, -1 on error
int vic_sdl_init(void);

// Shutdown SDL2 rendering
void vic_sdl_shutdown(void);

// Render the VIC screen to SDL window
// Should be called periodically (e.g., 60 Hz)
void vic_sdl_render(void);

// Handle SDL events (keyboard, window close, etc.)
// Returns false if user wants to quit
bool vic_sdl_handle_events(void);

// Check if SDL rendering is enabled
bool vic_sdl_enabled(void);

#endif // VIC_SDL_H
