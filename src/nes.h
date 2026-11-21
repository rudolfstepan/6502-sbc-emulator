#pragma once

#include "config.h"

int nes_run(const Config *cfg, const char *rom_override,
            const char *screenshot, int screenshot_frames);
