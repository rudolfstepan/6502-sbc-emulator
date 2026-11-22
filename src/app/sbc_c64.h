#pragma once

#include "config/config.h"

typedef struct {
    const char *config_path;
    const char *const *load_files;
    const bool *load_starts;
    int load_count;
    const char *screenshot_path;
    int screenshot_frames;
    bool show_map;
    bool trace;
    const char *trace_path;
    bool profile;
} SbcC64Options;

int sbc_c64_run(Config *cfg, const SbcC64Options *options);
