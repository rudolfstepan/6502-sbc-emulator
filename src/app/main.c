#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sbc_c64.h"
#include "host/path.h"
#include "machines/apple2/apple2.h"
#include "machines/nes/nes.h"

#define AUTO_LOAD_MAX 16

/* ── Usage ────────────────────────────────────────────────── */
static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s [options] [config.ini]\n"
        "Options:\n"
        "  -r <rom>      load ROM file (overrides config)\n"
        "  -s <speed>    CPU speed in Hz (0=unlimited, default 27MHz FPGA)\n"
        "  --load <file> load SBC programs, C64 .d64, NES cartridge/ZIP, or Apple II disk\n"
        "  --load-data <prg> load PRG bytes without changing CPU state\n"
        "  --screenshot <bmp> save a framebuffer screenshot and exit\n"
        "  --screenshot-frames <n> rendered frames before screenshot (default 120)\n"
        "  -d            start in debug/monitor mode\n"
        "  -t [file]     enable instruction tracing (default: stderr)\n"
        "  -p            dump CPU profile on exit\n"
        "  -m            show memory map and exit\n"
        "  -h            show this help\n"
        "\n"
        "Drag and drop .prg, .rom, or .bin files onto the SDL window to load them.\n"
        "\n"
        "Default config: sbc.ini (if present)\n"
        "Default memory map:\n"
        "  $0000-$7FFF  SRAM  (32KB)\n"
        "  $8000-$87FF  VIC Video RAM (2KB)\n"
        "  $8800-$880F  VIA 6522\n"
        "  $8810-$8813  UART 6551 (ACIA)\n"
        "  $8820-$882F  DISK MVP / SD-card loader or PS/2 keyboard regs\n"
        "  $8830-$8835  SOUND (freq/duration/volume/control)\n"
        "  $88B0-$88BF  Math coprocessor\n"
        "  $A000-$CFFF  BASIC ROM, $F000-$FFFF Kernel ROM\n",
        prog);
}

static bool file_exists(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) return false;
    fclose(f);
    return true;
}

static void apply_rom_override(Config *config, const char *path)
{
    if (config->c64) {
        snprintf(config->c64_kernal, sizeof(config->c64_kernal), "%s", path);
        return;
    }
    for (int i = 0; i < config->num_devs; i++) {
        DevConfig *rom = &config->devs[i];
        if (rom->type != DEV_ROM) continue;

        if (rom->has_rom_file_offset) {
            /* An image mapped in multiple windows must be replaced as a unit. */
            for (int j = i + 1; j < config->num_devs; j++) {
                DevConfig *bank = &config->devs[j];
                if (bank->type == DEV_ROM && bank->has_rom_file_offset &&
                    strcmp(bank->rom_file, rom->rom_file) == 0) {
                    snprintf(bank->rom_file, sizeof(bank->rom_file), "%s", path);
                }
            }
        }
        snprintf(rom->rom_file, sizeof(rom->rom_file), "%s", path);
        return;
    }
}

int main(int argc, char *argv[])
{
    Config  cfg;
    char    cfg_file[256] = "sbc.ini";
    char    rom_override[256] = "";
    const char *auto_load_files[AUTO_LOAD_MAX];
    bool    auto_load_starts[AUTO_LOAD_MAX];
    int     auto_load_count = 0;
    char    screenshot_file[256] = "";
    int     speed_override = -1;
    int     screenshot_frames = 120;
    bool    debug_flag    = false;
    bool    show_map      = false;
    bool    trace_flag    = false;
    char    trace_file[256] = "";
    bool    profile_flag  = false;

    /* ── Parse arguments ─────────────────────────────────── */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-h") == 0) { usage(argv[0]); return 0; }
        if (strcmp(argv[i], "-d") == 0) { debug_flag = true; continue; }
        if (strcmp(argv[i], "-m") == 0) { show_map = true; continue; }
        if (strcmp(argv[i], "-p") == 0) { profile_flag = true; continue; }
        bool start_load = strcmp(argv[i], "--load") == 0;
        if (start_load || strcmp(argv[i], "--load-data") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "%s requires a file path\n", argv[i]);
                return 1;
            }
            const char *path = argv[++i];
            if (auto_load_count < AUTO_LOAD_MAX) {
                auto_load_files[auto_load_count] = path;
                auto_load_starts[auto_load_count++] = start_load;
            }
            continue;
        }
        if (strcmp(argv[i], "--screenshot") == 0 && i+1 < argc) {
            snprintf(screenshot_file, sizeof(screenshot_file), "%s", argv[++i]);
            continue;
        }
        if (strcmp(argv[i], "--screenshot-frames") == 0 && i+1 < argc) {
            screenshot_frames = atoi(argv[++i]);
            if (screenshot_frames < 1) screenshot_frames = 1;
            continue;
        }
        if (strcmp(argv[i], "-t") == 0) {
            trace_flag = true;
            if (i+1 < argc && argv[i+1][0] != '-') {
                snprintf(trace_file, sizeof(trace_file), "%s", argv[++i]);
            }
            continue;
        }
        if (strcmp(argv[i], "-r") == 0 && i+1 < argc) {
            snprintf(rom_override, sizeof(rom_override), "%s", argv[++i]);
            continue;
        }
        if (strcmp(argv[i], "-s") == 0 && i+1 < argc) {
            speed_override = atoi(argv[++i]); continue;
        }
        /* positional: config file, ROM path, or ROM shorthand name */
        if (path_has_suffix(argv[i], ".rom")) {
            snprintf(rom_override, sizeof(rom_override), "%s", argv[i]);
            continue;
        }

        if (!path_has_suffix(argv[i], ".ini") &&
            !strchr(argv[i], '/') && !strchr(argv[i], '\\')) {
            char candidate[256];
            snprintf(candidate, sizeof(candidate), "roms/%s.rom", argv[i]);
            if (file_exists(candidate)) {
                snprintf(rom_override, sizeof(rom_override), "%s", candidate);
                continue;
            }
            snprintf(candidate, sizeof(candidate), "bin/roms/%s.rom", argv[i]);
            if (file_exists(candidate)) {
                snprintf(rom_override, sizeof(rom_override), "%s", candidate);
                continue;
            }
        }

        snprintf(cfg_file, sizeof(cfg_file), "%s", argv[i]);
    }

    /* ── Load config ─────────────────────────────────────── */
    memset(&cfg, 0, sizeof(cfg));
    int config_status = config_load(&cfg, cfg_file);
    if (config_status == -2) return 1;
    if (config_status != 0) {
        fprintf(stderr, "No config file found, using defaults.\n");
    }
    config_defaults(&cfg);

    if (cfg.apple2) {
        if (auto_load_count > 1 || (auto_load_count && !auto_load_starts[0]) ||
            debug_flag || show_map || trace_flag || profile_flag || speed_override >= 0 ||
            rom_override[0]) {
            fprintf(stderr, "Apple II Plus mode takes a single disk via --load.\n"
                            "Configure firmware in the [apple2] INI section.\n");
            return 1;
        }
        return apple2_run(&cfg, auto_load_count ? auto_load_files[0] : NULL,
                          screenshot_file, screenshot_frames);
    }

    if (cfg.nes) {
        if (auto_load_count > 1 || (auto_load_count && !auto_load_starts[0]) ||
            debug_flag || show_map || trace_flag || profile_flag || speed_override >= 0 ||
            rom_override[0]) {
            fprintf(stderr, "NES mode takes a single cartridge via --load. "
                            "SBC/C64 CPU and ROM options are unavailable.\n");
            return 1;
        }
        return nes_run(&cfg, auto_load_count ? auto_load_files[0] : NULL,
                       screenshot_file, screenshot_frames);
    }

    if (speed_override >= 0)
        cfg.cpu_speed_hz = (uint32_t)speed_override;
    if (debug_flag)
        cfg.debug = true;

    if (rom_override[0]) apply_rom_override(&cfg, rom_override);

    const SbcC64Options options = {
        .config_path = cfg_file,
        .load_files = auto_load_files,
        .load_starts = auto_load_starts,
        .load_count = auto_load_count,
        .screenshot_path = screenshot_file,
        .screenshot_frames = screenshot_frames,
        .show_map = show_map,
        .trace = trace_flag,
        .trace_path = trace_file,
        .profile = profile_flag,
    };
    return sbc_c64_run(&cfg, &options);
}
