#include "config.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

static char *trim(char *s)
{
    while (isspace((unsigned char)*s)) s++;
    char *e = s + strlen(s);
    while (e > s && isspace((unsigned char)e[-1])) e--;
    *e = 0;
    return s;
}

void config_defaults(Config *cfg)
{
    if (cfg->num_devs == 0) {
        /* Tang Primer 20K FPGA-compatible split-ROM map. */
        cfg->devs[0] = (DevConfig){ .type=DEV_SRAM, .base=0x0000, .size=0x8000 };
        cfg->devs[1] = (DevConfig){ .type=DEV_ROM,  .base=0xA000, .size=0x3000,
                                    .rom_file="roms/ehbasic.rom" };
        cfg->devs[2] = (DevConfig){ .type=DEV_ROM,  .base=0xF000, .size=0x1000,
                                    .rom_file="roms/kernel.rom" };
        cfg->devs[3] = (DevConfig){ .type=DEV_VIA,  .base=0x8800 };
        cfg->devs[4] = (DevConfig){ .type=DEV_UART, .base=0x8810,
                                    .uart_mode="stdio" };
        cfg->devs[5] = (DevConfig){ .type=DEV_DISK, .base=0x8820,
                                    .disk_path="data/disk" };
        cfg->num_devs = 6;
    }
    if (!cfg->cpu_speed_set)
        cfg->cpu_speed_hz = DEFAULT_CPU_SPEED_HZ;
}

int config_load(Config *cfg, const char *filename)
{
    memset(cfg, 0, sizeof(*cfg));

    FILE *f = fopen(filename, "r");
    if (!f) {
        fprintf(stderr, "config: cannot open '%s'\n", filename);
        return -1;
    }

    char line[256];
    char section[64] = "";
    DevConfig cur;
    memset(&cur, 0, sizeof(cur));
    bool in_dev = false;

    while (fgets(line, sizeof(line), f)) {
        char *p = trim(line);
        if (*p == '#' || *p == ';' || *p == 0) continue;

        if (*p == '[') {
            /* Save previous device section */
            if (in_dev && cfg->num_devs < CFG_MAX_DEVS)
                cfg->devs[cfg->num_devs++] = cur;

            char *end = strchr(p + 1, ']');
            if (end) *end = 0;
            strncpy(section, p + 1, sizeof(section) - 1);
            in_dev = false;
            memset(&cur, 0, sizeof(cur));

            if (strcmp(section, "sram") == 0) { cur.type = DEV_SRAM; in_dev = true; }
            else if (strcmp(section, "rom")  == 0) { cur.type = DEV_ROM;  in_dev = true; }
            else if (strcmp(section, "via")  == 0) { cur.type = DEV_VIA;  in_dev = true; }
            else if (strcmp(section, "uart") == 0) { cur.type = DEV_UART; in_dev = true; }
            else if (strcmp(section, "disk") == 0) { cur.type = DEV_DISK; in_dev = true; }
            continue;
        }

        char *eq = strchr(p, '=');
        if (!eq) continue;
        *eq = 0;
        char *key = trim(p);
        char *val = trim(eq + 1);
        /* strip inline comment */
        char *cm = strchr(val, '#');
        if (cm) { *cm = 0; val = trim(val); }

        if (strcmp(section, "cpu") == 0) {
            if (strcmp(key, "speed_hz") == 0) {
                cfg->cpu_speed_hz = (uint32_t)strtoul(val, NULL, 0);
                cfg->cpu_speed_set = true;
            }
            else if (strcmp(key, "debug") == 0)
                cfg->debug = atoi(val) != 0;
            else if (strcmp(key, "model") == 0)
                strncpy(cfg->cpu_model, val, sizeof(cfg->cpu_model) - 1);
            else if (strcmp(key, "trace") == 0)
                cfg->trace = atoi(val) != 0;
            else if (strcmp(key, "trace_file") == 0)
                strncpy(cfg->trace_file, val, CFG_STR_MAX - 1);
            else if (strcmp(key, "profile") == 0)
                cfg->profile = atoi(val) != 0;
        } else if (in_dev) {
            if (strcmp(key, "base") == 0)
                cur.base = (uint16_t)strtoul(val, NULL, 16);
            else if (strcmp(key, "size") == 0)
                cur.size = (uint32_t)strtoul(val, NULL, 16);
            else if (strcmp(key, "file") == 0)
                strncpy(cur.rom_file, val, CFG_STR_MAX - 1);
            else if (strcmp(key, "offset") == 0 || strcmp(key, "file_offset") == 0) {
                cur.rom_file_offset = (uint32_t)strtoul(val, NULL, 0);
                cur.has_rom_file_offset = true;
            }
            else if (strcmp(key, "mode") == 0)
                strncpy(cur.uart_mode, val, sizeof(cur.uart_mode) - 1);
            else if (strcmp(key, "port") == 0)
                cur.uart_port = atoi(val);
            else if (strcmp(key, "path") == 0)
                strncpy(cur.disk_path, val, CFG_STR_MAX - 1);
        }
    }

    if (in_dev && cfg->num_devs < CFG_MAX_DEVS)
        cfg->devs[cfg->num_devs++] = cur;

    fclose(f);
    return 0;
}

void config_dump(const Config *cfg)
{
    static const char *type_names[] = {"sram","rom","via","uart","disk"};
    printf("Configuration:\n");
    printf("  cpu speed : %u Hz\n", cfg->cpu_speed_hz);
    printf("  debug     : %s\n", cfg->debug ? "yes" : "no");
    for (int i = 0; i < cfg->num_devs; i++) {
        const DevConfig *d = &cfg->devs[i];
        printf("  [%s] base=$%04X", type_names[d->type], d->base);
        if (d->size)  printf(" size=$%04X", d->size);
        if (d->rom_file[0]) printf(" file=%s", d->rom_file);
        if (d->has_rom_file_offset) printf(" offset=$%04X", d->rom_file_offset);
        if (d->uart_mode[0]) printf(" mode=%s", d->uart_mode);
        if (d->uart_port)    printf(" port=%d", d->uart_port);
        if (d->disk_path[0]) printf(" path=%s", d->disk_path);
        printf("\n");
    }
}
