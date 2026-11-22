#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif

#include "sbc_c64.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif

#include "core/bus/bus.h"
#include "core/cpu/cpu6502.h"
#include "debug/monitor.h"
#include "devices/audio/sid_stub.h"
#include "devices/audio/soundchip.h"
#include "devices/io/cia6526.h"
#include "devices/io/uart6551.h"
#include "devices/io/via6522.h"
#include "devices/memory/rom.h"
#include "devices/memory/sram.h"
#include "host/path.h"
#include "host/vic_sdl.h"
#include "machines/c64/c64.h"
#include "machines/c64/c64_floppy.h"
#include "machines/c64/c64_vic.h"
#include "machines/sbc/diskdev.h"
#include "machines/sbc/keyboard_regs.h"
#include "machines/sbc/math_copro.h"
#include "machines/sbc/vic.h"

/* ── Global emulator state ────────────────────────────────── */
static volatile int g_sigint = 0;

#define DEFAULT_ROM_SIZE 0x4000u

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
    C64Floppy *floppy;
    MathCopro *math_copro;
    RomSlot  *rom_slots;
    int       rom_count;
} DropLoadContext;

static void handle_sigint(int sig)
{
    (void)sig;
    g_sigint = 1;
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

static bool ranges_overlap(uint16_t base_a, uint32_t size_a,
                           uint16_t base_b, uint32_t size_b)
{
    uint32_t end_a = (uint32_t)base_a + size_a;
    uint32_t end_b = (uint32_t)base_b + size_b;
    return (uint32_t)base_a < end_b && (uint32_t)base_b < end_a;
}

static bool rom_overlaps(const Config *cfg, uint16_t base, uint32_t size)
{
    for (int i = 0; i < cfg->num_devs; i++) {
        const DevConfig *dc = &cfg->devs[i];
        if (dc->type == DEV_ROM &&
            ranges_overlap(dc->base, dc->size ? dc->size : DEFAULT_ROM_SIZE, base, size)) {
            return true;
        }
    }
    return false;
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

    if (ctx->math_copro) {
        math_copro_init(ctx->math_copro);
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

    if (ctx->floppy && path_has_suffix(path, ".d64")) {
        if (c64_floppy_mount(ctx->floppy, path)) {
            vic_sdl_set_disk_title(ctx->floppy->device, path_basename(path));
        }
    } else if (path_has_suffix(path, ".prg")) {
        load_prg_file(ctx->bus, ctx->cpu, path, start_prg);
    } else if (path_has_suffix(path, ".rom") ||
               path_has_suffix(path, ".bin")) {
        load_rom_file(ctx, path);
    } else {
        fprintf(stderr, "\ndrop: unsupported file '%s' (use %s)\n", path_basename(path),
                ctx->floppy ? ".d64, .prg, .rom, or .bin" : ".prg, .rom, or .bin");
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

int sbc_c64_run(Config *cfg, const SbcC64Options *options)
{
    config_dump(cfg);

    /* ── Allocate devices ────────────────────────────────── */
    /* Maximum one of each type per config slot */
    SRAM    srams[CFG_MAX_DEVS];
    ROM     roms[CFG_MAX_DEVS];
    VIA6522 vias[CFG_MAX_DEVS];
    UART6551 uarts[CFG_MAX_DEVS];
    DiskDev  disks[CFG_MAX_DEVS];
    RomSlot  rom_slots[CFG_MAX_DEVS];
    KeyboardRegs keyboard_regs;
    VIA6522 *keyboard_via = NULL;
    MathCopro math_copro;
    CIA6526 cia1;
    SIDStub sid;
    C64     c64;
    bool sid_mapped = !cfg->c64 && !rom_overlaps(cfg, 0xD400, 0x1D);
    uint32_t cpu_clock = cfg->cpu_speed_hz ? cfg->cpu_speed_hz :
                         (cfg->c64 ? C64_PAL_CPU_HZ : DEFAULT_CPU_SPEED_HZ);
    soundchip_set_timebase(sid_mapped ? cpu_clock : 0);
    int ns = 0, nr = 0, nv = 0, nu = 0, nd = 0;
    int rom_slot_count = 0;

    Bus bus;
    bus_init(&bus);
    bool keyboard_regs_mapped = !cfg->c64;
    if (cfg->c64) {
        if (!c64_init(&c64, cfg->c64_basic, cfg->c64_kernal, cfg->c64_chargen)) {
            return 1;
        }
        bus_register(&bus, "C64", &c64, 0, C64_RAM_SIZE, c64_read, c64_write, c64_tick);
    } else {
        for (int i = 0; i < cfg->num_devs; i++) {
            DevConfig *dc = &cfg->devs[i];
            if (dc->type == DEV_DISK && ranges_overlap(dc->base, 12, 0x8820, 4)) {
                keyboard_regs_mapped = false;
                break;
            }
        }

        /* ── Initialize VIC (Video Interface Controller) ────── */
        vic_init();
        keyboard_regs_init(&keyboard_regs);
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
                     soundchip_voice_read, soundchip_voice_write,
                     sid_mapped ? soundchip_tick : NULL);
        bus_register(&bus, "SOUND1", (void*)(uintptr_t)1,
                     SOUND_VOICE1_BASE, SOUND_REG_COUNT,
                     soundchip_voice_read, soundchip_voice_write, NULL);
        bus_register(&bus, "SOUND2", (void*)(uintptr_t)2,
                     SOUND_VOICE2_BASE, SOUND_REG_COUNT,
                     soundchip_voice_read, soundchip_voice_write, NULL);
        bus_register(&bus, "SOUND3", (void*)(uintptr_t)3,
                     SOUND_VOICE3_BASE, SOUND_REG_COUNT,
                     soundchip_voice_read, soundchip_voice_write, NULL);

        if (keyboard_regs_mapped) {
            bus_register(&bus, "KEYBOARD", &keyboard_regs,
                         0x8820, 4,
                         keyboard_regs_read, keyboard_regs_write, NULL);
        }

        bus_register(&bus, "MATH-COPRO", &math_copro,
                     0x88B0, 16,
                     math_copro_read, math_copro_write, NULL);

        /* FPGA compatibility registers are available outside the configured ROM windows. */
        if (!rom_overlaps(cfg, 0xD000, 0x40)) {
            bus_register(&bus, "VIC-II", NULL, 0xD000, 0x40,
                         vicii_read, vicii_write, NULL);
        }
        if (sid_mapped) {
            bus_register(&bus, "SID-6581", &sid, 0xD400, 0x1D,
                         sid_read, sid_write, sid_tick);
        }
        if (!rom_overlaps(cfg, 0xDC00, 16)) {
            bus_register(&bus, "CIA1-6526", &cia1, 0xDC00, 16,
                         cia_read, cia_write, cia_tick);
        }

        for (int i = 0; i < cfg->num_devs; i++) {
            DevConfig *dc = &cfg->devs[i];
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
                uint32_t rsize = dc->size ? dc->size : DEFAULT_ROM_SIZE;
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
                    keyboard_via = &vias[nv];
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
    }

    if (options->show_map) {
        bus_dump(&bus);
        return 0;
    }

    bus_dump(&bus);

    /* ── Init CPU ─────────────────────────────────────────── */
    CPU6502 cpu;
    cpu6502_init(&cpu, cpu_bus_read, cpu_bus_write, &bus);
    cpu.nmos_rmw_writes = cfg->c64;

    /* Set CPU model (6502 or 65C02) */
    if (!cfg->c64 &&
        (strcmp(cfg->cpu_model, "65c02") == 0 || strcmp(cfg->cpu_model, "65C02") == 0))
        cpu.mode = CPU_MODEL_65C02;
    else
        cpu.mode = CPU_MODEL_6502;

    /* Setup tracing */
    if (options->trace || cfg->trace) {
        cpu.trace_enabled = true;
        if (options->trace_path[0]) {
            cpu.trace_fp = fopen(options->trace_path, "w");
            if (!cpu.trace_fp) {
                fprintf(stderr, "Cannot open trace file: %s\n", options->trace_path);
                cpu.trace_fp = stderr;
            }
        } else if (cfg->trace_file[0]) {
            cpu.trace_fp = fopen(cfg->trace_file, "w");
            if (!cpu.trace_fp) {
                fprintf(stderr, "Cannot open trace file: %s\n", cfg->trace_file);
                cpu.trace_fp = stderr;
            }
        } else {
            cpu.trace_fp = stderr;
        }
    }

    cpu6502_reset(&cpu);

    C64Floppy floppy = {.device = cfg->c64_floppy_device};
    DropLoadContext drop_ctx = {
        .bus = &bus,
        .cpu = &cpu,
        .floppy = cfg->c64 ? &floppy : NULL,
        .math_copro = cfg->c64 ? NULL : &math_copro,
        .rom_slots = rom_slots,
        .rom_count = rom_slot_count,
    };
    vic_sdl_set_drop_file_handler(handle_drop_file, &drop_ctx);
    vic_sdl_set_c64(cfg->c64 ? &c64 : NULL);
    vic_sdl_set_c64_config(cfg->c64 ? cfg : NULL, options->config_path);
    vic_sdl_set_sbc_keyboard(keyboard_via, keyboard_regs_mapped ? &keyboard_regs : NULL);

    if (cfg->c64 && cfg->c64_floppy_image[0] && c64_floppy_mount(&floppy, cfg->c64_floppy_image)) {
        vic_sdl_set_disk_title(floppy.device, path_basename(cfg->c64_floppy_image));
    }
    for (int i = 0; i < options->load_count; i++) {
        handle_load_file(options->load_files[i], &drop_ctx, options->load_starts[i]);
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
    bool use_sdl = (vic_sdl_init(cfg->window_scale) == 0);
    int screenshot_frames_seen = 0;
    bool screenshot_saved = false;
    if (use_sdl) {
        if (cfg->c64) {
            printf("SDL2 display enabled. ESC is RUN/STOP. F12 opens the configuration menu.\n");
        } else {
            printf("SDL2 display enabled. Press ESC to quit.\n");
        }
        vic_sdl_render();   /* Initial blank render so window appears */
    } else {
        printf("SDL2 display not available, using text output.\n");
    }

    /* Initialize sound chip (must be after SDL is up). */
    sid_set_cpu_clock(cfg->c64 ? &c64.sid : &sid, cpu_clock);
    soundchip_init();

    /* Startup chirp so audio path can be verified quickly. */
    if (!cfg->c64 && !sid_mapped) {
        soundchip_beep(880.0f, 100);
    }

    /* ── Init monitor ─────────────────────────────────────── */
    Monitor mon;
    monitor_init(&mon, &cpu, &bus);
    if (cfg->debug) {
        mon.active = true;
        printf("\nStarting in monitor mode. Type ? for help.\n");
    }

    /* ── Speed throttle setup ─────────────────────────────── */
    /* We batch steps and throttle every ~10ms of simulated time */
    uint64_t cycles_per_batch = (cfg->cpu_speed_hz > 0)
        ? cfg->cpu_speed_hz / 100  /* 10ms worth */
        : 100000;
    long     batch_ns         = (cfg->cpu_speed_hz > 0) ? 10000000L : 0L;
    uint64_t batch_start_cycle = 0;
    struct timespec batch_deadline;

    signal(SIGINT, handle_sigint);
    printf("\n%s emulator running. Press CTRL+C for monitor.\n\n",
           cfg->c64 ? "Commodore 64 (PAL)" : "6502 SBC");

    /* ── Main loop ────────────────────────────────────────── */
    monotonic_now(&batch_deadline);

    bool nmi_active = false;
    uint64_t next_sdl_poll = 0;
    uint32_t sdl_poll_interval = cpu_clock / 1000;
    while (!cpu.stopped) {
        /* SDL may pump the host event queue, so poll at a millisecond cadence. */
        if (use_sdl && (cpu.cycles >= next_sdl_poll || vic_sdl_menu_open())) {
            next_sdl_poll = cpu.cycles + sdl_poll_interval;
            if (!vic_sdl_handle_events()) {
                printf("\nSDL window closed, exiting...\n");
                break;
            }
        }

        if (use_sdl && vic_sdl_menu_open()) {
            vic_sdl_render();
            ns_sleep(16000000L);
            monotonic_now(&batch_deadline);
            batch_start_cycle = cpu.cycles;
            continue;
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
            monotonic_now(&batch_deadline);
            batch_start_cycle = cpu.cycles;
        }

        /* PAL VIC memory fetches can take the bus from the 6510. */
        int c = cfg->c64 ? c64_vic_cpu_stall(&c64) : 0;
        if (c != 0) {
            cpu.cycles += (uint32_t)c;
        } else if (cfg->c64) {
            c = c64_floppy_step(&floppy, &c64, &cpu);
        }
        if (c == 0) {
            c = cpu6502_step(&cpu);
        }

        /* Tick peripherals */
        bus_tick(&bus, (uint32_t)c);

        /* Feed the selected machine's interrupt lines back to the CPU. */
        bool irq = false;
        if (cfg->c64) {
            irq = c64_irq(&c64);
            bool nmi = c64_nmi(&c64);
            if (nmi && !nmi_active) {
                cpu6502_nmi(&cpu);
            }
            nmi_active = nmi;
        } else {
            for (int i = 0; i < nv; i++) irq |= via_irq(&vias[i]);
            for (int i = 0; i < nu; i++) irq |= uart_irq(&uarts[i]);
            if (keyboard_regs_mapped) irq |= keyboard_regs_irq(&keyboard_regs);
            irq |= cia_irq(&cia1);
            irq |= vic_irq();
        }
        if (irq) cpu6502_irq(&cpu);
        else     cpu6502_irq_clear(&cpu);

        /* Speed throttle and render: once per batch */
        static uint64_t last_render_cycle = 0;
        if (batch_ns > 0 && (cpu.cycles - batch_start_cycle) >= cycles_per_batch) {
            /* Carry sleep and render overhead into the next batch. Otherwise
               the audio producer gradually falls behind the playback device. */
            batch_deadline.tv_nsec += batch_ns;
            if (batch_deadline.tv_nsec >= 1000000000L) {
                batch_deadline.tv_sec++;
                batch_deadline.tv_nsec -= 1000000000L;
            }
            struct timespec now;
            monotonic_now(&now);
            int64_t sleep_ns = ((int64_t)batch_deadline.tv_sec - now.tv_sec) * INT64_C(1000000000) +
                               batch_deadline.tv_nsec - now.tv_nsec;
            if (sleep_ns > 1000L) {
                ns_sleep((long)sleep_ns);
            } else if (sleep_ns < -100000000L) {
                batch_deadline = now;
            }
            batch_start_cycle += cycles_per_batch;
            last_render_cycle = cpu.cycles;

            /* Render VIC display */
            if (use_sdl) {
                /* Handle SDL events (keyboard, quit, etc.) */
                if (!vic_sdl_handle_events()) {
                    printf("\n[SDL window closed - exiting]\n");
                    goto done;
                }
                vic_sdl_render();
                if (maybe_save_screenshot(options->screenshot_path, &screenshot_frames_seen,
                                          options->screenshot_frames, &screenshot_saved)) {
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
            if (maybe_save_screenshot(options->screenshot_path, &screenshot_frames_seen,
                                      options->screenshot_frames, &screenshot_saved)) {
                goto done;
            }
            last_render_cycle = cpu.cycles;
        }
    }

done:
    if (use_sdl && options->screenshot_path[0] && !screenshot_saved) {
        vic_sdl_render();
        vic_sdl_save_screenshot(options->screenshot_path);
    }

    printf("\nEmulator stopped after %llu cycles.\n",
           (unsigned long long)cpu.cycles);

    /* Dump profile if requested */
    if (options->profile || cfg->profile) {
        cpu6502_dump_profile(&cpu, stdout);
    }

    /* Close trace file if it was opened */
    if (cpu.trace_fp && cpu.trace_fp != stderr) {
        fclose((FILE*)cpu.trace_fp);
    }

    /* cleanup */
    soundchip_shutdown();
    bus_shutdown();
    vic_sdl_set_sbc_keyboard(NULL, NULL);
    vic_sdl_shutdown();
    c64_floppy_close(&floppy);
    for (int i = 0; i < ns; i++) sram_free(&srams[i]);
    for (int i = 0; i < nr; i++) rom_free(&roms[i]);
    for (int i = 0; i < nu; i++) uart_free(&uarts[i]);
    return 0;
}
