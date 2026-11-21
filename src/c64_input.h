#ifndef C64_INPUT_H
#define C64_INPUT_H

#include <SDL2/SDL.h>

#include "c64.h"
#include "config.h"

typedef struct {
    uint8_t matrix_key;
    bool shifted;
    bool pressed;
} C64HostKey;

typedef struct {
    C64HostKey keys[SDL_NUM_SCANCODES];
    SDL_Joystick *joystick;
} C64Input;

void c64_input_refresh_device(C64Input *input);
void c64_input_close(C64Input *input);
void c64_input_clear(C64Input *input, C64 *machine);
void c64_input_key(C64Input *input, C64 *machine, const Config *config, const SDL_KeyboardEvent *event);
void c64_input_joystick(C64Input *input, C64 *machine, const Config *config);
const char *c64_input_key_name(unsigned int index);
SDL_Keycode c64_input_default_key(unsigned int index);
SDL_Scancode c64_input_joystick_key(const Config *config, unsigned int action);
unsigned int c64_input_capture_control(const C64Input *input, const SDL_Event *event);
void c64_input_control_name(unsigned int control, char *label, size_t capacity);

#endif
