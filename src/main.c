#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <time.h>
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

/* ── Global emulator state ────────────────────────────────── */
static volatile int g_sigint = 0;
static VIA6522 *g_keyboard_via = NULL;  /* Global VIA for keyboard input */

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
        "  -s <speed>    CPU speed in Hz (0=unlimited, default 1MHz)\n"
        "  -d            start in debug/monitor mode\n"
        "  -t [file]     enable instruction tracing (default: stderr)\n"
        "  -p            dump CPU profile on exit\n"
        "  -m            show memory map and exit\n"
        "  -h            show this help\n"
        "\n"
        "Default config: sbc.ini (if present)\n"
        "Default memory map:\n"
        "  $0000-$7FFF  SRAM  (32KB)\n"
        "  $8000-$87FF  VIC Video RAM (2KB)\n"
        "  $8800-$880F  VIA 6522\n"
        "  $8810-$8813  UART 6551 (ACIA)\n"
        "  $8820-$882F  DISK MVP\n"
        "  $8830-$8835  SOUND (freq/duration/volume/control)\n"
        "  $C000-$FFFF  ROM  (16KB)\n",
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

int main(int argc, char *argv[])
{
    Config  cfg;
    char    cfg_file[256] = "sbc.ini";
    char    rom_override[256] = "";
    int     speed_override = -1;
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
    int ns = 0, nr = 0, nv = 0, nu = 0, nd = 0;

    Bus bus;
    bus_init(&bus);

    /* ── Initialize VIC (Video Interface Controller) ────── */
    vic_init();
    bus_register(&bus, "VIC-VIDEO", NULL,
                 0x8000, 2048,  /* 2KB: text video RAM at $8000-$87FF */
                 vic_bus_read, vic_bus_write, vic_bus_tick);

    bus_register(&bus, "VIC-REGS", NULL,
                 0x9000, 16,    /* VIC control registers at $9000-$900F */
                 vic_reg_read, vic_reg_write, NULL);

    bus_register(&bus, "VIC-BITMAP", NULL,
                 0x9010, 8000,  /* Bitmap RAM at $9010-$AF4F (320x200 pixels) */
                 vic_bitmap_read, vic_bitmap_write, NULL);

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
                if (rom_load(&roms[nr], dc->rom_file, rsize) != 0) {
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
                         dc->base, 16,
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
            last_render_cycle = cpu.cycles;
        }
    }

done:
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
