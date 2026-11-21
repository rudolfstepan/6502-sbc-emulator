#include "c64_menu.h"

#include "simd.h"
#include "vic.h"

#include <ctype.h>
#include <errno.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    ROW_SCALE, ROW_SPEED, ROW_FLOPPY_DEVICE, ROW_FLOPPY_IMAGE,
    ROW_BASIC, ROW_KERNAL, ROW_CHARGEN, ROW_DEBUG, ROW_TRACE, ROW_TRACE_FILE, ROW_PROFILE,
    SETTINGS_ROWS,
    VISIBLE_ROWS = 16,
    JOYSTICK_ROWS = 1 + 2 * C64_JOYSTICK_ACTIONS
};

static const char *const action_names[] = {"UP", "DOWN", "LEFT", "RIGHT", "FIRE"};

static unsigned int rows(C64MenuPage page)
{
    static const unsigned int counts[] = {SETTINGS_ROWS, C64_KEY_COUNT, JOYSTICK_ROWS};
    return counts[page];
}

static size_t path_offset(unsigned int row)
{
    switch (row) {
    case ROW_FLOPPY_IMAGE: return offsetof(Config, c64_floppy_image);
    case ROW_BASIC: return offsetof(Config, c64_basic);
    case ROW_KERNAL: return offsetof(Config, c64_kernal);
    case ROW_CHARGEN: return offsetof(Config, c64_chargen);
    case ROW_TRACE_FILE: return offsetof(Config, trace_file);
    default: return 0;
    }
}

static void move_row(C64Menu *menu, int step)
{
    int next = (int)menu->row + step;
    if (next < 0) {
        next = 0;
    } else if ((unsigned int)next >= rows(menu->page)) {
        next = (int)rows(menu->page) - 1;
    }
    menu->row = (unsigned int)next;
    if (menu->row < menu->first) {
        menu->first = menu->row;
    } else if (menu->row >= menu->first + VISIBLE_ROWS) {
        menu->first = menu->row - VISIBLE_ROWS + 1;
    }
}

static unsigned int adjust(unsigned int value, int step, unsigned int minimum, unsigned int maximum)
{
    if (step < 0) {
        return value > minimum ? value - 1 : minimum;
    }
    return value < maximum ? value + 1 : maximum;
}

static void adjust_row(C64Menu *menu, int step)
{
    Config *config = &menu->draft;
    if (menu->page == C64_MENU_JOYSTICK && menu->row == 0) {
        config->joystick_port = adjust(config->joystick_port, step, 0, 2);
    }
    if (menu->page != C64_MENU_SETTINGS) {
        return;
    }
    switch (menu->row) {
    case ROW_SCALE:
        config->window_scale = (int)adjust((unsigned int)config->window_scale, step, 1, CFG_MAX_WINDOW_SCALE);
        break;
    case ROW_FLOPPY_DEVICE:
        config->c64_floppy_device = adjust(config->c64_floppy_device, step, 8, 11);
        break;
    case ROW_DEBUG: config->debug = !config->debug; break;
    case ROW_TRACE: config->trace = !config->trace; break;
    case ROW_PROFILE: config->profile = !config->profile; break;
    default: break;
    }
}

static uint16_t *binding(C64Menu *menu)
{
    if (menu->page == C64_MENU_KEYBOARD) {
        return &menu->draft.c64_keys[menu->row];
    }
    if (menu->page == C64_MENU_JOYSTICK && menu->row > 0) {
        if (menu->row <= C64_JOYSTICK_ACTIONS) {
            return &menu->draft.joystick_keys[menu->row - 1];
        }
        return &menu->draft.joystick_controls[menu->row - 1 - C64_JOYSTICK_ACTIONS];
    }
    return NULL;
}

static void begin_edit(C64Menu *menu)
{
    if (binding(menu)) {
        menu->edit = menu->page == C64_MENU_JOYSTICK && menu->row > C64_JOYSTICK_ACTIONS
            ? C64_MENU_BIND_CONTROL : C64_MENU_BIND_KEY;
        return;
    }
    size_t offset = menu->page == C64_MENU_SETTINGS ? path_offset(menu->row) : 0;
    if (offset || (menu->page == C64_MENU_SETTINGS && menu->row == ROW_SPEED)) {
        if (offset) {
            snprintf(menu->text, sizeof(menu->text), "%s", (const char *)&menu->draft + offset);
        } else {
            snprintf(menu->text, sizeof(menu->text), "%u", menu->draft.cpu_speed_hz);
        }
        menu->edit = C64_MENU_TEXT;
        menu->caret = strlen(menu->text);
        menu->select_all = true;
    } else {
        adjust_row(menu, 1);
    }
}

static void insert_text(C64Menu *menu, const char *value)
{
    size_t length = strlen(value);
    size_t old = menu->select_all ? 0 : strlen(menu->text);
    if (length + old >= sizeof(menu->text) || strpbrk(value, "\r\n#")) {
        menu->status = "TEXT TOO LONG OR INVALID CHARACTER";
        return;
    }
    if (menu->select_all) {
        menu->text[0] = 0;
        menu->caret = 0;
        menu->select_all = false;
    }
    memmove(menu->text + menu->caret + length, menu->text + menu->caret, old - menu->caret + 1);
    memcpy(menu->text + menu->caret, value, length);
    menu->caret += length;
    menu->status = NULL;
}

static size_t previous_character(const char *text, size_t pos)
{
    while (pos && ((unsigned char)text[--pos] & 0xC0) == 0x80) {
    }
    return pos;
}

static size_t next_character(const char *text, size_t pos)
{
    if (text[pos]) {
        do {
            pos++;
        } while (((unsigned char)text[pos] & 0xC0) == 0x80);
    }
    return pos;
}

static void text_key(C64Menu *menu, const SDL_Keysym *key)
{
    if (key->mod & KMOD_CTRL) {
        if (key->sym == SDLK_a) {
            menu->select_all = true;
        } else if (key->sym == SDLK_v) {
            char *value = SDL_GetClipboardText();
            if (value) {
                insert_text(menu, value);
                SDL_free(value);
            }
        }
        return;
    }

    switch (key->sym) {
    case SDLK_ESCAPE:
        menu->edit = C64_MENU_BROWSE;
        return;
    case SDLK_RETURN:
    case SDLK_KP_ENTER: {
        size_t offset = path_offset(menu->row);
        if (offset) {
            strcpy((char *)&menu->draft + offset, menu->text);
        } else {
            char *end;
            errno = 0;
            unsigned long value = strtoul(menu->text, &end, 10);
            if (errno || !isdigit((unsigned char)menu->text[0]) || *end || value > UINT32_MAX) {
                menu->status = "ENTER A VALID FREQUENCY IN HZ";
                return;
            }
            menu->draft.cpu_speed_hz = (uint32_t)value;
        }
        menu->edit = C64_MENU_BROWSE;
        menu->status = NULL;
        return;
    }
    case SDLK_BACKSPACE:
    case SDLK_DELETE:
        if (menu->select_all) {
            menu->text[0] = 0;
            menu->caret = 0;
        } else if (key->sym == SDLK_BACKSPACE && menu->caret) {
            size_t prev = previous_character(menu->text, menu->caret);
            memmove(menu->text + prev, menu->text + menu->caret, strlen(menu->text + menu->caret) + 1);
            menu->caret = prev;
        } else if (key->sym == SDLK_DELETE) {
            size_t next = next_character(menu->text, menu->caret);
            memmove(menu->text + menu->caret, menu->text + next, strlen(menu->text + next) + 1);
        }
        break;
    case SDLK_LEFT: menu->caret = previous_character(menu->text, menu->caret); break;
    case SDLK_RIGHT: menu->caret = next_character(menu->text, menu->caret); break;
    case SDLK_HOME: menu->caret = 0; break;
    case SDLK_END: menu->caret = strlen(menu->text); break;
    default: return;
    }
    menu->select_all = false;
}

static void save_menu(C64Menu *menu, SDL_Window *window)
{
    if (config_save_c64(&menu->draft, menu->filename) != 0) {
        menu->status = "SAVE FAILED. CHECK THE INI FILE.";
        return;
    }
    int previous_scale = menu->config->window_scale;
    *menu->config = menu->draft;
    if (previous_scale != menu->config->window_scale) {
        SDL_SetWindowSize(window, 2 * C64_VIDEO_WIDTH * menu->config->window_scale,
                         2 * C64_VIDEO_HEIGHT * menu->config->window_scale);
    }
    menu->status = "SAVED. * SETTINGS APPLY AT NEXT START.";
}

static void set_key_binding(C64Menu *menu, SDL_Scancode scan)
{
    if (scan <= SDL_SCANCODE_UNKNOWN || scan >= SDL_NUM_SCANCODES) {
        return;
    }
    uint16_t *target = binding(menu);
    if (menu->page == C64_MENU_KEYBOARD) {
        for (unsigned int i = 0; i < C64_KEY_COUNT; i++) {
            if (menu->draft.c64_keys[i] == scan) {
                menu->draft.c64_keys[i] = 0;
            }
        }
    }
    *target = (uint16_t)scan;
    menu->edit = C64_MENU_BROWSE;
}

bool c64_menu_event(C64Menu *menu, C64Input *input, C64 *machine, SDL_Window *window,
                    const SDL_Event *event)
{
    if (!menu->config || !machine) {
        return false;
    }
    if (event->type == SDL_KEYDOWN && event->key.keysym.sym == SDLK_F12) {
        if (!event->key.repeat) {
            menu->open = !menu->open;
            menu->edit = C64_MENU_BROWSE;
            if (menu->open) {
                menu->draft = *menu->config;
                menu->status = NULL;
            }
            c64_input_clear(input, machine);
        }
        return true;
    }
    if (!menu->open) {
        return false;
    }

    if (event->type == SDL_DROPFILE) {
        char *path = event->drop.file;
        size_t length = path ? strlen(path) : 0;
        if (length >= 4 && length < sizeof(menu->draft.c64_floppy_image) &&
            SDL_strcasecmp(path + length - 4, ".d64") == 0 && !strpbrk(path, "\r\n#")) {
            strcpy(menu->draft.c64_floppy_image, path);
            menu->page = C64_MENU_SETTINGS;
            menu->row = ROW_FLOPPY_IMAGE;
            menu->first = 0;
            menu->edit = C64_MENU_BROWSE;
            menu->status = "START IMAGE SELECTED. F2 TO SAVE.";
        } else {
            menu->status = "DROP A D64 WITH A VALID PATH.";
        }
        SDL_free(path);
        return true;
    }

    if (menu->edit == C64_MENU_TEXT && event->type == SDL_TEXTINPUT) {
        insert_text(menu, event->text.text);
        return true;
    }
    if (menu->edit == C64_MENU_BIND_CONTROL) {
        unsigned int control = c64_input_capture_control(input, event);
        if (control) {
            *binding(menu) = (uint16_t)control;
            menu->edit = C64_MENU_BROWSE;
            return true;
        }
    }
    if (event->type != SDL_KEYDOWN) {
        return event->type == SDL_KEYUP || event->type == SDL_TEXTINPUT;
    }

    const SDL_Keysym *key = &event->key.keysym;
    if (menu->edit == C64_MENU_TEXT) {
        text_key(menu, key);
        return true;
    }
    if (menu->edit == C64_MENU_BIND_KEY) {
        if (!event->key.repeat) {
            set_key_binding(menu, key->scancode);
        }
        return true;
    }
    if (menu->edit == C64_MENU_BIND_CONTROL) {
        if (key->sym == SDLK_ESCAPE) {
            menu->edit = C64_MENU_BROWSE;
        }
        return true;
    }

    menu->status = NULL;
    switch (key->sym) {
    case SDLK_ESCAPE:
        menu->open = false;
        c64_input_clear(input, machine);
        break;
    case SDLK_TAB:
        if (!event->key.repeat) {
            menu->page = (menu->page + ((key->mod & KMOD_SHIFT) ? C64_MENU_PAGE_COUNT - 1 : 1)) % C64_MENU_PAGE_COUNT;
            menu->row = menu->first = 0;
        }
        break;
    case SDLK_UP: move_row(menu, -1); break;
    case SDLK_DOWN: move_row(menu, 1); break;
    case SDLK_PAGEUP: move_row(menu, -VISIBLE_ROWS); break;
    case SDLK_PAGEDOWN: move_row(menu, VISIBLE_ROWS); break;
    case SDLK_LEFT: adjust_row(menu, -1); break;
    case SDLK_RIGHT: adjust_row(menu, 1); break;
    case SDLK_RETURN:
    case SDLK_KP_ENTER:
        if (!event->key.repeat) {
            begin_edit(menu);
        }
        break;
    case SDLK_DELETE: {
        uint16_t *value = binding(menu);
        if (value) {
            *value = 0;
        }
        break;
    }
    case SDLK_F2:
        if (!event->key.repeat) {
            save_menu(menu, window);
        }
        break;
    default: break;
    }
    return true;
}

static void setting_row(const C64Menu *menu, unsigned int row, char *line, size_t capacity)
{
    static const char *const names[] = {
        "WINDOW SCALE", "CPU SPEED HZ *", "FLOPPY DEVICE *", "START IMAGE *",
        "BASIC ROM *", "KERNAL ROM *", "CHARACTER ROM *", "DEBUG AT START *",
        "CPU TRACE *", "TRACE FILE *", "CPU PROFILE *"
    };
    const Config *config = &menu->draft;
    size_t offset = path_offset(row);
    const char *value = offset ? (const char *)config + offset : NULL;
    char number[32];
    if (!value) {
        switch (row) {
        case ROW_SCALE: snprintf(number, sizeof(number), "%dx", config->window_scale); break;
        case ROW_SPEED: snprintf(number, sizeof(number), "%u", config->cpu_speed_hz); break;
        case ROW_FLOPPY_DEVICE: snprintf(number, sizeof(number), "%u", config->c64_floppy_device); break;
        case ROW_DEBUG: strcpy(number, config->debug ? "ON" : "OFF"); break;
        case ROW_TRACE: strcpy(number, config->trace ? "ON" : "OFF"); break;
        default: strcpy(number, config->profile ? "ON" : "OFF"); break;
        }
        value = number;
    }
    size_t length = strlen(value);
    if (length > 20) {
        snprintf(line, capacity, "%-17s ...%.17s", names[row], value + length - 17);
    } else {
        snprintf(line, capacity, "%-17s %.20s", names[row], *value ? value : "(EMPTY)");
    }
}

static void binding_row(const C64Menu *menu, unsigned int row, char *line, size_t capacity)
{
    const Config *config = &menu->draft;
    if (menu->page == C64_MENU_KEYBOARD) {
        SDL_Scancode scan = (SDL_Scancode)config->c64_keys[row];
        const char *key = scan ? SDL_GetScancodeName(scan) : SDL_GetKeyName(c64_input_default_key(row));
        snprintf(line, capacity, "%-17s %.20s", c64_input_key_name(row), key);
    } else if (row == 0) {
        static const char *const ports[] = {"OFF", "PORT 1", "PORT 2"};
        snprintf(line, capacity, "%-17s %s", "C64 JOYSTICK", ports[config->joystick_port]);
    } else if (row <= C64_JOYSTICK_ACTIONS) {
        unsigned int action = row - 1;
        snprintf(line, capacity, "KEY %-13s %.20s", action_names[action],
                 SDL_GetScancodeName(c64_input_joystick_key(config, action)));
    } else {
        unsigned int action = row - 1 - C64_JOYSTICK_ACTIONS;
        char label[24];
        c64_input_control_name(config->joystick_controls[action], label, sizeof(label));
        snprintf(line, capacity, "PAD %-13s %.20s", action_names[action], label);
    }
}

static const uint8_t *menu_glyph(unsigned char character)
{
    /* The SBC font uses these ASCII code points for line graphics. */
    static const uint8_t lowercase[26][8] = {
        {0x00,0x00,0x1C,0x20,0x3C,0x22,0x3C,0x00}, /* a */
        {0x02,0x02,0x1E,0x22,0x22,0x22,0x1E,0x00},
        {0x00,0x00,0x3C,0x02,0x02,0x02,0x3C,0x00},
        {0x20,0x20,0x3C,0x22,0x22,0x22,0x3C,0x00},
        {0x00,0x00,0x1C,0x22,0x3E,0x02,0x3C,0x00},
        {0x18,0x24,0x04,0x1E,0x04,0x04,0x04,0x00},
        {0x00,0x00,0x3C,0x22,0x22,0x3C,0x20,0x1C},
        {0x02,0x02,0x1E,0x22,0x22,0x22,0x22,0x00},
        {0x08,0x00,0x0C,0x08,0x08,0x08,0x1C,0x00},
        {0x10,0x00,0x18,0x10,0x10,0x10,0x12,0x0C},
        {0x02,0x02,0x22,0x12,0x0E,0x12,0x22,0x00},
        {0x0C,0x08,0x08,0x08,0x08,0x08,0x1C,0x00},
        {0x00,0x00,0x36,0x2A,0x2A,0x22,0x22,0x00},
        {0x00,0x00,0x1E,0x22,0x22,0x22,0x22,0x00},
        {0x00,0x00,0x1C,0x22,0x22,0x22,0x1C,0x00},
        {0x00,0x00,0x1E,0x22,0x22,0x1E,0x02,0x02},
        {0x00,0x00,0x3C,0x22,0x22,0x3C,0x20,0x20},
        {0x00,0x00,0x1A,0x26,0x02,0x02,0x02,0x00},
        {0x00,0x00,0x3C,0x02,0x1C,0x20,0x1E,0x00},
        {0x04,0x04,0x1E,0x04,0x04,0x04,0x18,0x00},
        {0x00,0x00,0x22,0x22,0x22,0x32,0x2C,0x00},
        {0x00,0x00,0x22,0x22,0x22,0x14,0x08,0x00},
        {0x00,0x00,0x22,0x22,0x2A,0x2A,0x14,0x00},
        {0x00,0x00,0x22,0x14,0x08,0x14,0x22,0x00},
        {0x00,0x00,0x22,0x22,0x22,0x3C,0x20,0x1C},
        {0x00,0x00,0x3E,0x10,0x08,0x04,0x3E,0x00}  /* z */
    };
    if (character >= 'a' && character <= 'z') {
        return lowercase[character - 'a'];
    }
    return vic_get_char_pattern(character < 0x80 ? character : '?');
}

static void draw_text(uint32_t *pixels, unsigned int width, unsigned int row, unsigned int col,
                      const char *text, uint32_t fg, uint32_t bg)
{
    for (; *text && col < width / 16; text++, col++) {
        const uint8_t *glyph = menu_glyph((unsigned char)*text);
        uint32_t *start = pixels + row * 16 * width + col * 16;
        for (unsigned int y = 0; y < 8; y++) {
            simd_render_char_row_x2(start + y * 2 * width, width, glyph[y], fg, bg);
        }
    }
}

void c64_menu_render(const C64Menu *menu, const C64Input *input, uint32_t *pixels,
                     unsigned int width, unsigned int height)
{
    const uint32_t background = 0xFF151B2A, foreground = 0xFFE8EDF5;
    const uint32_t highlight = 0xFFBED9FF, ink = 0xFF161C2A;
    simd_fill_u32(pixels, background, (size_t)width * height);
    draw_text(pixels, width, 0, 1, "C64 CONFIGURATION", foreground, background);
    static const char *const tab_labels[] = {"SETTINGS", "KEYBOARD", "JOYSTICK"};
    for (unsigned int page = 0; page < C64_MENU_PAGE_COUNT; page++) {
        bool selected = menu->page == page;
        draw_text(pixels, width, 2, 1 + page * 13, tab_labels[page],
                  selected ? ink : foreground, selected ? highlight : background);
    }

    for (unsigned int i = 0; i < VISIBLE_ROWS && menu->first + i < rows(menu->page); i++) {
        unsigned int row = menu->first + i;
        char line[39];
        if (menu->page == C64_MENU_SETTINGS) {
            setting_row(menu, row, line, sizeof(line));
        } else {
            binding_row(menu, row, line, sizeof(line));
        }
        if (row == menu->row) {
            size_t length = strlen(line);
            memset(line + length, ' ', sizeof(line) - length - 1);
            line[sizeof(line) - 1] = 0;
        }
        draw_text(pixels, width, 4 + i, 1, line, row == menu->row ? ink : foreground,
                  row == menu->row ? highlight : background);
    }

    if (menu->edit == C64_MENU_TEXT) {
        size_t start = menu->caret > 35 ? menu->caret - 35 : 0;
        char text[39];
        snprintf(text, sizeof(text), "%.38s", menu->text + start);
        draw_text(pixels, width, 20, 1, text, ink, highlight);
        draw_text(pixels, width, 21, 1 + (unsigned int)(menu->caret - start), "^", foreground, background);
        draw_text(pixels, width, 23, 1, "ENTER ACCEPT   ESC CANCEL   CTRL+V PASTE", foreground, background);
    } else if (menu->edit == C64_MENU_BIND_KEY) {
        draw_text(pixels, width, 22, 1, "PRESS A KEY   F12 CLOSES MENU", foreground, background);
    } else if (menu->edit == C64_MENU_BIND_CONTROL) {
        draw_text(pixels, width, 22, 1, input->joystick ? "MOVE STICK OR PRESS BUTTON   ESC BACK"
                                                       : "CONNECT A JOYSTICK   ESC BACK", foreground, background);
    } else {
        draw_text(pixels, width, 20, 1, "TAB PAGE   UP/DOWN SELECT", foreground, background);
        draw_text(pixels, width, 21, 1, "LEFT/RIGHT CHANGE   ENTER EDIT", foreground, background);
        draw_text(pixels, width, 22, 1, "F2 SAVE  DEL DEFAULT  F12 CLOSE", foreground, background);
        if (menu->page == C64_MENU_SETTINGS) {
            draw_text(pixels, width, 23, 1, "* NEXT START   CPU 0 = UNLIMITED", foreground, background);
        } else if (menu->page == C64_MENU_JOYSTICK) {
            draw_text(pixels, width, 23, 1, input->joystick ? "JOYSTICK CONNECTED" : "NO USB JOYSTICK CONNECTED", foreground, background);
        }
    }
    if (menu->status) {
        draw_text(pixels, width, 24, 1, menu->status, highlight, background);
    }
}
