#define _POSIX_C_SOURCE 200809L

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "config.h"

static void write_config(const char *path, const char *contents)
{
    FILE *file = fopen(path, "w");
    assert(file != NULL);
    assert(fputs(contents, file) >= 0);
    assert(fclose(file) == 0);
}

static void check_window_scale(const char *path, const char *contents, int expected)
{
    write_config(path, contents);
    Config cfg;
    assert(config_load(&cfg, path) == 0);
    config_defaults(&cfg);
    assert(cfg.window_scale == expected);
}

static void check_nes_profile(const char *path)
{
    write_config(path, "[nes]\nrom_dir = E:/Emulatoren/Nintendo/Roms\n"
                      "rom = USA/Game #1.zip\ncore = bin/cores/fceumm_libretro.dll\n"
                      "[machine]\ntype = nes\n");
    Config cfg;
    assert(config_load(&cfg, path) == 0);
    config_defaults(&cfg);
    assert(cfg.nes && !cfg.c64 && cfg.num_devs == 0);
    assert(strcmp(cfg.nes_rom_dir, "E:/Emulatoren/Nintendo/Roms") == 0);
    assert(strcmp(cfg.nes_rom, "USA/Game #1.zip") == 0);
    assert(strcmp(cfg.nes_core, "bin/cores/fceumm_libretro.dll") == 0);
}

int main(int argc, char *argv[])
{
    assert(argc == 2);
    char path[CFG_STR_MAX];
    int length = snprintf(path, sizeof(path), "%s/test-config-XXXXXX", argv[1]);
    assert(length > 0 && (size_t)length < sizeof(path));
    int fd = mkstemp(path);
    assert(fd >= 0);
    assert(close(fd) == 0);

    check_window_scale(path, "[cpu]\nwindow_scale = 1\n", 2);
    check_window_scale(path, "[video]\nwindow_scale = 1 # Native size\n", 1);
    check_window_scale(path, "[video]\nwindow_scale = 25\n", 25);
    check_window_scale(path, "[video]\nwindow_scale = 0\n", 2);
    check_window_scale(path, "[video]\nwindow_scale = -1\n", 2);
    check_window_scale(path, "[video]\nwindow_scale = 26\n", 2);
    check_window_scale(path, "[video]\nwindow_scale = 1.5\n", 2);
    check_window_scale(path, "[video]\nwindow_scale = \n", 2);
    check_window_scale(path, "[video]\nwindow_scale = 9999999999999999999999\n", 2);
    check_nes_profile(path);

    assert(unlink(path) == 0);
    puts("test_config: ok");
    return 0;
}
