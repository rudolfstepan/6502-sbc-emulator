#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>

#include "cpu6502.h"
#include "bus.h"
#include "sram.h"
#include "rom.h"
#include "via6522.h"
#include "uart6551.h"
#include "monitor.h"
#include "config.h"
#include "disasm.h"

/* ── Global emulator state ────────────────────────────────── */
static volatile int g_sigint = 0;

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

/* ── Nanosecond sleep for speed throttling ───────────────── */
static void ns_sleep(long ns)
{
    struct timespec ts = { .tv_sec = 0, .tv_nsec = ns };
    nanosleep(&ts, NULL);
}

/* ── Usage ────────────────────────────────────────────────── */
static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s [options] [config.ini]\n"
        "Options:\n"
        "  -r <rom>      load ROM file (overrides config)\n"
        "  -s <speed>    CPU speed in Hz (0=unlimited, default 1MHz)\n"
        "  -d            start in debug/monitor mode\n"
        "  -m            show memory map and exit\n"
        "  -h            show this help\n"
        "\n"
        "Default config: sbc.ini (if present)\n"
        "Default memory map:\n"
        "  $0000-$7FFF  SRAM  (32KB)\n"
        "  $8000-$800F  VIA 6522\n"
        "  $8010-$8013  UART 6551 (ACIA)\n"
        "  $C000-$FFFF  ROM  (16KB)\n",
        prog);
}

int main(int argc, char *argv[])
{
    Config  cfg;
    char    cfg_file[256] = "sbc.ini";
    char    rom_override[256] = "";
    int     speed_override = -1;
    bool    debug_flag    = false;
    bool    show_map      = false;

    /* ── Parse arguments ─────────────────────────────────── */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-h") == 0) { usage(argv[0]); return 0; }
        if (strcmp(argv[i], "-d") == 0) { debug_flag = true; continue; }
        if (strcmp(argv[i], "-m") == 0) { show_map = true; continue; }
        if (strcmp(argv[i], "-r") == 0 && i+1 < argc) {
            snprintf(rom_override, sizeof(rom_override), "%s", argv[++i]);
            continue;
        }
        if (strcmp(argv[i], "-s") == 0 && i+1 < argc) {
            speed_override = atoi(argv[++i]); continue;
        }
        /* positional: config file */
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
    int ns = 0, nr = 0, nv = 0, nu = 0;

    Bus bus;
    bus_init(&bus);

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
    cpu6502_reset(&cpu);

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
    clock_gettime(CLOCK_MONOTONIC, &batch_ts_start);

    while (!cpu.stopped) {
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
            while (mon.active) {
                if (!monitor_run(&mon)) goto done;
            }
            for (int i = 0; i < nu; i++) uart_stdio_resume(&uarts[i]);
            /* Restart speed timer after monitor */
            clock_gettime(CLOCK_MONOTONIC, &batch_ts_start);
            batch_start_cycle = cpu.cycles;
        }

        /* Execute one instruction */
        int c = cpu6502_step(&cpu);

        /* Tick peripherals */
        bus_tick(&bus, (uint32_t)c);

        /* Feed IRQ from VIA/UART back to CPU */
        bool irq = false;
        for (int i = 0; i < nv; i++) irq |= via_irq(&vias[i]);
        for (int i = 0; i < nu; i++) irq |= uart_irq(&uarts[i]);
        if (irq) cpu6502_irq(&cpu);
        else     cpu6502_irq_clear(&cpu);

        /* Speed throttle: once per batch */
        if (batch_ns > 0 && (cpu.cycles - batch_start_cycle) >= cycles_per_batch) {
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            long elapsed_ns = (long)((now.tv_sec  - batch_ts_start.tv_sec)  * 1000000000L
                                    + (now.tv_nsec - batch_ts_start.tv_nsec));
            long sleep_ns = batch_ns - elapsed_ns;
            if (sleep_ns > 1000L) ns_sleep(sleep_ns);
            batch_start_cycle = cpu.cycles;
            clock_gettime(CLOCK_MONOTONIC, &batch_ts_start);
        }
    }

done:
    printf("\nEmulator stopped after %llu cycles.\n",
           (unsigned long long)cpu.cycles);

    /* cleanup */
    for (int i = 0; i < ns; i++) sram_free(&srams[i]);
    for (int i = 0; i < nr; i++) rom_free(&roms[i]);
    for (int i = 0; i < nu; i++) uart_free(&uarts[i]);
    return 0;
}
