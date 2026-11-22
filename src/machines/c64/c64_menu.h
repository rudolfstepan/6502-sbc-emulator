#ifndef C64_MENU_H
#define C64_MENU_H

#include "c64_input.h"

typedef enum {
    C64_MENU_SETTINGS,
    C64_MENU_KEYBOARD,
    C64_MENU_JOYSTICK,
    C64_MENU_PAGE_COUNT
} C64MenuPage;

typedef enum {
    C64_MENU_BROWSE,
    C64_MENU_TEXT,
    C64_MENU_BIND_KEY,
    C64_MENU_BIND_CONTROL
} C64MenuEdit;

typedef struct {
    Config *config;
    const char *filename;
    Config draft;
    bool open;
    C64MenuPage page;
    C64MenuEdit edit;
    unsigned int row;
    unsigned int first;
    char text[CFG_STR_MAX];
    size_t caret;
    bool select_all;
    const char *status;
} C64Menu;

/* Returns true if the menu consumed the event. */
bool c64_menu_event(C64Menu *menu, C64Input *input, C64 *machine, SDL_Window *window,
                    const SDL_Event *event);
void c64_menu_render(const C64Menu *menu, const C64Input *input, uint32_t *pixels,
                     unsigned int width, unsigned int height);

#endif
