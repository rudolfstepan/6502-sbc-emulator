#define _POSIX_C_SOURCE 200809L

#include "config.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef _WIN32
#include <windows.h>
#endif

typedef struct {
    const char *section;
    char key[24];
    const char *text;
    unsigned int number;
    bool optional;
    bool written;
} Setting;

static void write_setting(FILE *file, Setting *setting, const char *comment, const char *ending)
{
    fprintf(file, "%s =", setting->key);
    if (!setting->text) {
        fprintf(file, " %u", setting->number);
    } else if (*setting->text) {
        fprintf(file, " %s", setting->text);
    }
    if (comment) {
        fputc(' ', file);
        fputs(comment, file);
    }
    fputs(ending, file);
    setting->written = true;
}

static void write_missing(FILE *file, Setting *settings, size_t count, const char *section,
                          const char *ending)
{
    for (size_t i = 0; i < count; i++) {
        Setting *setting = &settings[i];
        if (!setting->written && strcmp(section, setting->section) == 0 &&
            (!setting->optional || setting->number)) {
            write_setting(file, setting, NULL, ending);
        }
    }
}

static char *strip(char *text)
{
    while (isspace((unsigned char)*text)) {
        text++;
    }
    char *end = text + strlen(text);
    while (end > text && isspace((unsigned char)end[-1])) {
        *--end = 0;
    }
    return text;
}

static bool merge_settings(FILE *input, FILE *output, Setting *settings, size_t count)
{
    char line[1024];
    char section[64] = "";
    const char *ending = "\n";
    bool first = true;
    bool terminated = true;
    while (fgets(line, sizeof(line), input)) {
        size_t length = strlen(line);
        terminated = length && line[length - 1] == '\n';
        if (!terminated && !feof(input)) {
            return false;
        }
        if (first && terminated) {
            ending = length > 1 && line[length - 2] == '\r' ? "\r\n" : "\n";
        }
        first = false;

        char copy[sizeof(line)];
        memcpy(copy, line, length + 1);
        char *text = strip(copy);
        if (*text == '[') {
            char *end = strchr(text + 1, ']');
            if (end && (size_t)(end - text) <= sizeof(section)) {
                write_missing(output, settings, count, section, ending);
                *end = 0;
                strcpy(section, text + 1);
            }
        } else if (*text != '#' && *text != ';') {
            char *equals = strchr(text, '=');
            if (equals) {
                *equals = 0;
                char *key = strip(text);
                for (size_t i = 0; i < count; i++) {
                    if (strcmp(settings[i].section, section) == 0 && strcmp(settings[i].key, key) == 0) {
                        write_setting(output, &settings[i], strchr(equals + 1, '#'), ending);
                        line[0] = 0;
                        terminated = true;
                        break;
                    }
                }
            }
        }
        fputs(line, output);
    }
    if (!terminated) {
        fputs(ending, output);
    }
    write_missing(output, settings, count, section, ending);
    for (size_t i = 0; i < count; i++) {
        Setting *setting = &settings[i];
        if (!setting->written && (!setting->optional || setting->number)) {
            fprintf(output, "%s[%s]%s", ending, setting->section, ending);
            write_missing(output, settings, count, setting->section, ending);
        }
    }
    return !ferror(input) && !ferror(output);
}

int config_save_c64(const Config *cfg, const char *filename)
{
    Setting settings[12 + C64_KEY_COUNT + C64_JOYSTICK_ACTIONS * 2] = {
        {"machine", "basic", cfg->c64_basic, 0, false, false},
        {"machine", "kernal", cfg->c64_kernal, 0, false, false},
        {"machine", "chargen", cfg->c64_chargen, 0, false, false},
        {"floppy", "image", cfg->c64_floppy_image, 0, false, false},
        {.section = "floppy", .key = "device", .number = cfg->c64_floppy_device},
        {.section = "video", .key = "window_scale", .number = (unsigned int)cfg->window_scale},
        {.section = "cpu", .key = "speed_hz", .number = cfg->cpu_speed_hz},
        {.section = "cpu", .key = "debug", .number = cfg->debug},
        {.section = "cpu", .key = "trace", .number = cfg->trace},
        {"cpu", "trace_file", cfg->trace_file, 0, false, false},
        {.section = "cpu", .key = "profile", .number = cfg->profile},
        {.section = "joystick", .key = "port", .number = cfg->joystick_port}
    };
    size_t count = 12;
    for (unsigned int i = 0; i < C64_KEY_COUNT; i++) {
        Setting *setting = &settings[count++];
        *setting = (Setting){.section = "keyboard", .number = cfg->c64_keys[i], .optional = true};
        snprintf(setting->key, sizeof(setting->key), "key_%u", i);
    }
    static const char *const actions[] = {"up", "down", "left", "right", "fire"};
    for (unsigned int i = 0; i < C64_JOYSTICK_ACTIONS; i++) {
        Setting *keyboard = &settings[count++];
        *keyboard = (Setting){.section = "joystick", .number = cfg->joystick_keys[i], .optional = true};
        snprintf(keyboard->key, sizeof(keyboard->key), "key_%s", actions[i]);
        Setting *control = &settings[count++];
        *control = (Setting){.section = "joystick", .number = cfg->joystick_controls[i], .optional = true};
        snprintf(control->key, sizeof(control->key), "control_%s", actions[i]);
    }

    FILE *input = fopen(filename, "rb");
    if (!input) {
        return -1;
    }
    char temporary[CFG_STR_MAX + 16];
    int length = snprintf(temporary, sizeof(temporary), "%s.tmp-XXXXXX", filename);
    if (length < 0 || (size_t)length >= sizeof(temporary)) {
        fclose(input);
        return -1;
    }
    int descriptor = mkstemp(temporary);
    FILE *output = descriptor >= 0 ? fdopen(descriptor, "wb") : NULL;
    bool ok = output && merge_settings(input, output, settings, count);
    if (output) {
        ok = fclose(output) == 0 && ok;
    } else if (descriptor >= 0) {
        close(descriptor);
    }
    fclose(input);
    if (ok) {
#ifdef _WIN32
        ok = MoveFileExA(temporary, filename, MOVEFILE_REPLACE_EXISTING) != 0;
#else
        ok = rename(temporary, filename) == 0;
#endif
    }
    if (!ok && descriptor >= 0) {
        remove(temporary);
    }
    return ok ? 0 : -1;
}
