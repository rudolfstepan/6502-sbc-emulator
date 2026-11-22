#include "apple2.h"
#include "apple2_disk.h"
#include "core/cpu/cpu6502.h"

#include <SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    VIDEO_WIDTH = 280,
    VIDEO_HEIGHT = 192,
    VIDEO_COLUMNS = 40,
    CYCLES_PER_LINE = 65,
    CYCLES_PER_FRAME = CYCLES_PER_LINE * 262,
    CPU_HZ = 1020484,
    AUDIO_HZ = 44100,
    KEY_QUEUE_SIZE = 64
};

typedef struct {
    uint8_t ram[0xC000];
    uint8_t language_ram[0x4000];
    uint8_t rom[0x3000];
    uint8_t video_rom[0x800];
    Apple2Disk disk;
    CPU6502 cpu;
    uint8_t key;
    uint8_t keys[KEY_QUEUE_SIZE];
    unsigned next_key, pending_keys;
    bool text, mixed, page_two, hires;
    bool lc_bank_two, lc_read, lc_write, lc_prewrite;
    bool speaker;
    unsigned audio_phase;
    float audio_level;
    uint32_t pixels[VIDEO_WIDTH * VIDEO_HEIGHT];
} Apple2;

static bool load_rom(const char *path, uint8_t *rom, size_t size)
{
    FILE *file = fopen(path, "rb");
    if (!file) {
        fprintf(stderr, "Apple II: cannot open ROM '%s'\n", path);
        return false;
    }
    bool ok = fread(rom, 1, size, file) == size && fgetc(file) == EOF && !ferror(file);
    fclose(file);
    if (!ok) {
        fprintf(stderr, "Apple II: expected a readable %zu-byte ROM at '%s'\n", size, path);
    }
    return ok;
}

static unsigned video_address(const Apple2 *a, unsigned y, bool hires)
{
    unsigned row = y / 8;
    unsigned offset = (row % 8) * 128 + (row / 8) * VIDEO_COLUMNS;
    if (hires) {
        return (a->page_two ? 0x4000 : 0x2000) + (y % 8) * 1024 + offset;
    }
    return (a->page_two ? 0x0800 : 0x0400) + offset;
}

static void language_switch(Apple2 *a, uint16_t addr, bool write)
{
    a->lc_bank_two = !(addr & 8);
    unsigned mode = addr & 3;
    a->lc_read = mode == 0 || mode == 3;
    if (!(mode & 1)) {
        a->lc_write = false;
    } else if (!write && a->lc_prewrite) {
        a->lc_write = true;
    }
    a->lc_prewrite = (mode & 1) && !write;
}

static unsigned language_address(const Apple2 *a, uint16_t addr)
{
    if (addr < 0xE000 && !a->lc_bank_two) {
        return addr - 0xC000;
    }
    return addr - 0xD000;
}

static uint8_t io_access(Apple2 *a, uint16_t addr, bool write)
{
    if (addr < 0xC010) return a->key;
    if (addr < 0xC020) {
        a->key &= 0x7F;
    } else if (addr >= 0xC030 && addr < 0xC040) {
        a->speaker = !a->speaker;
    } else if (addr >= 0xC050 && addr <= 0xC057) {
        bool on = addr & 1;
        switch (addr & 6) {
        case 0: a->text = on; break;
        case 2: a->mixed = on; break;
        case 4: a->page_two = on; break;
        case 6: a->hires = on; break;
        }
    } else if (addr >= 0xC080 && addr <= 0xC08F) {
        language_switch(a, addr, write);
    } else if (addr >= 0xC0E0 && addr <= 0xC0EF) {
        return apple2_disk_switch(&a->disk, addr & 15);
    } else if (addr >= 0xC060 && addr <= 0xC067) {
        return 0; /* Idle cassette input, buttons and paddles. */
    }

    /* Approximate the open bus with the current display fetch. */
    unsigned y = a->cpu.cycles / CYCLES_PER_LINE % VIDEO_HEIGHT;
    unsigned x = a->cpu.cycles % CYCLES_PER_LINE % VIDEO_COLUMNS;
    bool hires = a->hires && !a->text && !(a->mixed && y >= 160);
    return a->ram[video_address(a, y, hires) + x];
}

static uint8_t apple2_read(void *context, uint16_t addr)
{
    Apple2 *a = context;
    if (addr < 0xC000) return a->ram[addr];
    if (addr < 0xC100) return io_access(a, addr, false);
    if (addr >= 0xC600 && addr <= 0xC6FF && a->disk.tracks) {
        return a->disk.rom[addr & 0xFF];
    }
    if (addr < 0xD000) return 0xFF;
    if (a->lc_read) return a->language_ram[language_address(a, addr)];
    return a->rom[addr - 0xD000];
}

static void apple2_write(void *context, uint16_t addr, uint8_t data)
{
    Apple2 *a = context;
    if (addr < 0xC000) {
        a->ram[addr] = data;
    } else if (addr < 0xC100) {
        io_access(a, addr, true);
    } else if (addr >= 0xD000 && a->lc_write) {
        a->language_ram[language_address(a, addr)] = data;
    }
}

static void reset(Apple2 *a, bool cold)
{
    if (cold) {
        /* Invalidate the Autostart ROM's warm-start vector check. */
        a->ram[0x03F4] = a->ram[0x03F3];
    }
    a->key &= 0x7F;
    a->pending_keys = 0;
    a->text = true;
    a->mixed = a->page_two = a->hires = false;
    a->lc_bank_two = true;
    a->lc_read = a->lc_write = a->lc_prewrite = false;
    apple2_disk_reset(&a->disk);
    cpu6502_reset(&a->cpu);
}

static void draw_hires_line(uint32_t *pixels, const uint8_t *row)
{
    static const uint32_t colors[] = {
        0xFFBA36E5, 0xFF39D636, 0xFF3788FF, 0xFFF26B25
    };
    bool dots[VIDEO_WIDTH + 2] = {false};
    for (unsigned x = 0; x < VIDEO_WIDTH; ++x) {
        dots[x + 1] = (row[x / 7] >> (x % 7)) & 1;
    }
    for (unsigned x = 0; x < VIDEO_WIDTH; ++x) {
        if (!dots[x + 1]) {
            pixels[x] = 0xFF000000;
        } else if (dots[x] || dots[x + 2]) {
            pixels[x] = 0xFFFFFFFF;
        } else {
            unsigned phase = (row[x / 7] >> 7) * 2 + x % 2;
            pixels[x] = colors[phase];
        }
    }
}

static void draw_frame(Apple2 *a, unsigned frame)
{
    static const uint32_t lores[] = {
        0xFF000000, 0xFF9D0966, 0xFF2A2AA5, 0xFFC24DFF,
        0xFF007B49, 0xFF808080, 0xFF278AF0, 0xFFA8C7FF,
        0xFF6B4F00, 0xFFF26916, 0xFFAAAAAA, 0xFFFF89E5,
        0xFF43CB23, 0xFFFFFF39, 0xFF63F5B0, 0xFFFFFFFF
    };
    bool flash = (frame / 16) % 2;
    for (unsigned y = 0; y < VIDEO_HEIGHT; ++y) {
        bool text = a->text || (a->mixed && y >= 160);
        bool hires = a->hires && !text;
        const uint8_t *row = a->ram + video_address(a, y, hires);
        uint32_t *pixel = a->pixels + y * VIDEO_WIDTH;
        if (hires) {
            draw_hires_line(pixel, row);
            continue;
        }

        for (unsigned col = 0; col < VIDEO_COLUMNS; ++col) {
            unsigned code = row[col];
            if (text) {
                unsigned bits = a->video_rom[code * 8 + y % 8];
                if (code < 0x40 || (code < 0x80 && flash)) bits ^= 0x7F;
                for (unsigned x = 0; x < 7; ++x) {
                    *pixel++ = (bits & (0x40 >> x)) ? 0xFFFFFFFF : 0xFF000000;
                }
            } else {
                uint32_t color = lores[(code >> (y & 4)) & 15];
                for (unsigned x = 0; x < 7; ++x) *pixel++ = color;
            }
        }
    }
}

static void set_key(Apple2 *a, int code)
{
    if (a->pending_keys == KEY_QUEUE_SIZE) return;
    unsigned tail = (a->next_key + a->pending_keys) % KEY_QUEUE_SIZE;
    a->keys[tail] = (uint8_t)code | 0x80;
    ++a->pending_keys;
}

static void handle_key(Apple2 *a, const SDL_KeyboardEvent *event)
{
    SDL_Keycode key = event->keysym.sym;
    if ((event->keysym.mod & KMOD_CTRL) && key >= SDLK_a && key <= SDLK_z) {
        set_key(a, key - SDLK_a + 1);
        return;
    }
    switch (key) {
    case SDLK_RETURN:
    case SDLK_KP_ENTER: set_key(a, 13); break;
    case SDLK_LEFT:
    case SDLK_BACKSPACE: set_key(a, 8); break;
    case SDLK_RIGHT: set_key(a, 21); break;
    case SDLK_ESCAPE: set_key(a, 27); break;
    case SDLK_F2: if (!event->repeat) reset(a, false); break;
    case SDLK_F3: if (!event->repeat) reset(a, true); break;
    case SDLK_F4: apple2_disk_eject(&a->disk); break;
    }
}

static bool handle_events(Apple2 *a)
{
    SDL_Event event;
    while (SDL_PollEvent(&event)) {
        switch (event.type) {
        case SDL_QUIT: return false;
        case SDL_KEYDOWN: handle_key(a, &event.key); break;
        case SDL_TEXTINPUT:
            for (const char *input = event.text.text; *input; ++input) {
                unsigned char ch = (unsigned char)*input;
                if (ch >= 'a' && ch <= 'z') ch -= 'a' - 'A';
                if (ch >= ' ' && ch <= '_') set_key(a, ch);
            }
            break;
        case SDL_DROPFILE:
            if (apple2_disk_mount(&a->disk, event.drop.file)) reset(a, true);
            SDL_free(event.drop.file);
            break;
        }
    }
    return true;
}

static void run_frame(Apple2 *a, uint64_t target, SDL_AudioDeviceID audio)
{
    int16_t samples[AUDIO_HZ / 60 + 8];
    unsigned count = 0;
    while (a->cpu.cycles < target) {
        if (!(a->key & 0x80) && a->pending_keys) {
            a->key = a->keys[a->next_key];
            a->next_key = (a->next_key + 1) % KEY_QUEUE_SIZE;
            --a->pending_keys;
        }
        unsigned cycles;
        if (a->cpu.stopped && !a->cpu.reset_pending) {
            /* A halted CPU leaves the display and disk running. */
            cycles = (unsigned)(target - a->cpu.cycles);
            a->cpu.cycles += cycles;
        } else {
            cycles = (unsigned)cpu6502_step(&a->cpu);
        }
        apple2_disk_tick(&a->disk, cycles);
        if (!audio) continue;

        a->audio_phase += cycles * AUDIO_HZ;
        while (a->audio_phase >= CPU_HZ) {
            a->audio_phase -= CPU_HZ;
            float level = a->speaker ? 5000.0f : -5000.0f;
            samples[count++] = (int16_t)(level - a->audio_level);
            a->audio_level += (level - a->audio_level) * 0.015f;
        }
    }
    if (audio && SDL_GetQueuedAudioSize(audio) < AUDIO_HZ * sizeof(*samples) / 12) {
        SDL_QueueAudio(audio, samples, count * sizeof(*samples));
    }
}

static bool save_frame(Apple2 *a, const char *path)
{
    SDL_Surface *surface = SDL_CreateRGBSurfaceWithFormatFrom(
        a->pixels, VIDEO_WIDTH, VIDEO_HEIGHT, 32, VIDEO_WIDTH * sizeof(uint32_t),
        SDL_PIXELFORMAT_ARGB8888);
    bool ok = surface && SDL_SaveBMP(surface, path) == 0;
    SDL_FreeSurface(surface);
    return ok;
}

int apple2_run(const Config *cfg, const char *disk_path,
               const char *screenshot, int screenshot_frames)
{
    bool capture = *screenshot != '\0';
    int result = 1;
    Apple2 *a = calloc(1, sizeof(*a));
    SDL_Window *window = NULL;
    SDL_Renderer *renderer = NULL;
    SDL_Texture *texture = NULL;
    SDL_AudioDeviceID audio = 0;

    if (!a) {
        fprintf(stderr, "Apple II: out of memory\n");
        return 1;
    }
    if (!disk_path) disk_path = cfg->apple2_disk_image;
    if (!load_rom(cfg->apple2_system_rom, a->rom, sizeof(a->rom)) ||
        !load_rom(cfg->apple2_video_rom, a->video_rom, sizeof(a->video_rom)) ||
        !load_rom(cfg->apple2_disk_rom, a->disk.rom, sizeof(a->disk.rom)) ||
        (*disk_path && !apple2_disk_mount(&a->disk, disk_path))) {
        goto done;
    }

    cpu6502_init(&a->cpu, apple2_read, apple2_write, a);
    a->cpu.nmos_rmw_writes = true;
    a->audio_level = -5000.0f;
    reset(a, true);

    if (!capture) {
        if (SDL_Init(SDL_INIT_VIDEO) < 0) goto sdl_error;
        SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");
        if (SDL_CreateWindowAndRenderer(VIDEO_WIDTH * cfg->window_scale,
                                        VIDEO_HEIGHT * cfg->window_scale,
                                        SDL_WINDOW_RESIZABLE, &window, &renderer) < 0) {
            goto sdl_error;
        }
        SDL_SetWindowTitle(window, "Apple II Plus");
        SDL_RenderSetLogicalSize(renderer, VIDEO_WIDTH, VIDEO_HEIGHT);
        texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ARGB8888,
                                    SDL_TEXTUREACCESS_STREAMING, VIDEO_WIDTH, VIDEO_HEIGHT);
        if (!texture) goto sdl_error;
        SDL_StartTextInput();

        if (SDL_InitSubSystem(SDL_INIT_AUDIO) == 0) {
            SDL_AudioSpec wanted = {.freq = AUDIO_HZ, .format = AUDIO_S16SYS,
                                    .channels = 1, .samples = 1024};
            audio = SDL_OpenAudioDevice(NULL, 0, &wanted, NULL, 0);
            if (audio) SDL_PauseAudioDevice(audio, 0);
        }
        if (!audio) fprintf(stderr, "Apple II: audio unavailable: %s\n", SDL_GetError());
    }

    uint64_t frequency = SDL_GetPerformanceFrequency();
    uint64_t next_frame = SDL_GetPerformanceCounter();
    uint64_t frame_period = frequency * CYCLES_PER_FRAME / CPU_HZ;
    for (unsigned frame = 1; capture || handle_events(a); ++frame) {
        static const unsigned pitch = VIDEO_WIDTH * sizeof(uint32_t);
        run_frame(a, (uint64_t)frame * CYCLES_PER_FRAME, audio);
        if (capture) {
            if (frame != (unsigned)screenshot_frames) continue;
            draw_frame(a, frame);
            if (!save_frame(a, screenshot)) goto sdl_error;
            break;
        }
        draw_frame(a, frame);
        if (SDL_UpdateTexture(texture, NULL, a->pixels, pitch) < 0 ||
            SDL_RenderClear(renderer) < 0 ||
            SDL_RenderCopy(renderer, texture, NULL, NULL) < 0) {
            goto sdl_error;
        }
        SDL_RenderPresent(renderer);
        next_frame += frame_period;
        uint64_t now = SDL_GetPerformanceCounter();
        if (next_frame > now) {
            SDL_Delay((uint32_t)((next_frame - now) * 1000 / frequency));
        } else if (now - next_frame > frame_period) {
            next_frame = now;
        }
    }
    result = 0;
    goto done;

sdl_error:
    fprintf(stderr, "Apple II: %s\n", SDL_GetError());
done:
    if (audio) SDL_CloseAudioDevice(audio);
    if (texture) SDL_DestroyTexture(texture);
    if (renderer) SDL_DestroyRenderer(renderer);
    if (window) SDL_DestroyWindow(window);
    if (!capture) SDL_Quit();
    apple2_disk_eject(&a->disk);
    free(a);
    return result;
}
