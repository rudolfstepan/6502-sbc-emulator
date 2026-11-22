#define _POSIX_C_SOURCE 200809L

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SDL_MAIN_HANDLED
#include <SDL2/SDL.h>

#include "core/bus/bus.h"
#include "machines/c64/c64.h"
#include "machines/c64/c64_floppy.h"
#include "machines/c64/c64_vic.h"
#include "core/cpu/cpu6502.h"
#include "media/d64.h"
#include "host/vic_sdl.h"
#include "machines/sbc/vic.h"

static const char *const rom_paths[] = {
    "roms/c64/basic.rom", "roms/c64/kernal.rom", "roms/c64/chargen.rom"
};

static bool send_key(uint32_t type, SDL_Keycode symbol)
{
    SDL_Event event = {.key = {.type = type}};
    event.key.keysym.sym = symbol;
    event.key.keysym.scancode = SDL_GetScancodeFromKey(symbol);
    assert(SDL_PushEvent(&event) == 1);
    /* SDL may leave events pushed after its current poll batch for the next poll. */
    for (unsigned int i = 0; i < 4; i++) {
        bool running = vic_sdl_handle_events();
        if (!running || !SDL_HasEvent(type)) {
            return running;
        }
    }
    assert(false);
    return false;
}

static void test_sdl_sbc_keyboard(void)
{
    VIA6522 via;
    KeyboardRegs registers;
    via_init(&via);
    keyboard_regs_init(&registers);

    assert(SDL_setenv("SDL_VIDEODRIVER", "dummy", 1) == 0);
    assert(vic_sdl_init(1) == 0);
    vic_sdl_set_sbc_keyboard(&via, &registers);
    assert(send_key(SDL_KEYDOWN, SDLK_RETURN));
    assert(keyboard_regs_irq(&registers));
    assert(keyboard_regs_read(&registers, 3) == '\r');
    assert(!via_keyboard_available(&via));

    vic_sdl_set_sbc_keyboard(&via, NULL);
    assert(send_key(SDL_KEYDOWN, SDLK_RETURN));
    assert(via_keyboard_available(&via));
    assert(via_keyboard_pop(&via) == '\r');
    assert(!keyboard_regs_irq(&registers));

    vic_sdl_set_sbc_keyboard(NULL, NULL);
    vic_sdl_shutdown();
}

static void test_sdl_sbc_text_refresh(void)
{
    char path[] = "sbc-text-XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0);
    assert(close(fd) == 0);

    assert(SDL_setenv("SDL_VIDEODRIVER", "dummy", 1) == 0);
    vic_init();
    vic_reg_write(NULL, 1, 0xFF);
    vic_reg_write(NULL, 2, 0xFF);
    assert(vic_sdl_init(1) == 0);

    vic_sdl_render();
    vic_sdl_render();
    assert(vic_sdl_save_screenshot(path) == 0);
    SDL_Surface *before = SDL_LoadBMP(path);
    assert(before);

    vic_write_video_ram(0, 'A');
    vic_sdl_render();
    assert(vic_sdl_save_screenshot(path) == 0);
    SDL_Surface *after = SDL_LoadBMP(path);
    assert(after && after->pitch == before->pitch && after->h == before->h);
    assert(memcmp(before->pixels, after->pixels, (size_t)before->pitch * before->h) != 0);

    SDL_FreeSurface(after);
    SDL_FreeSurface(before);
    assert(unlink(path) == 0);
    vic_sdl_shutdown();
}

static void test_sdl_run_stop(void)
{
    C64 c64 = {0};
    SDL_SetMainReady();
    assert(SDL_setenv("SDL_VIDEODRIVER", "dummy", 1) == 0);
    vic_sdl_set_c64(&c64);
    assert(vic_sdl_init(1) == 0);
    assert(vic_sdl_handle_events());

    c64_write(&c64, 0xDC02, 0xFF);
    c64_write(&c64, 0xDC00, 0x7F);
    assert(c64_read(&c64, 0xDC01) == 0xFF);
    assert(send_key(SDL_KEYDOWN, SDLK_ESCAPE));
    assert(c64_read(&c64, 0xDC01) == 0x7F);
    assert(send_key(SDL_KEYUP, SDLK_ESCAPE));
    assert(c64_read(&c64, 0xDC01) == 0xFF);

    SDL_Event event = {.type = SDL_QUIT};
    assert(SDL_PushEvent(&event) == 1);
    assert(!vic_sdl_handle_events());
    SDL_FlushEvents(SDL_FIRSTEVENT, SDL_LASTEVENT);
    vic_sdl_set_c64(NULL);
    assert(!send_key(SDL_KEYDOWN, SDLK_ESCAPE));
    vic_sdl_shutdown();
}

static void menu_key(SDL_Keycode key)
{
    assert(send_key(SDL_KEYDOWN, key));
    assert(send_key(SDL_KEYUP, key));
}

static void test_sdl_config_menu(void)
{
    char path[] = "build/c64-menu-XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0);
    FILE *file = fdopen(fd, "wb");
    assert(file);
    assert(fputs("# retained\r\n[machine]\r\ntype = c64\r\n[video]\r\n"
                 "window_scale = 1 # zoom\r\n[custom]\r\nkeep = yes\r\n", file) >= 0);
    assert(fclose(file) == 0);

    Config config;
    assert(config_load(&config, path) == 0);
    config_defaults(&config);
    C64 c64 = {0};
    vic_sdl_set_c64(&c64);
    vic_sdl_set_c64_config(&config, path);
    assert(vic_sdl_init(1) == 0);
    assert(vic_sdl_handle_events());

    menu_key(SDLK_F12);
    assert(vic_sdl_menu_open());
    menu_key(SDLK_RIGHT);
    assert(config.window_scale == 1);
    menu_key(SDLK_TAB);
    menu_key(SDLK_RETURN);
    menu_key(SDLK_F9);
    vic_sdl_render();
    menu_key(SDLK_TAB);
    menu_key(SDLK_RIGHT);
    menu_key(SDLK_RIGHT);
    menu_key(SDLK_DOWN);
    menu_key(SDLK_RETURN);
    menu_key(SDLK_z);
    menu_key(SDLK_F2);
    assert(config.window_scale == 2);
    assert(config.c64_keys[0] == SDL_SCANCODE_F9);
    assert(config.joystick_port == 2 && config.joystick_keys[0] == SDL_SCANCODE_Z);
    menu_key(SDLK_F12);
    assert(!vic_sdl_menu_open());

    c64_write(&c64, 0xDC02, 0xFF);
    c64_write(&c64, 0xDC00, 0xFE);
    assert(send_key(SDL_KEYDOWN, SDLK_F9));
    assert(c64_read(&c64, 0xDC01) == 0xFE);
    assert(send_key(SDL_KEYUP, SDLK_F9));
    assert(c64_read(&c64, 0xDC01) == 0xFF);
    c64_write(&c64, 0xDC00, 0xFF);
    assert(send_key(SDL_KEYDOWN, SDLK_z));
    assert(c64_read(&c64, 0xDC00) == 0xFE);
    assert(send_key(SDL_KEYUP, SDLK_z));
    assert(c64_read(&c64, 0xDC00) == 0xFF);
    assert(send_key(SDL_KEYDOWN, SDLK_PAGEUP));
    assert(c64_nmi(&c64));
    assert(send_key(SDL_KEYUP, SDLK_PAGEUP));
    assert(!c64_nmi(&c64));

#if SDL_VERSION_ATLEAST(2, 0, 14)
    if (SDL_NumJoysticks() == 0) {
        int device = SDL_JoystickAttachVirtual(SDL_JOYSTICK_TYPE_GAMECONTROLLER, 2, 2, 1);
        assert(device >= 0);
        SDL_Joystick *virtual = SDL_JoystickOpen(device);
        assert(virtual);
        assert(vic_sdl_handle_events());
        assert(SDL_JoystickSetVirtualButton(virtual, 0, SDL_PRESSED) == 0);
        SDL_JoystickUpdate();
        assert(vic_sdl_handle_events());
        assert(c64_read(&c64, 0xDC00) == 0xEF);
        assert(SDL_JoystickSetVirtualButton(virtual, 0, SDL_RELEASED) == 0);
        SDL_JoystickUpdate();
        assert(vic_sdl_handle_events());

        menu_key(SDLK_F12);
        menu_key(SDLK_PAGEDOWN);
        menu_key(SDLK_RETURN);
        assert(SDL_JoystickSetVirtualButton(virtual, 1, SDL_PRESSED) == 0);
        SDL_JoystickUpdate();
        assert(vic_sdl_handle_events());
        menu_key(SDLK_F2);
        menu_key(SDLK_F12);
        assert(config.joystick_controls[4] == 2);
        assert(SDL_JoystickSetVirtualButton(virtual, 1, SDL_RELEASED) == 0);
        SDL_JoystickUpdate();
        assert(vic_sdl_handle_events());
        assert(SDL_JoystickSetVirtualButton(virtual, 1, SDL_PRESSED) == 0);
        SDL_JoystickUpdate();
        assert(vic_sdl_handle_events());
        assert(c64_read(&c64, 0xDC00) == 0xEF);
        SDL_JoystickClose(virtual);
        assert(SDL_JoystickDetachVirtual(device) == 0);
        assert(vic_sdl_handle_events());
        assert(c64_read(&c64, 0xDC00) == 0xFF);
    }
#endif

    menu_key(SDLK_F12);
    SDL_Event drop = {.type = SDL_DROPFILE};
    drop.drop.file = SDL_strdup("data/sdcard/example.d64");
    assert(drop.drop.file);
    assert(SDL_PushEvent(&drop) == 1);
    assert(vic_sdl_handle_events());
    menu_key(SDLK_F2);
    menu_key(SDLK_F12);

    Config reloaded;
    assert(config_load(&reloaded, path) == 0);
    assert(reloaded.window_scale == 2 && reloaded.c64_keys[0] == SDL_SCANCODE_F9);
    assert(reloaded.joystick_port == 2 && reloaded.joystick_keys[0] == SDL_SCANCODE_Z);
    assert(reloaded.joystick_controls[4] == config.joystick_controls[4]);
    assert(strcmp(reloaded.c64_floppy_image, "data/sdcard/example.d64") == 0);
    file = fopen(path, "rb");
    assert(file);
    char contents[2048];
    size_t length = fread(contents, 1, sizeof(contents) - 1, file);
    contents[length] = 0;
    assert(fclose(file) == 0);
    assert(strstr(contents, "# retained\r\n"));
    assert(strstr(contents, "window_scale = 2 # zoom\r\n"));
    assert(strstr(contents, "[custom]\r\nkeep = yes\r\n"));
    assert(unlink(path) == 0);

    vic_sdl_shutdown();
    vic_sdl_set_c64(NULL);
    vic_sdl_set_c64_config(NULL, NULL);
}

static void test_memory_map(void)
{
    C64 c64 = {0};
    c64.basic[0] = 0xA1;
    c64.kernal[0x1FFF] = 0xE2;
    c64.chargen[0] = 0xD3;

    Bus bus;
    bus_init(&bus);
    bus_register(&bus, "C64", &c64, 0, C64_RAM_SIZE, c64_read, c64_write, c64_tick);
    assert(bus_read(&bus, 0xA000) == 0xA1);
    assert(bus_read(&bus, 0xFFFF) == 0xE2);

    bus_write(&bus, 0xA000, 0x12);
    bus_write(&bus, 0xFFFF, 0x34);
    bus_write(&bus, 0xD800, 0xAB);
    assert(bus_read(&bus, 0xD800) == 0xFB);
    assert(bus_read(&bus, 0xA000) == 0xA1);
    assert(bus_read(&bus, 0xFFFF) == 0xE2);

    bus_write(&bus, 0, 0x07);
    bus_write(&bus, 1, 0x03);
    assert(bus_read(&bus, 0xD000) == 0xD3);
    bus_write(&bus, 0xD000, 0x56);
    bus_write(&bus, 1, 0x00);
    assert(bus_read(&bus, 0xD000) == 0x56);
    assert(bus_read(&bus, 0xA000) == 0x12);
    assert(bus_read(&bus, 0xFFFF) == 0x34);
}

static void test_video_and_keyboard(void)
{
    C64 c64 = {0};
    cia_init_native(&c64.cia1);
    cia_init_native(&c64.cia2);

    c64.chargen[0] = 0x12;
    c64.ram[0x5000] = 0x34;
    assert(c64_video_bank(&c64) == 0);
    assert(c64_video_read(&c64, 0x9000) == 0x12);
    c64_write(&c64, 0xDD02, 0x03);
    c64_write(&c64, 0xDD00, 0x02);
    assert(c64_video_bank(&c64) == 0x4000);
    assert(c64_video_read(&c64, 0x5000) == 0x34);

    c64_write(&c64, 0xDC02, 0xFF);
    c64_write(&c64, 0xDC00, 0xFD);
    c64_set_key(&c64, 1 * 8 + 2); /* A */
    assert(c64_read(&c64, 0xDC01) == 0xFB);
    c64_clear_keys(&c64);
    assert(c64_read(&c64, 0xDC01) == 0xFF);

    c64_write(&c64, 0xD012, 2);
    c64_write(&c64, 0xD01A, 1);
    c64_tick(&c64, 125);
    assert(c64_read(&c64, 0xD012) == 1);
    assert(!c64_irq(&c64));
    c64_tick(&c64, 1);
    assert(c64_irq(&c64));
    c64_write(&c64, 0xD019, 1);
    assert(!c64_irq(&c64));
}

static void test_cia_interrupts(void)
{
    C64 c64 = {0};
    cia_init_native(&c64.cia1);
    cia_init_native(&c64.cia2);
    c64_write(&c64, 0xDC04, 2);
    c64_write(&c64, 0xDC05, 0);
    c64_write(&c64, 0xDC0D, 0x81);
    c64_write(&c64, 0xDC0E, 1);
    c64_tick(&c64, 2);
    assert(!c64_irq(&c64));
    c64_tick(&c64, 1);
    assert(c64_irq(&c64));
    assert(c64_read(&c64, 0xDC0D) == 0x81);
    assert(!c64_irq(&c64));
    c64_tick(&c64, 3);
    assert(c64_irq(&c64));
}

static void test_vic_scanlines_and_sprites(void)
{
    C64 c64 = {0};
    cia_init_native(&c64.cia1);
    cia_init_native(&c64.cia2);
    c64_write(&c64, 0xD011, 0x1B);
    c64_write(&c64, 0xD016, 0x08);
    c64_write(&c64, 0xD018, 0x18);
    c64_write(&c64, 0xD021, 6);
    c64.ram[0x0400] = 1;
    c64.color_ram[0] = 1;
    c64.ram[0x2008] = 0x80;

    for (unsigned int sprite = 0; sprite < 2; sprite++) {
        c64_write(&c64, 0xD000 + 2 * sprite, 24);
        c64_write(&c64, 0xD001 + 2 * sprite, 50);
        c64_write(&c64, 0xD027 + sprite, 2 + sprite);
        c64.ram[0x07F8 + sprite] = 0x20 + sprite;
        c64.ram[0x0800 + 64 * sprite] = 0x80;
    }
    c64_write(&c64, 0xD015, 3);
    c64_write(&c64, 0xD01A, 6);
    c64_write(&c64, 0xD01B, 1);

    unsigned int elapsed = 51 * 63 + 14;
    c64_tick(&c64, elapsed);
    assert(c64_vic_cpu_stall(&c64) == 40);
    c64_tick(&c64, 40);
    elapsed += 40;
    assert(c64_vic_cpu_stall(&c64) == 0);
    assert(c64_read(&c64, 0xD01E) == 3);
    assert(c64_read(&c64, 0xD01E) == 0);
    assert(c64_read(&c64, 0xD01F) == 3);
    assert(c64_irq(&c64));
    c64_write(&c64, 0xD019, 6);
    assert(!c64_irq(&c64));

    c64_write(&c64, 0xD021, 3);
    c64_tick(&c64, 312 * 63 - elapsed);
    const uint8_t (*frame)[C64_VIDEO_WIDTH] = c64_vic_frame(&c64);
    assert(frame[0][0] == 1); /* Higher-priority sprite remains behind the glyph. */
    assert(frame[0][1] == 6);
    assert(frame[1][1] == 3);
}

static void test_vic_raster_acknowledge(void)
{
    C64 c64 = {0};
    CPU6502 cpu;
    cpu6502_init(&cpu, c64_read, c64_write, &c64);
    cpu.nmos_rmw_writes = true;
    cpu.PC = 0x0200;
    const uint8_t instruction[] = {0xEE, 0x19, 0xD0}; /* INC $D019. */
    memcpy(c64.ram + cpu.PC, instruction, sizeof(instruction));

    c64_write(&c64, 0xD012, 2);
    c64_write(&c64, 0xD01A, 1);
    c64_vic_tick(&c64, 2 * 63);
    assert(c64_irq(&c64));
    assert(cpu6502_step(&cpu) == 6);
    assert(!c64_irq(&c64));
}

static void test_vic_multicolor_sprite_expansion(void)
{
    C64 c64 = {0};
    c64_write(&c64, 0xD011, 0x1B);
    c64_write(&c64, 0xD016, 0x0B);
    c64_write(&c64, 0xD018, 0x18);
    c64_write(&c64, 0xD021, 6);
    c64.ram[0x0400] = 1;
    c64.color_ram[0] = 1;
    c64.ram[0x2008] = 0x80;

    c64_write(&c64, 0xD000, 40);
    c64_write(&c64, 0xD001, 50);
    c64_write(&c64, 0xD015, 1);
    c64_write(&c64, 0xD017, 1);
    c64_write(&c64, 0xD01C, 1);
    c64_write(&c64, 0xD01D, 1);
    c64_write(&c64, 0xD025, 2);
    c64_write(&c64, 0xD026, 4);
    c64_write(&c64, 0xD027, 3);
    c64.ram[0x07F8] = 0x20;
    c64.ram[0x0800] = 0x6C; /* Shared 0, individual, shared 1, transparent. */

    c64_vic_tick(&c64, 312 * 63);
    const uint8_t (*frame)[C64_VIDEO_WIDTH] = c64_vic_frame(&c64);
    assert(frame[0][2] == 6 && frame[0][3] == 1);
    for (unsigned int y = 0; y < 2; y++) {
        assert(frame[y][16] == 2 && frame[y][19] == 2);
        assert(frame[y][20] == 3 && frame[y][23] == 3);
        assert(frame[y][24] == 4 && frame[y][27] == 4);
        assert(frame[y][28] == 6);
    }
    assert(frame[2][16] == 6);
}

static void run_cpu(CPU6502 *cpu, C64 *c64, C64Floppy *floppy, uint64_t cycles)
{
    uint64_t until = cpu->cycles + cycles;
    while (cpu->cycles < until) {
        assert(!cpu->stopped);
        int elapsed = c64_vic_cpu_stall(c64);
        if (elapsed) {
            cpu->cycles += (uint32_t)elapsed;
        } else {
            elapsed = c64_floppy_step(floppy, c64, cpu);
        }
        if (!elapsed) {
            elapsed = cpu6502_step(cpu);
        }
        c64_tick(c64, (uint32_t)elapsed);
        if (c64_irq(c64)) {
            cpu6502_irq(cpu);
        } else {
            cpu6502_irq_clear(cpu);
        }
    }
}

static bool screen_contains(const C64 *c64, const char *text)
{
    uint16_t screen = c64_video_bank(c64) + ((c64->vic_regs[0x18] & 0xF0) << 6);
    for (unsigned int start = 0; start < 1000; start++) {
        unsigned int offset = start;
        const char *letter = text;
        while (*letter && offset < 1000) {
            uint8_t ascii = c64_video_read(c64, (uint16_t)(screen + offset++)) & 0x7F;
            if (ascii < 32) {
                ascii += 64;
            }
            if (ascii != (uint8_t)*letter) {
                break;
            }
            letter++;
        }
        if (!*letter) {
            return true;
        }
    }
    return false;
}

static FILE *make_test_disk(void)
{
    FILE *image = tmpfile();
    assert(image);
    uint8_t sector[D64_SECTOR_SIZE] = {0};
    const uint8_t prg[] = {1, 8, 0x0F, 8, 10, 0, 0x99, '"',
                           'D', '6', '4', ' ', 'O', 'K', '"', 0, 0, 0};
    sector[1] = sizeof(prg) + 1;
    memcpy(sector + 2, prg, sizeof(prg));
    assert(fwrite(sector, 1, sizeof(sector), image) == sizeof(sector));

    assert(fseek(image, 17 * 21 * D64_SECTOR_SIZE, SEEK_SET) == 0);
    memset(sector, 0, sizeof(sector));
    memcpy(sector + 0x90, "TEST DISK", 9);
    assert(fwrite(sector, 1, sizeof(sector), image) == sizeof(sector));
    memset(sector, 0, sizeof(sector));
    sector[1] = 0xFF;
    sector[2] = 0x82;
    sector[3] = 1;
    memcpy(sector + 5, "HELLO", 5);
    sector[30] = 1;
    assert(fwrite(sector, 1, sizeof(sector), image) == sizeof(sector));
    assert(fseek(image, D64_IMAGE_SIZE - 1, SEEK_SET) == 0);
    assert(fputc(0, image) == 0);
    return image;
}

static void test_floppy_load(void)
{
    C64 c64 = {0};
    C64Floppy floppy = {.image = make_test_disk(), .device = 8};
    CPU6502 cpu = {.PC = 0xFFD5, .SP = 0xFB, .X = 0x00, .Y = 0x20};
    c64.ram[0x0331] = 0xF4;
    c64.ram[0x01FC] = 0x34;
    c64.ram[0x01FD] = 0x12;
    c64.ram[0xB7] = 5;
    c64.ram[0xBA] = 9;
    c64.ram[0xBC] = 0x02;
    memcpy(c64.ram + 0x0200, "HEL?O", 5);
    assert(c64_floppy_step(&floppy, &c64, &cpu) == 0);

    c64.ram[0xBA] = 8;
    assert(c64_floppy_step(&floppy, &c64, &cpu) == 6);
    assert(!(cpu.P & FLAG_C));
    assert(cpu.PC == 0x1235 && cpu.SP == 0xFD);
    assert(cpu.X == 0x10 && cpu.Y == 0x20);
    assert(c64.ram[0x2004] == 0x99);

    cpu.PC = 0xFFD5;
    cpu.SP = 0xFB;
    cpu.X = 0xF8;
    cpu.Y = 0xFF;
    assert(c64_floppy_step(&floppy, &c64, &cpu) == 6);
    assert(cpu.P & FLAG_C);
    assert(c64.ram[0xFFF8] == 0);
    c64_floppy_close(&floppy);
}

static void basic_command(CPU6502 *cpu, C64 *c64, C64Floppy *floppy, const char *command)
{
    size_t length = strlen(command);
    while (length) {
        size_t chunk = length > 10 ? 10 : length;
        assert(c64->ram[0xC6] == 0);
        memcpy(c64->ram + 0x277, command, chunk);
        c64->ram[0xC6] = (uint8_t)chunk;
        run_cpu(cpu, c64, floppy, C64_PAL_CPU_HZ / 2);
        command += chunk;
        length -= chunk;
    }
}

static void test_rom_boot(void)
{
    C64 c64;
    C64Floppy floppy = {.device = 9};
    assert(c64_init(&c64, rom_paths[0], rom_paths[1], rom_paths[2]));
    CPU6502 cpu;
    cpu6502_init(&cpu, c64_read, c64_write, &c64);
    cpu.nmos_rmw_writes = true;
    cpu6502_reset(&cpu);
    run_cpu(&cpu, &c64, &floppy, 3 * C64_PAL_CPU_HZ);
    assert(screen_contains(&c64, "READY."));

    /* Enter PRINT 7*6 by pressing the corresponding CIA1 matrix switches. */
    const unsigned int command[] = {41, 17, 33, 39, 22, 60, 24, 49, 19, 1};
    for (size_t i = 0; i < sizeof(command) / sizeof(command[0]); i++) {
        c64_set_key(&c64, command[i]);
        run_cpu(&cpu, &c64, &floppy, 40000);
        c64_clear_keys(&c64);
        run_cpu(&cpu, &c64, &floppy, 40000);
    }
    assert(screen_contains(&c64, "PRINT 7*6"));
    assert(screen_contains(&c64, " 42"));
    puts("test_c64: BASIC boot and keyboard input ok");

    floppy.image = make_test_disk();
    basic_command(&cpu, &c64, &floppy, "LOAD\"$\",9\r");
    basic_command(&cpu, &c64, &floppy, "LIST\r");
    assert(screen_contains(&c64, "TEST DISK"));
    assert(screen_contains(&c64, "\"HELLO\""));
    assert(screen_contains(&c64, "BLOCKS FREE."));
    basic_command(&cpu, &c64, &floppy, "LOAD\"MISSING\",9\r");
    assert(screen_contains(&c64, "FILE NOT FOUND"));
    basic_command(&cpu, &c64, &floppy, "LOAD\"HELLO           \",9,1\r");
    basic_command(&cpu, &c64, &floppy, "RUN\r");
    assert(screen_contains(&c64, "D64 OK"));
    c64_floppy_close(&floppy);
    puts("test_c64: D64 directory, missing file, and PRG boot ok");
}

int main(int argc, char *argv[])
{
    test_sdl_sbc_keyboard();
    test_sdl_sbc_text_refresh();
    test_sdl_run_stop();
    test_sdl_config_menu();
    test_memory_map();
    test_video_and_keyboard();
    test_cia_interrupts();
    test_vic_scanlines_and_sprites();
    test_vic_raster_acknowledge();
    test_vic_multicolor_sprite_expansion();
    test_floppy_load();
    if (argc == 2 && strcmp(argv[1], "--boot") == 0) {
        test_rom_boot();
    }
    puts("test_c64: ok");
    return 0;
}
