#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <time.h>
#include <errno.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif

#include "cpu6502.h"
#include "bus.h"
#include "sram.h"
#include "rom.h"
#include "via6522.h"
#include "uart6551.h"
#include "diskdev.h"
#include "monitor.h"
#include "config.h"
#include "disasm.h"
#include "vic.h"
#include "vic_sdl.h"
#include "keyboard.h"
#include "soundchip.h"
#include "math_copro.h"
#include "cia6526.h"
#include "sid_stub.h"

/* ── Global emulator state ────────────────────────────────── */
static volatile int g_sigint = 0;
static VIA6522 *g_keyboard_via = NULL;  /* Global VIA for keyboard input */
static KeyboardRegs *g_keyboard_regs = NULL;

#define AUTO_LOAD_MAX 16

typedef struct {
    ROM     *rom;
    uint16_t base;
    uint32_t size;
    uint32_t file_offset;
    bool     has_file_offset;
} RomSlot;

typedef struct {
    Bus      *bus;
    CPU6502  *cpu;
    RomSlot  *rom_slots;
    int       rom_count;
} DropLoadContext;

static void handle_sigint(int sig)
{
    (void)sig;
    g_sigint = 1;
}

/* Get the keyboard VIA for external access (e.g., from SDL) */
VIA6522* get_keyboard_via(void)
{
    return g_keyboard_via;
}

KeyboardRegs* get_keyboard_regs(void)
{
    return g_keyboard_regs;
}

/* ── Bus read/write wrappers for CPU ─────────────────────── */
static uint8_t cpu_bus_read(void *ctx, uint16_t addr)
{
    return bus_read((Bus *)ctx, addr);
}
static void cpu_bus_write(void *ctx, uint16_t addr, uint8_t val)
{
    bus_write((Bus *)ctx, addr, val);
}

/* ── Portable monotonic timing and sleep helpers ─────────── */
#ifdef _WIN32
static void monotonic_now(struct timespec *ts)
{
    static LARGE_INTEGER freq;
    static int initialized = 0;
    LARGE_INTEGER counter;

    if (!initialized) {
        QueryPerformanceFrequency(&freq);
        initialized = 1;
    }

    QueryPerformanceCounter(&counter);
    ts->tv_sec = (time_t)(counter.QuadPart / freq.QuadPart);
    ts->tv_nsec = (long)(((counter.QuadPart % freq.QuadPart) * 1000000000LL) / freq.QuadPart);
}

static void ns_sleep(long ns)
{
    if (ns <= 0) {
        return;
    }
    Sleep((DWORD)((ns + 999999L) / 1000000L));
}
#else
static void monotonic_now(struct timespec *ts)
{
    clock_gettime(CLOCK_MONOTONIC, ts);
}

static void ns_sleep(long ns)
{
    struct timespec ts = { .tv_sec = 0, .tv_nsec = ns };
    nanosleep(&ts, NULL);
}
#endif

/* ── Usage ────────────────────────────────────────────────── */
static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s [options] [config.ini]\n"
        "Options:\n"
        "  -r <rom>      load ROM file (overrides config)\n"
        "  -s <speed>    CPU speed in Hz (0=unlimited, default 27MHz FPGA)\n"
        "  --load <file> load .prg/.rom/.bin like drag and drop after startup\n"
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
        "  $8820-$8823  PS/2 keyboard registers\n"
        "  $8824-$882F  DISK MVP\n"
        "  $8830-$8835  SOUND (freq/duration/volume/control)\n"
        "  $88B0-$88BF  Math coprocessor\n"
        "  $A000-$CFFF  BASIC ROM, $F000-$FFFF Kernel ROM\n",
        prog);
}

static bool ends_with_ignore_case(const char *s, const char *suffix)
{
    size_t slen = strlen(s);
    size_t tlen = strlen(suffix);
    if (slen < tlen) return false;
    const char *a = s + (slen - tlen);
    for (size_t i = 0; i < tlen; i++) {
        char ca = a[i];
        char cb = suffix[i];
        if (ca >= 'A' && ca <= 'Z') ca = (char)(ca - 'A' + 'a');
        if (cb >= 'A' && cb <= 'Z') cb = (char)(cb - 'A' + 'a');
        if (ca != cb) return false;
    }
    return true;
}

static bool file_exists(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) return false;
    fclose(f);
    return true;
}

static const char *path_basename(const char *path)
{
    const char *slash = strrchr(path, '/');
    const char *backslash = strrchr(path, '\\');
    const char *base = slash > backslash ? slash : backslash;
    return base ? base + 1 : path;
}

static long file_size(FILE *f)
{
    long pos = ftell(f);
    if (pos < 0) return -1;
    if (fseek(f, 0, SEEK_END) != 0) return -1;
    long size = ftell(f);
    if (fseek(f, pos, SEEK_SET) != 0) return -1;
    return size;
}

static void refresh_rom_bus_fastpath(Bus *bus, ROM *rom)
{
    for (int i = 0; i < bus->num_devices; i++) {
        if (bus->devices[i].device == rom) {
            bus->devices[i].linear_data = rom->data;
            bus->devices[i].linear_flags = 0;
        }
    }
}

static int load_prg_file(Bus *bus, CPU6502 *cpu, const char *path, bool start)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "drop: cannot open PRG '%s': %s\n", path, strerror(errno));
        return -1;
    }

    long size = file_size(f);
    if (size < 3) {
        fclose(f);
        fprintf(stderr, "drop: PRG '%s' is too small\n", path);
        return -1;
    }

    int lo = fgetc(f);
    int hi = fgetc(f);
    if (lo == EOF || hi == EOF) {
        fclose(f);
        fprintf(stderr, "drop: PRG '%s' has no load address\n", path);
        return -1;
    }

    uint16_t load_addr = (uint16_t)((uint8_t)lo | ((uint16_t)(uint8_t)hi << 8));
    uint16_t addr = load_addr;
    long payload = 0;
    int c;
    while ((c = fgetc(f)) != EOF) {
        bus_write(bus, addr++, (uint8_t)c);
        payload++;
    }
    fclose(f);

    if (start) {
        cpu->A = cpu->X = cpu->Y = 0;
        cpu->SP = 0xFD;
        cpu->P = FLAG_U | FLAG_I;
        cpu->PC = load_addr;
        cpu->stopped = false;
        cpu->reset_pending = false;
        cpu->nmi_pending = false;
        cpu->irq_pending = false;

        printf("\ndrop: loaded PRG '%s' at $%04X (%ld bytes), PC=$%04X\n",
               path_basename(path), load_addr, payload, cpu->PC);
    } else {
        printf("\ndrop: loaded PRG data '%s' at $%04X (%ld bytes)\n",
               path_basename(path), load_addr, payload);
    }
    return 0;
}

static int load_rom_file(DropLoadContext *ctx, const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "drop: cannot open ROM '%s': %s\n", path, strerror(errno));
        return -1;
    }
    long size = file_size(f);
    fclose(f);
    if (size <= 0) {
        fprintf(stderr, "drop: ROM '%s' is empty\n", path);
        return -1;
    }

    bool split_rom = false;
    for (int i = 0; i < ctx->rom_count; i++) {
        split_rom = split_rom || ctx->rom_slots[i].has_file_offset;
    }

    int loaded = 0;
    for (int i = 0; i < ctx->rom_count; i++) {
        RomSlot *slot = &ctx->rom_slots[i];
        bool should_load = false;
        uint32_t offset = 0;

        if (split_rom && slot->has_file_offset) {
            offset = slot->file_offset;
            if (size == 0x4000) {
                should_load = (uint32_t)size > offset;
            } else if ((uint32_t)size == slot->size) {
                offset = 0;
                should_load = true;
            } else if (slot->base == 0xA000 && (uint32_t)size < slot->size) {
                offset = 0;
                should_load = true;
            }
        } else if ((uint32_t)size <= slot->size) {
            should_load = true;
        } else if (ctx->rom_count == 1) {
            should_load = true;
        }

        if (!should_load) {
            continue;
        }

        rom_free(slot->rom);
        int rc = slot->has_file_offset || (uint32_t)size > slot->size
            ? rom_load_segment(slot->rom, path, slot->size, offset)
            : rom_load(slot->rom, path, slot->size);
        if (rc != 0) {
            rom_init(slot->rom, slot->size);
            refresh_rom_bus_fastpath(ctx->bus, slot->rom);
            fprintf(stderr, "drop: failed to load ROM window $%04X-$%04X\n",
                    slot->base, (uint16_t)(slot->base + slot->size - 1));
            return -1;
        }
        refresh_rom_bus_fastpath(ctx->bus, slot->rom);
        loaded++;
    }

    if (loaded == 0) {
        fprintf(stderr, "drop: ROM '%s' does not fit any configured ROM window\n",
                path_basename(path));
        return -1;
    }

    ctx->cpu->stopped = false;
    cpu6502_reset(ctx->cpu);
    printf("\ndrop: loaded ROM '%s' into %d window(s), CPU reset requested\n",
           path_basename(path), loaded);
    return 0;
}

static void handle_load_file(const char *path, void *user, bool start_prg)
{
    DropLoadContext *ctx = (DropLoadContext *)user;
    if (!path || !ctx) {
        return;
    }

    if (ends_with_ignore_case(path, ".prg")) {
        load_prg_file(ctx->bus, ctx->cpu, path, start_prg);
    } else if (ends_with_ignore_case(path, ".rom") ||
               ends_with_ignore_case(path, ".bin")) {
        load_rom_file(ctx, path);
    } else {
        fprintf(stderr, "\ndrop: unsupported file '%s' (use .prg, .rom, or .bin)\n",
                path_basename(path));
    }
}

static void handle_drop_file(const char *path, void *user)
{
    handle_load_file(path, user, true);
}

static bool maybe_save_screenshot(const char *path,
                                  int *frames_seen,
                                  int target_frames,
                                  bool *saved)
{
    if (!path || !*path || *saved) {
        return false;
    }

    (*frames_seen)++;
    if (*frames_seen < target_frames) {
        return false;
    }

    if (vic_sdl_save_screenshot(path) == 0) {
        *saved = true;
    }
    return true;
}

int main(int argc, char *argv[])
{
    Config  cfg;
    char    cfg_file[256] = "sbc.ini";
    char    rom_override[256] = "";
    char    auto_load_files[AUTO_LOAD_MAX][256];
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
        if (strcmp(argv[i], "--load") == 0 && i+1 < argc) {
            if (auto_load_count < AUTO_LOAD_MAX) {
                snprintf(auto_load_files[auto_load_count],
                         sizeof(auto_load_files[auto_load_count]), "%s", argv[++i]);
                auto_load_starts[auto_load_count++] = true;
            } else {
                i++;
            }
            continue;
        }
        if (strcmp(argv[i], "--load-data") == 0 && i+1 < argc) {
            if (auto_load_count < AUTO_LOAD_MAX) {
                snprintf(auto_load_files[auto_load_count],
                         sizeof(auto_load_files[auto_load_count]), "%s", argv[++i]);
                auto_load_starts[auto_load_count++] = false;
            } else {
                i++;
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
        if (ends_with_ignore_case(argv[i], ".rom")) {
            snprintf(rom_override, sizeof(rom_override), "%s", argv[i]);
            continue;
        }

        if (!ends_with_ignore_case(argv[i], ".ini") &&
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
    if (config_load(&cfg, cfg_file) != 0) {
        fprintf(stderr, "No config file found, using defaults.\n");
    }
    config_defaults(&cfg);

    if (speed_override >= 0)
        cfg.cpu_speed_hz = (uint32_t)speed_override;
    if (debug_flag)
        cfg.debug = true;

    /* Apply ROM override to first ROM device */
    if (rom_override[0]) {
        for (int i = 0; i < cfg.num_devs; i++) {
            if (cfg.devs[i].type == DEV_ROM) {
                snprintf(cfg.devs[i].rom_file, CFG_STR_MAX, "%s",
                         rom_override);
                break;
            }
        }
    }

    config_dump(&cfg);

    /* ── Allocate devices ────────────────────────────────── */
    /* Maximum one of each type per config slot */
    SRAM    srams[CFG_MAX_DEVS];
    ROM     roms[CFG_MAX_DEVS];
    VIA6522 vias[CFG_MAX_DEVS];
    UART6551 uarts[CFG_MAX_DEVS];
    DiskDev  disks[CFG_MAX_DEVS];
    RomSlot  rom_slots[CFG_MAX_DEVS];
    KeyboardRegs keyboard_regs;
    MathCopro math_copro;
    CIA6526 cia1;
    SIDStub sid;
    int ns = 0, nr = 0, nv = 0, nu = 0, nd = 0;
    int rom_slot_count = 0;

    Bus bus;
    bus_init(&bus);

    /* ── Initialize VIC (Video Interface Controller) ────── */
    vic_init();
    keyboard_regs_init(&keyboard_regs);
    g_keyboard_regs = &keyboard_regs;
    math_copro_init(&math_copro);
    cia_init(&cia1);
    sid_init(&sid);

    bus_register(&bus, "VIC-BITMAP", NULL,
                 0x6000, 0x2000,  /* Tang FPGA: 8KB banked framebuffer window */
                 vic_bitmap_read, vic_bitmap_write, NULL);

    bus_register(&bus, "VIC-VIDEO", NULL,
                 0x8000, 2048,  /* 2KB: text video RAM at $8000-$87FF */
                 vic_bus_read, vic_bus_write, vic_bus_tick);

    bus_register(&bus, "VIC-REGS", NULL,
                 0x9000, 16,    /* VIC control registers at $9000-$900F */
                 vic_reg_read, vic_reg_write, NULL);

    bus_register(&bus, "VIC-BLITTER", NULL,
                 0x8840, 16,    /* Blitter registers: $8840-$884F */
                 vic_blitter_read, vic_blitter_write, NULL);

    bus_register(&bus, "VIC-SPRREGS", NULL,
                 0x8850, 64,    /* Sprite regs: $8850-$888F (8 sprites × 8 bytes) */
                 vic_sprite_reg_read, vic_sprite_reg_write, NULL);

    bus_register(&bus, "VIC-SPRDATA", NULL,
                 0x8900, 256,   /* Sprite pixel data: $8900-$89FF (8 × 32 bytes) */
                 vic_sprite_data_read, vic_sprite_data_write, NULL);

    bus_register(&bus, "SOUND0", (void*)(uintptr_t)0,
                 SOUND_VOICE0_BASE, SOUND0_REG_COUNT,
                 soundchip_voice_read, soundchip_voice_write, NULL);
    bus_register(&bus, "SOUND1", (void*)(uintptr_t)1,
                 SOUND_VOICE1_BASE, SOUND_REG_COUNT,
                 soundchip_voice_read, soundchip_voice_write, NULL);
    bus_register(&bus, "SOUND2", (void*)(uintptr_t)2,
                 SOUND_VOICE2_BASE, SOUND_REG_COUNT,
                 soundchip_voice_read, soundchip_voice_write, NULL);
    bus_register(&bus, "SOUND3", (void*)(uintptr_t)3,
                 SOUND_VOICE3_BASE, SOUND_REG_COUNT,
                 soundchip_voice_read, soundchip_voice_write, NULL);

    bus_register(&bus, "KEYBOARD", &keyboard_regs,
                 0x8820, 4,
                 keyboard_regs_read, keyboard_regs_write, NULL);

    bus_register(&bus, "MATH-COPRO", &math_copro,
                 0x88B0, 16,
                 math_copro_read, math_copro_write, NULL);

    bus_register(&bus, "VIC-II", NULL,
                 0xD000, 0x40,
                 vicii_read, vicii_write, NULL);

    bus_register(&bus, "SID-6581", &sid,
                 0xD400, 0x1D,
                 sid_read, sid_write, sid_tick);

    bus_register(&bus, "CIA1-6526", &cia1,
                 0xDC00, 16,
                 cia_read, cia_write, cia_tick);

    for (int i = 0; i < cfg.num_devs; i++) {
        DevConfig *dc = &cfg.devs[i];
        switch (dc->type) {
        case DEV_SRAM:
            if (ns >= CFG_MAX_DEVS) { fprintf(stderr,"Too many SRAMs\n"); break; }
            if (sram_init(&srams[ns], dc->size) != 0) return 1;
            bus_register(&bus, "SRAM", &srams[ns],
                         dc->base, dc->size,
                         sram_read, sram_write, NULL);
            ns++;
            break;

        case DEV_ROM: {
            if (nr >= CFG_MAX_DEVS) { fprintf(stderr,"Too many ROMs\n"); break; }
            uint32_t rsize = dc->size ? dc->size : 0x4000;
            if (dc->rom_file[0]) {
                int rom_rc = dc->has_rom_file_offset
                    ? rom_load_segment(&roms[nr], dc->rom_file, rsize, dc->rom_file_offset)
                    : rom_load(&roms[nr], dc->rom_file, rsize);
                if (rom_rc != 0) {
                    fprintf(stderr, "Warning: ROM load failed, using blank ROM\n");
                    rom_init(&roms[nr], rsize);
                }
            } else {
                rom_init(&roms[nr], rsize);
                fprintf(stderr, "Warning: no ROM file specified\n");
            }
            bus_register(&bus, "ROM", &roms[nr],
                         dc->base, rsize,
                         rom_read, rom_write, NULL);
            if (rom_slot_count < CFG_MAX_DEVS) {
                rom_slots[rom_slot_count++] = (RomSlot){
                    .rom = &roms[nr],
                    .base = dc->base,
                    .size = rsize,
                    .file_offset = dc->rom_file_offset,
                    .has_file_offset = dc->has_rom_file_offset,
                };
            }
            nr++;
            break;
        }

        case DEV_VIA:
            if (nv >= CFG_MAX_DEVS) { fprintf(stderr,"Too many VIAs\n"); break; }
            via_init(&vias[nv]);
            bus_register(&bus, "VIA-6522", &vias[nv],
                         dc->base, 16,
                         via_read, via_write, via_tick);
            /* Set the first VIA as keyboard VIA */
            if (nv == 0) {
                g_keyboard_via = &vias[nv];
                printf("VIA #0 configured for keyboard input\n");
            }
            nv++;
            break;

        case DEV_UART: {
            if (nu >= CFG_MAX_DEVS) { fprintf(stderr,"Too many UARTs\n"); break; }
            UartMode umode = UART_MODE_STDIO;
            int uport = 0;
            if (strncmp(dc->uart_mode, "tcp", 3) == 0) {
                umode = UART_MODE_TCP;
                uport = dc->uart_port ? dc->uart_port : 2551;
            }
            if (uart_init(&uarts[nu], umode, uport) != 0) return 1;
            bus_register(&bus, "UART-6551", &uarts[nu],
                         dc->base, 4,
                         uart_read, uart_write, uart_tick);
            nu++;
            break;
        }

        case DEV_DISK:
            if (nd >= CFG_MAX_DEVS) { fprintf(stderr,"Too many DISKs\n"); break; }
            if (diskdev_init(&disks[nd], &bus, dc->disk_path) != 0) return 1;
            bus_register(&bus, "DISK-MVP", &disks[nd],
                         dc->base, 12,
                         diskdev_read, diskdev_write, NULL);
            nd++;
            break;
        }
    }

    if (show_map) {
        bus_dump(&bus);
        return 0;
    }

    bus_dump(&bus);

    /* ── Init CPU ─────────────────────────────────────────── */
    CPU6502 cpu;
    cpu6502_init(&cpu, cpu_bus_read, cpu_bus_write, &bus);

    /* Set CPU model (6502 or 65C02) */
    if (strcmp(cfg.cpu_model, "65c02") == 0 || strcmp(cfg.cpu_model, "65C02") == 0)
        cpu.mode = 1;
    else
        cpu.mode = 0;  /* Default to NMOS 6502 */

    /* Setup tracing */
    if (trace_flag || cfg.trace) {
        cpu.trace_enabled = true;
        if (trace_file[0]) {
            cpu.trace_fp = fopen(trace_file, "w");
            if (!cpu.trace_fp) {
                fprintf(stderr, "Cannot open trace file: %s\n", trace_file);
                cpu.trace_fp = stderr;
            }
        } else if (cfg.trace_file[0]) {
            cpu.trace_fp = fopen(cfg.trace_file, "w");
            if (!cpu.trace_fp) {
                fprintf(stderr, "Cannot open trace file: %s\n", cfg.trace_file);
                cpu.trace_fp = stderr;
            }
        } else {
            cpu.trace_fp = stderr;
        }
    }

    cpu6502_reset(&cpu);

    DropLoadContext drop_ctx = {
        .bus = &bus,
        .cpu = &cpu,
        .rom_slots = rom_slots,
        .rom_count = rom_slot_count,
    };
    vic_sdl_set_drop_file_handler(handle_drop_file, &drop_ctx);

    for (int i = 0; i < auto_load_count; i++) {
        handle_load_file(auto_load_files[i], &drop_ctx, auto_load_starts[i]);
    }

    /* ── VIC Demo messages disabled - MS BASIC will initialize the screen ──── */
    /*
    vic_clear_screen();
    vic_write_string("6502 SBC with VIC - Video Interface Controller\n");
    vic_write_string("==============================================\n\n");
    vic_write_string("System initialized and ready.\n");
    vic_write_string("Video RAM: $8000-$87FF (2KB)\n\n");
    vic_write_string("Type text to see it on screen...\n");
    */

    /* ── Initialize SDL2 for VIC display ──────────────────── */
    bool use_sdl = (vic_sdl_init() == 0);
    int screenshot_frames_seen = 0;
    bool screenshot_saved = false;
    if (use_sdl) {
        printf("SDL2 display enabled. Press ESC to quit.\n");
        vic_sdl_render();   /* Initial blank render so window appears */
    } else {
        printf("SDL2 display not available, using text output.\n");
    }

    /* Initialize sound chip (must be after SDL is up). */
    soundchip_init();

    /* Startup chirp so audio path can be verified quickly. */
    soundchip_beep(880.0f, 100);

    /* ── Init monitor ─────────────────────────────────────── */
    Monitor mon;
    monitor_init(&mon, &cpu, &bus);
    if (cfg.debug) {
        mon.active = true;
        printf("\nStarting in monitor mode. Type ? for help.\n");
    }

    /* ── Speed throttle setup ─────────────────────────────── */
    /* We batch steps and throttle every ~10ms of simulated time */
    uint64_t cycles_per_batch = (cfg.cpu_speed_hz > 0)
        ? cfg.cpu_speed_hz / 100  /* 10ms worth */
        : 100000;
    long     batch_ns         = (cfg.cpu_speed_hz > 0) ? 10000000L : 0L;
    uint64_t batch_start_cycle = 0;
    struct timespec batch_ts_start;

    signal(SIGINT, handle_sigint);
    printf("\n6502 SBC Emulator running. Press CTRL+C for monitor.\n\n");

    /* ── Main loop ────────────────────────────────────────── */
    monotonic_now(&batch_ts_start);

    while (!cpu.stopped) {
        /* Handle SDL events */
        if (use_sdl && !vic_sdl_handle_events()) {
            printf("\nSDL window closed, exiting...\n");
            break;
        }

        /* Check SIGINT frequently (after every ~1000 instructions) */
        static uint64_t sigint_check_cycles = 0;
        if (cpu.cycles - sigint_check_cycles >= 1000) {
            sigint_check_cycles = cpu.cycles;
            if (g_sigint) {
                g_sigint = 0;
                mon.active = true;
                printf("\n[SIGINT - entering monitor]\n");
            }
        }

        /* Monitor / breakpoint */
        if (mon.active || monitor_check(&mon)) {
            for (int i = 0; i < nu; i++) uart_stdio_suspend(&uarts[i]);
            mon.active = true;
            /* Render VIC before entering monitor so user sees current state */
            if (use_sdl) vic_sdl_render();
            while (mon.active) {
                if (!monitor_run(&mon)) goto done;
            }
            for (int i = 0; i < nu; i++) uart_stdio_resume(&uarts[i]);
            /* Restart speed timer after monitor */
            monotonic_now(&batch_ts_start);
            batch_start_cycle = cpu.cycles;
        }

        /* Execute one instruction */
        int c = cpu6502_step(&cpu);

        /* Tick peripherals */
        bus_tick(&bus, (uint32_t)c);

        /* Feed IRQ from VIA/UART/VIC back to CPU */
        bool irq = false;
        for (int i = 0; i < nv; i++) irq |= via_irq(&vias[i]);
        for (int i = 0; i < nu; i++) irq |= uart_irq(&uarts[i]);
        irq |= keyboard_regs_irq(&keyboard_regs);
        irq |= cia_irq(&cia1);
        irq |= vic_irq();
        if (irq) cpu6502_irq(&cpu);
        else     cpu6502_irq_clear(&cpu);

        /* Speed throttle and render: once per batch */
        static uint64_t last_render_cycle = 0;
        if (batch_ns > 0 && (cpu.cycles - batch_start_cycle) >= cycles_per_batch) {
            struct timespec now;
            monotonic_now(&now);
            long elapsed_ns = (long)((now.tv_sec  - batch_ts_start.tv_sec)  * 1000000000L
                                    + (now.tv_nsec - batch_ts_start.tv_nsec));
            long sleep_ns = batch_ns - elapsed_ns;
            if (sleep_ns > 1000L) ns_sleep(sleep_ns);
            batch_start_cycle = cpu.cycles;
            monotonic_now(&batch_ts_start);
            last_render_cycle = cpu.cycles;

            /* Render VIC display */
            if (use_sdl) {
                /* Handle SDL events (keyboard, quit, etc.) */
                if (!vic_sdl_handle_events()) {
                    printf("\n[SDL window closed - exiting]\n");
                    goto done;
                }
                vic_sdl_render();
                if (maybe_save_screenshot(screenshot_file, &screenshot_frames_seen,
                                          screenshot_frames, &screenshot_saved)) {
                    goto done;
                }
            }
        }
        /* Also render periodically when throttle not active (unlimited speed) */
        if (use_sdl && batch_ns == 0 && (cpu.cycles - last_render_cycle) >= 50000) {
            /* Handle SDL events */
            if (!vic_sdl_handle_events()) {
                printf("\n[SDL window closed - exiting]\n");
                goto done;
            }
            vic_sdl_render();
            if (maybe_save_screenshot(screenshot_file, &screenshot_frames_seen,
                                      screenshot_frames, &screenshot_saved)) {
                goto done;
            }
            last_render_cycle = cpu.cycles;
        }
    }

done:
    if (use_sdl && screenshot_file[0] && !screenshot_saved) {
        vic_sdl_render();
        vic_sdl_save_screenshot(screenshot_file);
    }

    printf("\nEmulator stopped after %llu cycles.\n",
           (unsigned long long)cpu.cycles);

    /* Dump profile if requested */
    if (profile_flag || cfg.profile) {
        cpu6502_dump_profile(&cpu, stdout);
    }

    /* Close trace file if it was opened */
    if (cpu.trace_fp && cpu.trace_fp != stderr) {
        fclose((FILE*)cpu.trace_fp);
    }

    /* cleanup */
    soundchip_shutdown();
    bus_shutdown();
    vic_sdl_shutdown();
    for (int i = 0; i < ns; i++) sram_free(&srams[i]);
    for (int i = 0; i < nr; i++) rom_free(&roms[i]);
    for (int i = 0; i < nu; i++) uart_free(&uarts[i]);
    return 0;
}
