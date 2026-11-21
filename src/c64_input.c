#include "c64_input.h"

#include <stdio.h>
#include <string.h>

enum {
    CONTROL_AXIS = 0x100,
    CONTROL_HAT = 0x300,
    AXIS_THRESHOLD = 16000,
    LEFT_SHIFT = 15,
    RESTORE = 64
};

/* CIA1 port A bit * 8 + port B bit, followed by the separate RESTORE line. */
static const struct {
    SDL_Keycode symbol;
    const char *name;
} matrix[C64_KEY_COUNT] = {
    {SDLK_BACKSPACE, "INST/DEL"}, {SDLK_RETURN, "RETURN"}, {SDLK_RIGHT, "CURSOR RIGHT"},
    {SDLK_F7, "F7"}, {SDLK_F1, "F1"}, {SDLK_F3, "F3"}, {SDLK_F5, "F5"}, {SDLK_DOWN, "CURSOR DOWN"},
    {SDLK_3, "3"}, {SDLK_w, "W"}, {SDLK_a, "A"}, {SDLK_4, "4"}, {SDLK_z, "Z"},
    {SDLK_s, "S"}, {SDLK_e, "E"}, {SDLK_LSHIFT, "LEFT SHIFT"},
    {SDLK_5, "5"}, {SDLK_r, "R"}, {SDLK_d, "D"}, {SDLK_6, "6"}, {SDLK_c, "C"},
    {SDLK_f, "F"}, {SDLK_t, "T"}, {SDLK_x, "X"},
    {SDLK_7, "7"}, {SDLK_y, "Y"}, {SDLK_g, "G"}, {SDLK_8, "8"}, {SDLK_b, "B"},
    {SDLK_h, "H"}, {SDLK_u, "U"}, {SDLK_v, "V"},
    {SDLK_9, "9"}, {SDLK_i, "I"}, {SDLK_j, "J"}, {SDLK_0, "0"}, {SDLK_m, "M"},
    {SDLK_k, "K"}, {SDLK_o, "O"}, {SDLK_n, "N"},
    {SDLK_PLUS, "+"}, {SDLK_p, "P"}, {SDLK_l, "L"}, {SDLK_MINUS, "-"}, {SDLK_PERIOD, "."},
    {SDLK_COLON, ":"}, {SDLK_AT, "@"}, {SDLK_COMMA, ","},
    {SDLK_BACKSLASH, "POUND"}, {SDLK_ASTERISK, "*"}, {SDLK_SEMICOLON, ";"}, {SDLK_HOME, "HOME"},
    {SDLK_RSHIFT, "RIGHT SHIFT"}, {SDLK_EQUALS, "="}, {SDLK_CARET, "UP ARROW"}, {SDLK_SLASH, "/"},
    {SDLK_1, "1"}, {SDLK_BACKQUOTE, "LEFT ARROW"}, {SDLK_LCTRL, "CTRL"}, {SDLK_2, "2"},
    {SDLK_SPACE, "SPACE"}, {SDLK_LALT, "COMMODORE"}, {SDLK_q, "Q"}, {SDLK_ESCAPE, "RUN/STOP"},
    {SDLK_PAGEUP, "RESTORE"}
};

static const uint8_t hat_directions[] = {SDL_HAT_UP, SDL_HAT_DOWN, SDL_HAT_LEFT, SDL_HAT_RIGHT};

const char *c64_input_key_name(unsigned int index)
{
    return matrix[index].name;
}

SDL_Keycode c64_input_default_key(unsigned int index)
{
    return matrix[index].symbol;
}

SDL_Scancode c64_input_joystick_key(const Config *config, unsigned int action)
{
    static const SDL_Scancode defaults[] = {
        SDL_SCANCODE_UP, SDL_SCANCODE_DOWN, SDL_SCANCODE_LEFT, SDL_SCANCODE_RIGHT, SDL_SCANCODE_RCTRL
    };
    return config->joystick_keys[action] ? (SDL_Scancode)config->joystick_keys[action] : defaults[action];
}

void c64_input_refresh_device(C64Input *input)
{
    if (input->joystick && !SDL_JoystickGetAttached(input->joystick)) {
        SDL_JoystickClose(input->joystick);
        input->joystick = NULL;
    }
    for (int index = 0; !input->joystick && index < SDL_NumJoysticks(); index++) {
        input->joystick = SDL_JoystickOpen(index);
    }
}

void c64_input_close(C64Input *input)
{
    if (input->joystick) {
        SDL_JoystickClose(input->joystick);
        input->joystick = NULL;
    }
}

void c64_input_clear(C64Input *input, C64 *machine)
{
    memset(input->keys, 0, sizeof(input->keys));
    c64_clear_keys(machine);
    machine->restore_pressed = false;
    memset(machine->joystick, 0, sizeof(machine->joystick));
}

static C64HostKey resolve_key(const Config *config, SDL_Scancode scan, SDL_Keycode symbol)
{
    C64HostKey key = {.pressed = true};
    if (config) {
        if (config->joystick_port) {
            for (unsigned int i = 0; i < C64_JOYSTICK_ACTIONS; i++) {
                if (scan == c64_input_joystick_key(config, i)) {
                    return key;
                }
            }
        }
        for (unsigned int i = 0; i < C64_KEY_COUNT; i++) {
            if (config->c64_keys[i] == scan) {
                key.matrix_key = (uint8_t)(i + 1);
                return key;
            }
        }
    }

    switch (symbol) {
    case SDLK_LEFT: symbol = SDLK_RIGHT; key.shifted = true; break;
    case SDLK_UP:   symbol = SDLK_DOWN;  key.shifted = true; break;
    case SDLK_F2:   symbol = SDLK_F1;    key.shifted = true; break;
    case SDLK_F4:   symbol = SDLK_F3;    key.shifted = true; break;
    case SDLK_F6:   symbol = SDLK_F5;    key.shifted = true; break;
    case SDLK_F8:   symbol = SDLK_F7;    key.shifted = true; break;
    case SDLK_TAB:         symbol = SDLK_ESCAPE; break;
    case SDLK_DELETE:      symbol = SDLK_BACKSPACE; break;
    case SDLK_KP_ENTER:    symbol = SDLK_RETURN; break;
    case SDLK_KP_PLUS:     symbol = SDLK_PLUS; break;
    case SDLK_KP_MINUS:    symbol = SDLK_MINUS; break;
    case SDLK_KP_MULTIPLY: symbol = SDLK_ASTERISK; break;
    case SDLK_KP_DIVIDE:   symbol = SDLK_SLASH; break;
    case SDLK_RCTRL:       symbol = SDLK_LCTRL; break;
    case SDLK_RALT:        symbol = SDLK_LALT; break;
    default: break;
    }
    for (unsigned int i = 0; i < C64_KEY_COUNT; i++) {
        if (matrix[i].symbol == symbol && (!config || !config->c64_keys[i])) {
            key.matrix_key = (uint8_t)(i + 1);
            break;
        }
    }
    return key;
}

void c64_input_key(C64Input *input, C64 *machine, const Config *config, const SDL_KeyboardEvent *event)
{
    SDL_Scancode scan = event->keysym.scancode;
    if (scan <= SDL_SCANCODE_UNKNOWN || scan >= SDL_NUM_SCANCODES) {
        return;
    }
    input->keys[scan] = event->type == SDL_KEYDOWN ? resolve_key(config, scan, event->keysym.sym)
                                                  : (C64HostKey){0};
    c64_clear_keys(machine);
    machine->restore_pressed = false;
    for (unsigned int i = 0; i < SDL_NUM_SCANCODES; i++) {
        C64HostKey key = input->keys[i];
        if (key.matrix_key == RESTORE + 1) {
            machine->restore_pressed = true;
        } else if (key.matrix_key) {
            c64_set_key(machine, key.matrix_key - 1);
            if (key.shifted) {
                c64_set_key(machine, LEFT_SHIFT);
            }
        }
    }
    c64_input_joystick(input, machine, config);
}

static bool control_pressed(SDL_Joystick *joystick, unsigned int control)
{
    if (control >= CONTROL_HAT) {
        unsigned int index = control - CONTROL_HAT;
        return (SDL_JoystickGetHat(joystick, (int)(index / 4)) & hat_directions[index % 4]) != 0;
    }
    if (control >= CONTROL_AXIS) {
        unsigned int index = control - CONTROL_AXIS;
        int value = SDL_JoystickGetAxis(joystick, (int)(index / 2));
        return (index & 1) ? value > AXIS_THRESHOLD : value < -AXIS_THRESHOLD;
    }
    return control != 0 && SDL_JoystickGetButton(joystick, (int)control - 1) != 0;
}

void c64_input_joystick(C64Input *input, C64 *machine, const Config *config)
{
    memset(machine->joystick, 0, sizeof(machine->joystick));
    if (!config || !config->joystick_port) {
        return;
    }
    static const unsigned int defaults[] = {CONTROL_AXIS + 2, CONTROL_AXIS + 3, CONTROL_AXIS, CONTROL_AXIS + 1, 1};
    for (unsigned int action = 0; action < C64_JOYSTICK_ACTIONS; action++) {
        unsigned int control = config->joystick_controls[action];
        bool pressed = input->keys[c64_input_joystick_key(config, action)].pressed;
        if (input->joystick) {
            pressed |= control_pressed(input->joystick, control ? control : defaults[action]);
            if (!control && action < 4) {
                pressed |= control_pressed(input->joystick, CONTROL_HAT + action);
            }
        }
        if (pressed) {
            machine->joystick[config->joystick_port - 1] |= (uint8_t)(1u << action);
        }
    }
}

unsigned int c64_input_capture_control(const C64Input *input, const SDL_Event *event)
{
    if (!input->joystick) {
        return 0;
    }
    SDL_JoystickID id = SDL_JoystickInstanceID(input->joystick);
    if (event->type == SDL_JOYBUTTONDOWN && event->jbutton.which == id && event->jbutton.button < 255) {
        return 1u + event->jbutton.button;
    }
    if (event->type == SDL_JOYAXISMOTION && event->jaxis.which == id &&
        (event->jaxis.value > AXIS_THRESHOLD || event->jaxis.value < -AXIS_THRESHOLD)) {
        return CONTROL_AXIS + 2u * event->jaxis.axis + (event->jaxis.value > 0);
    }
    if (event->type == SDL_JOYHATMOTION && event->jhat.which == id && event->jhat.hat < 64) {
        for (unsigned int direction = 0; direction < 4; direction++) {
            if (event->jhat.value == hat_directions[direction]) {
                return CONTROL_HAT + 4u * event->jhat.hat + direction;
            }
        }
    }
    return 0;
}

void c64_input_control_name(unsigned int control, char *label, size_t capacity)
{
    if (control >= CONTROL_HAT) {
        static const char *const names[] = {"UP", "DOWN", "LEFT", "RIGHT"};
        unsigned int index = control - CONTROL_HAT;
        snprintf(label, capacity, "HAT %u %s", index / 4 + 1, names[index % 4]);
    } else if (control >= CONTROL_AXIS) {
        unsigned int index = control - CONTROL_AXIS;
        snprintf(label, capacity, "AXIS %u %c", index / 2 + 1, index & 1 ? '+' : '-');
    } else if (control) {
        snprintf(label, capacity, "BUTTON %u", control);
    } else {
        snprintf(label, capacity, "AUTO");
    }
}
