#include "nes.h"
#include "nes_content.h"
#include "libretro/libretro.h"
#include <SDL.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#ifdef _WIN32
#define NES_CORE_SUFFIX ".dll"
#elif defined(__APPLE__)
#define NES_CORE_SUFFIX ".dylib"
#else
#define NES_CORE_SUFFIX ".so"
#endif

typedef struct {
    unsigned (*api_version)(void);
    void (*set_environment)(retro_environment_t);
    void (*set_video_refresh)(retro_video_refresh_t);
    void (*set_audio_sample)(retro_audio_sample_t);
    void (*set_audio_sample_batch)(retro_audio_sample_batch_t);
    void (*set_input_poll)(retro_input_poll_t);
    void (*set_input_state)(retro_input_state_t);
    void (*init)(void);
    void (*deinit)(void);
    void (*get_system_info)(struct retro_system_info *);
    void (*get_system_av_info)(struct retro_system_av_info *);
    void (*set_controller_port_device)(unsigned, unsigned);
    bool (*load_game)(const struct retro_game_info *);
    void (*unload_game)(void);
    void (*reset)(void);
    void (*run)(void);
    void *(*get_memory_data)(unsigned);
    size_t (*get_memory_size)(unsigned);
} NesCore;

SDL_COMPILE_TIME_ASSERT(nes_core_symbol, sizeof(void (*)(void)) == sizeof(void *));

typedef struct {
    NesCore core;
    NesContent cartridge;
    struct retro_game_info_ext *loading;
    char *system_dir;
    char *save_dir;
    SDL_Window *window;
    SDL_Renderer *renderer;
    SDL_Texture *texture;
    SDL_AudioDeviceID audio;
    SDL_GameController *controllers[2];
    struct retro_system_av_info av;
    Uint32 video_format;
    unsigned texture_width;
    unsigned texture_height;
    Uint32 audio_limit;
    bool supports_memory_content;
    bool save_writable;
    bool video_failed;
} Nes;

/* Libretro callbacks are synchronous and carry no user data. */
static Nes *active_nes;

static char *join_path(const char *directory, const char *path)
{
    size_t length = strlen(directory) + strlen(path) + 2;
    char *joined = SDL_malloc(length);
    if (joined) SDL_snprintf(joined, length, "%s/%s", directory, path);
    return joined;
}

static bool is_separator(char character)
{
    return character == '/' || character == '\\';
}

static bool is_absolute(const char *path)
{
    return is_separator(path[0]) ||
           (SDL_isalpha((unsigned char)path[0]) && path[1] == ':' && is_separator(path[2]));
}

static const char *basename_of(const char *path)
{
    const char *base = path;
    for (const char *p = path; *p; p++) {
        if (is_separator(*p)) base = p + 1;
    }
    return base;
}

static char *startup_path(const Config *cfg, const char *rom_override)
{
    const char *path = rom_override ? rom_override : cfg->nes_rom;
    if (!*path) return NULL;
    if (!cfg->nes_rom_dir[0] || is_absolute(path)) return SDL_strdup(path);
    if (rom_override) {
        if (path[0] == '.' && (is_separator(path[1]) ||
                               (path[1] == '.' && is_separator(path[2])))) {
            return SDL_strdup(path);
        }
        SDL_RWops *file = SDL_RWFromFile(path, "rb");
        if (file) {
            SDL_RWclose(file);
            return SDL_strdup(path);
        }
    }
    return join_path(cfg->nes_rom_dir, path);
}

static bool bind_core(NesCore *core, void *library)
{
#define BIND(name)                                                            \
    do {                                                                      \
        void *symbol = SDL_LoadFunction(library, "retro_" #name);              \
        if (!symbol) return false;                                             \
        memcpy(&core->name, &symbol, sizeof(symbol));                         \
    } while (0)
    BIND(api_version);
    BIND(set_environment);
    BIND(set_video_refresh);
    BIND(set_audio_sample);
    BIND(set_audio_sample_batch);
    BIND(set_input_poll);
    BIND(set_input_state);
    BIND(init);
    BIND(deinit);
    BIND(get_system_info);
    BIND(get_system_av_info);
    BIND(set_controller_port_device);
    BIND(load_game);
    BIND(unload_game);
    BIND(reset);
    BIND(run);
    BIND(get_memory_data);
    BIND(get_memory_size);
#undef BIND
    return true;
}

static void core_log(enum retro_log_level level, const char *format, ...)
{
    if (level < RETRO_LOG_WARN) return;
    va_list arguments;
    va_start(arguments, format);
    vfprintf(stderr, format, arguments);
    va_end(arguments);
}

static bool environment(unsigned command, void *data)
{
    switch (command) {
    case RETRO_ENVIRONMENT_GET_CAN_DUPE:
        *(bool *)data = true;
        return true;
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
        *(const char **)data = active_nes->system_dir;
        return true;
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
        *(const char **)data = active_nes->save_dir ? active_nes->save_dir : active_nes->system_dir;
        return *(const char **)data != NULL;
    case RETRO_ENVIRONMENT_SET_CONTENT_INFO_OVERRIDE: {
        const struct retro_system_content_info_override *override = data;
        for (; override->extensions; override++) {
            if (!override->need_fullpath && strcmp(override->extensions, "fds|nes|unf|unif") == 0) {
                active_nes->supports_memory_content = true;
                return true;
            }
        }
        return false;
    }
    case RETRO_ENVIRONMENT_GET_GAME_INFO_EXT:
        *(struct retro_game_info_ext **)data = active_nes->loading;
        return active_nes->loading != NULL;
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
        switch (*(const enum retro_pixel_format *)data) {
        case RETRO_PIXEL_FORMAT_0RGB1555:
            active_nes->video_format = SDL_PIXELFORMAT_RGB555;
            return true;
        case RETRO_PIXEL_FORMAT_RGB565:
            active_nes->video_format = SDL_PIXELFORMAT_RGB565;
            return true;
        case RETRO_PIXEL_FORMAT_XRGB8888:
            active_nes->video_format = SDL_PIXELFORMAT_RGB888;
            return true;
        default:
            return false;
        }
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
        *(bool *)data = false;
        return true;
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
        ((struct retro_log_callback *)data)->log = core_log;
        return true;
    default:
        return false;
    }
}

static void video_refresh(const void *data, unsigned width, unsigned height, size_t pitch)
{
    Nes *nes = active_nes;
    if (!data || !nes->renderer || nes->video_failed) return;

    if (!nes->texture || width != nes->texture_width || height != nes->texture_height) {
        SDL_DestroyTexture(nes->texture);
        nes->texture = SDL_CreateTexture(nes->renderer, nes->video_format,
                                         SDL_TEXTUREACCESS_STREAMING, (int)width, (int)height);
        nes->texture_width = width;
        nes->texture_height = height;
    }
    nes->video_failed = !nes->texture || SDL_UpdateTexture(nes->texture, NULL, data, (int)pitch) < 0;
}

static size_t audio_batch(const int16_t *samples, size_t frames)
{
    Nes *nes = active_nes;
    if (nes->audio && SDL_GetQueuedAudioSize(nes->audio) < nes->audio_limit) {
        SDL_QueueAudio(nes->audio, samples, (Uint32)(frames * 2 * sizeof(*samples)));
    }
    return frames;
}

static void audio_sample(int16_t left, int16_t right)
{
    int16_t stereo[] = {left, right};
    audio_batch(stereo, 1);
}

static void input_poll(void)
{
    /* The main loop processes SDL events before each frame. */
}

static int16_t input_state(unsigned port, unsigned device, unsigned index, unsigned id)
{
    static const SDL_Scancode keys[] = {
        [RETRO_DEVICE_ID_JOYPAD_B] = SDL_SCANCODE_X,
        [RETRO_DEVICE_ID_JOYPAD_SELECT] = SDL_SCANCODE_RSHIFT,
        [RETRO_DEVICE_ID_JOYPAD_START] = SDL_SCANCODE_RETURN,
        [RETRO_DEVICE_ID_JOYPAD_UP] = SDL_SCANCODE_UP,
        [RETRO_DEVICE_ID_JOYPAD_DOWN] = SDL_SCANCODE_DOWN,
        [RETRO_DEVICE_ID_JOYPAD_LEFT] = SDL_SCANCODE_LEFT,
        [RETRO_DEVICE_ID_JOYPAD_RIGHT] = SDL_SCANCODE_RIGHT,
        [RETRO_DEVICE_ID_JOYPAD_A] = SDL_SCANCODE_Z,
        [RETRO_DEVICE_ID_JOYPAD_L] = SDL_SCANCODE_F6,
        [RETRO_DEVICE_ID_JOYPAD_R] = SDL_SCANCODE_F7,
        [RETRO_DEVICE_ID_JOYPAD_R2] = SDL_SCANCODE_F8
    };
    static const int buttons[] = {
        [RETRO_DEVICE_ID_JOYPAD_B] = SDL_CONTROLLER_BUTTON_X,
        [RETRO_DEVICE_ID_JOYPAD_SELECT] = SDL_CONTROLLER_BUTTON_BACK,
        [RETRO_DEVICE_ID_JOYPAD_START] = SDL_CONTROLLER_BUTTON_START,
        [RETRO_DEVICE_ID_JOYPAD_UP] = SDL_CONTROLLER_BUTTON_DPAD_UP,
        [RETRO_DEVICE_ID_JOYPAD_DOWN] = SDL_CONTROLLER_BUTTON_DPAD_DOWN,
        [RETRO_DEVICE_ID_JOYPAD_LEFT] = SDL_CONTROLLER_BUTTON_DPAD_LEFT,
        [RETRO_DEVICE_ID_JOYPAD_RIGHT] = SDL_CONTROLLER_BUTTON_DPAD_RIGHT,
        [RETRO_DEVICE_ID_JOYPAD_A] = SDL_CONTROLLER_BUTTON_A,
        [RETRO_DEVICE_ID_JOYPAD_L] = SDL_CONTROLLER_BUTTON_LEFTSHOULDER,
        [RETRO_DEVICE_ID_JOYPAD_R] = SDL_CONTROLLER_BUTTON_RIGHTSHOULDER,
        [RETRO_DEVICE_ID_JOYPAD_R2] = SDL_CONTROLLER_BUTTON_Y
    };
    if (port >= SDL_arraysize(active_nes->controllers) || device != RETRO_DEVICE_JOYPAD ||
        index != 0 || id >= SDL_arraysize(keys) || keys[id] == SDL_SCANCODE_UNKNOWN) {
        return 0;
    }
    SDL_GameController *controller = active_nes->controllers[port];
    SDL_Scancode key = id == RETRO_DEVICE_ID_JOYPAD_A ? SDL_GetScancodeFromKey(SDLK_z) : keys[id];
    return (port == 0 && SDL_GetKeyboardState(NULL)[key]) ||
           (controller && SDL_GameControllerGetButton(controller, buttons[id]));
}

static void controller_added(Nes *nes, int index)
{
    if (!SDL_IsGameController(index)) return;
    SDL_JoystickID instance = SDL_JoystickGetDeviceInstanceID(index);
    for (size_t port = 0; port < SDL_arraysize(nes->controllers); port++) {
        if (nes->controllers[port] &&
            SDL_JoystickInstanceID(SDL_GameControllerGetJoystick(nes->controllers[port])) == instance) {
            return;
        }
    }
    for (size_t port = 0; port < SDL_arraysize(nes->controllers); port++) {
        if (!nes->controllers[port]) {
            nes->controllers[port] = SDL_GameControllerOpen(index);
            return;
        }
    }
}

static void controller_removed(Nes *nes, SDL_JoystickID instance)
{
    for (size_t port = 0; port < SDL_arraysize(nes->controllers); port++) {
        SDL_GameController *controller = nes->controllers[port];
        if (controller && SDL_JoystickInstanceID(SDL_GameControllerGetJoystick(controller)) == instance) {
            SDL_GameControllerClose(controller);
            nes->controllers[port] = NULL;
        }
    }
    for (int index = 0; index < SDL_NumJoysticks(); index++) controller_added(nes, index);
}

static void configure_audio(Nes *nes, bool silent)
{
    if (nes->audio) SDL_CloseAudioDevice(nes->audio);
    nes->audio = 0;
    if (silent) return;

    SDL_AudioSpec format = {0};
    format.freq = (int)(nes->av.timing.sample_rate + 0.5);
    format.format = AUDIO_S16SYS;
    format.channels = 2;
    format.samples = 1024;
    nes->audio_limit = (Uint32)(format.freq / 10) * format.channels * sizeof(int16_t);
    nes->audio = SDL_OpenAudioDevice(NULL, 0, &format, NULL, 0);
    if (nes->audio) {
        SDL_PauseAudioDevice(nes->audio, 0);
    } else {
        fprintf(stderr, "NES: audio unavailable: %s\n", SDL_GetError());
    }
}

static bool battery_ram(Nes *nes, bool write)
{
    if (!nes->save_dir) return true;
    if (write && !nes->save_writable) return true;
    if (!write) nes->save_writable = false;
    size_t size = nes->core.get_memory_size(RETRO_MEMORY_SAVE_RAM);
    void *data = nes->core.get_memory_data(RETRO_MEMORY_SAVE_RAM);
    if (!size || !data) return true;

    char filename[32];
    SDL_snprintf(filename, sizeof(filename), "%08lx.sav", nes_content_checksum(&nes->cartridge));
    char *path = join_path(nes->save_dir, filename);
    if (!path) {
        fprintf(stderr, "NES: out of memory accessing battery save\n");
        return false;
    }

    bool ok = true;
    if (write) {
        ok = nes_save_write(path, data, size);
        if (!ok) fprintf(stderr, "NES: could not write battery save '%s'\n", path);
    } else {
        SDL_RWops *file = SDL_RWFromFile(path, "rb");
        if (file) {
            void *saved = SDL_malloc(size);
            ok = saved && SDL_RWsize(file) == (Sint64)size && SDL_RWread(file, saved, 1, size) == size;
            if (SDL_RWclose(file) != 0) ok = false;
            if (ok) memcpy(data, saved, size);
            else fprintf(stderr, "NES: could not read complete battery save '%s'\n", path);
            SDL_free(saved);
        }
    }
    SDL_free(path);
    if (!write) nes->save_writable = ok;
    return ok;
}

static bool load_game(Nes *nes, const NesContent *content)
{
    const char *path = content->archive_path ? content->archive_path : content->name;
    const char *base = basename_of(content->name);
    size_t dir_length = (size_t)(basename_of(path) - path);
    char *directory = SDL_strdup(dir_length ? path : ".");
    char *name = SDL_strdup(base);
    if (!directory || !name) {
        fprintf(stderr, "NES: out of memory loading '%s'\n", content->name);
        SDL_free(directory);
        SDL_free(name);
        return false;
    }
    if (dir_length) directory[dir_length] = '\0';
    char *dot = strrchr(name, '.');
    *dot = '\0';

    struct retro_game_info_ext extended = {
        .full_path = content->archive_path ? NULL : path,
        .archive_path = content->archive_path,
        .archive_file = content->archive_path ? content->name : NULL,
        .dir = directory, .name = name, .ext = SDL_strlwr(dot + 1),
        .data = content->data, .size = content->size,
        .file_in_archive = content->archive_path != NULL
    };
    const struct retro_game_info game = {
        .path = path, .data = content->data, .size = content->size
    };
    nes->video_format = SDL_PIXELFORMAT_RGB555;
    nes->loading = &extended;
    bool loaded = nes->core.load_game(&game);
    nes->loading = NULL;
    SDL_free(directory);
    SDL_free(name);
    if (!loaded) {
        fprintf(stderr, "NES: core rejected '%s'\n", content->name);
        return false;
    }
    nes->core.get_system_av_info(&nes->av);
    const struct retro_system_timing *timing = &nes->av.timing;
    const struct retro_game_geometry *geometry = &nes->av.geometry;
    if (!(timing->fps >= 1 && timing->fps <= 1000) ||
        !(timing->sample_rate >= 1 && timing->sample_rate <= 384000) ||
        !geometry->base_width || !geometry->base_height ||
        geometry->base_width > 1024 || geometry->base_height > 1024 ||
        !(geometry->aspect_ratio >= 0 && geometry->aspect_ratio <= 8)) {
        fprintf(stderr, "NES: invalid video or audio configuration from core\n");
        nes->core.unload_game();
        return false;
    }
    nes->core.set_controller_port_device(0, RETRO_DEVICE_JOYPAD);
    nes->core.set_controller_port_device(1, RETRO_DEVICE_JOYPAD);
    return true;
}

static void update_window(Nes *nes, int scale)
{
    const struct retro_game_geometry *geometry = &nes->av.geometry;
    int height = (int)geometry->base_height;
    int width = geometry->aspect_ratio > 0
        ? (int)(height * geometry->aspect_ratio + 0.5f) : (int)geometry->base_width;
    char title[256];
    SDL_snprintf(title, sizeof(title), "6502 SBC Emulator - NES - %s", basename_of(nes->cartridge.name));
    SDL_SetWindowTitle(nes->window, title);
    SDL_SetWindowSize(nes->window, width * scale, height * scale);
    SDL_RenderSetLogicalSize(nes->renderer, width, height);
    SDL_DestroyTexture(nes->texture);
    nes->texture = NULL;
}

static bool change_game(Nes *nes, const char *path, int scale, bool silent)
{
    NesContent next;
    if (!nes_content_load(&next, path)) return true;

    if (!battery_ram(nes, true)) {
        nes_content_free(&next);
        return true;
    }
    nes->core.unload_game();
    if (load_game(nes, &next)) {
        nes_content_free(&nes->cartridge);
        nes->cartridge = next;
    } else {
        nes_content_free(&next);
        if (!load_game(nes, &nes->cartridge)) {
            nes_content_free(&nes->cartridge);
            return false;
        }
    }
    battery_ram(nes, false);
    update_window(nes, scale);
    configure_audio(nes, silent);
    return true;
}

static bool screenshot_frame(Nes *nes, const char *path)
{
    int width, height;
    if (SDL_GetRendererOutputSize(nes->renderer, &width, &height) < 0) return false;
    SDL_Surface *surface = SDL_CreateRGBSurfaceWithFormat(0, width, height, 32, SDL_PIXELFORMAT_ARGB8888);
    if (!surface) return false;
    bool ok = SDL_RenderReadPixels(nes->renderer, NULL, surface->format->format,
                                   surface->pixels, surface->pitch) == 0 && SDL_SaveBMP(surface, path) == 0;
    SDL_FreeSurface(surface);
    return ok;
}

static int run_frames(Nes *nes, int scale, const char *screenshot, int target_frames)
{
    double ticks_per_second = (double)SDL_GetPerformanceFrequency();
    double deadline = (double)SDL_GetPerformanceCounter();
    bool capture = *screenshot != '\0';
    int frames = 0;
    for (;;) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT ||
                (event.type == SDL_KEYDOWN && event.key.keysym.scancode == SDL_SCANCODE_ESCAPE)) {
                return capture ? 1 : 0;
            }
            if (event.type == SDL_KEYDOWN && event.key.keysym.scancode == SDL_SCANCODE_F5) {
                nes->core.reset();
            } else if (event.type == SDL_CONTROLLERDEVICEADDED) {
                controller_added(nes, event.cdevice.which);
            } else if (event.type == SDL_CONTROLLERDEVICEREMOVED) {
                controller_removed(nes, event.cdevice.which);
            } else if (event.type == SDL_DROPFILE) {
                bool ok = change_game(nes, event.drop.file, scale, capture);
                SDL_free(event.drop.file);
                if (!ok) return 1;
                deadline = (double)SDL_GetPerformanceCounter();
            }
        }

        nes->core.run();
        if (nes->video_failed || SDL_RenderClear(nes->renderer) < 0 ||
            (nes->texture && SDL_RenderCopy(nes->renderer, nes->texture, NULL, NULL) < 0)) {
            fprintf(stderr, "NES: rendering failed: %s\n", SDL_GetError());
            return 1;
        }
        if (capture && ++frames >= target_frames) {
            if (nes->texture && screenshot_frame(nes, screenshot)) return 0;
            fprintf(stderr, "NES: could not save screenshot '%s': %s\n", screenshot, SDL_GetError());
            return 1;
        }
        SDL_RenderPresent(nes->renderer);
        if (!capture) {
            double frame_ticks = ticks_per_second / nes->av.timing.fps;
            deadline += frame_ticks;
            double remaining = deadline - (double)SDL_GetPerformanceCounter();
            if (remaining > 0) SDL_Delay((Uint32)(remaining * 1000 / ticks_per_second));
            if (remaining < -2 * frame_ticks) deadline -= remaining;
        }
    }
}

int nes_run(const Config *cfg, const char *rom_override, const char *screenshot, int screenshot_frames)
{
    bool capture = *screenshot != '\0';
    char *path = startup_path(cfg, rom_override);
    if (!path) {
        fprintf(stderr, "NES: set [nes] rom in the INI or pass --load <cartridge>\n");
        return 1;
    }

    Nes nes = {0};
    bool core_ready = false;
    bool game_loaded = false;
    int status = 1;
    void *library = NULL;
    char *base_path = SDL_GetBasePath();
    char *core_path = NULL;
    const char *core_file = cfg->nes_sbc_cpu ? "cores/fceumm_sbc_cpu_libretro" NES_CORE_SUFFIX
                                            : "cores/fceumm_libretro" NES_CORE_SUFFIX;
    if (cfg->nes_core[0]) {
        core_path = is_absolute(cfg->nes_core) ? SDL_strdup(cfg->nes_core)
                                               : join_path(".", cfg->nes_core);
    } else if (base_path) {
        core_path = join_path(base_path, core_file);
    }

    if (!nes_content_load(&nes.cartridge, path)) goto done;
    library = core_path ? SDL_LoadObject(core_path) : NULL;
    if (!library) {
        fprintf(stderr, "NES: could not load the FCEUmm core '%s': %s\n",
                core_path ? core_path : core_file, SDL_GetError());
        fprintf(stderr, "%s\n", cfg->nes_sbc_cpu
                ? "NES: build the SBC CPU core with make nes-sbc-core, or set [nes] core"
                : "NES: install the core in the executable's cores directory or set [nes] core");
        goto done;
    }
    if (!bind_core(&nes.core, library) || nes.core.api_version() != RETRO_API_VERSION) {
        fprintf(stderr, "NES: incompatible libretro core '%s'\n", core_path);
        goto done;
    }
    struct retro_system_info info = {0};
    nes.core.get_system_info(&info);
    const char *core_name = cfg->nes_sbc_cpu ? "FCEUmm (SBC CPU)" : "FCEUmm";
    if (!info.library_name || SDL_strcasecmp(info.library_name, core_name) != 0) {
        fprintf(stderr, "NES: expected the '%s' libretro core, got '%s'\n", core_name,
                info.library_name ? info.library_name : "unknown");
        goto done;
    }

    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMECONTROLLER) < 0) {
        fprintf(stderr, "NES: SDL initialization failed: %s\n", SDL_GetError());
        goto done;
    }
    if (!capture) {
        SDL_InitSubSystem(SDL_INIT_AUDIO);
        nes.save_dir = SDL_GetPrefPath("6502-sbc-emulator", cfg->nes_sbc_cpu ? "NES SBC CPU" : "NES");
        if (!nes.save_dir) fprintf(stderr, "NES: battery saves unavailable: %s\n", SDL_GetError());
    }
    nes.system_dir = cfg->nes_system_dir[0] ? SDL_strdup(cfg->nes_system_dir) : base_path;
    if (nes.system_dir == base_path) base_path = NULL;
    active_nes = &nes;
    nes.supports_memory_content = !info.need_fullpath;
    nes.core.set_environment(environment);
    if (!nes.supports_memory_content) {
        fprintf(stderr, "NES: this FCEUmm core does not support loading ROM data from memory\n");
        goto done;
    }
    nes.core.set_video_refresh(video_refresh);
    nes.core.set_audio_sample(audio_sample);
    nes.core.set_audio_sample_batch(audio_batch);
    nes.core.set_input_poll(input_poll);
    nes.core.set_input_state(input_state);
    nes.core.init();
    core_ready = true;
    if (!load_game(&nes, &nes.cartridge)) goto done;
    game_loaded = true;
    battery_ram(&nes, false);

    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");
    nes.window = SDL_CreateWindow("6502 SBC Emulator - NES", SDL_WINDOWPOS_CENTERED,
                                  SDL_WINDOWPOS_CENTERED, 320, 240,
                                  capture ? SDL_WINDOW_HIDDEN : SDL_WINDOW_RESIZABLE);
    if (nes.window) {
        nes.renderer = SDL_CreateRenderer(nes.window, -1, SDL_RENDERER_ACCELERATED);
        if (!nes.renderer) nes.renderer = SDL_CreateRenderer(nes.window, -1, SDL_RENDERER_SOFTWARE);
    }
    if (!nes.renderer) {
        fprintf(stderr, "NES: could not create SDL window or renderer: %s\n", SDL_GetError());
        goto done;
    }
    update_window(&nes, cfg->window_scale);
    configure_audio(&nes, capture);
    for (int index = 0; index < SDL_NumJoysticks(); index++) controller_added(&nes, index);
    SDL_EventState(SDL_DROPFILE, SDL_ENABLE);
    printf("NES: %s (%s), %.3f Hz\n", basename_of(nes.cartridge.name), info.library_name, nes.av.timing.fps);
    status = run_frames(&nes, cfg->window_scale, screenshot, screenshot_frames);

done:
    if (game_loaded && nes.cartridge.data) {
        if (!battery_ram(&nes, true)) status = 1;
        nes.core.unload_game();
    }
    if (core_ready) nes.core.deinit();
    active_nes = NULL;
    if (nes.audio) SDL_CloseAudioDevice(nes.audio);
    for (size_t port = 0; port < SDL_arraysize(nes.controllers); port++) {
        if (nes.controllers[port]) SDL_GameControllerClose(nes.controllers[port]);
    }
    SDL_DestroyTexture(nes.texture);
    SDL_DestroyRenderer(nes.renderer);
    SDL_DestroyWindow(nes.window);
    if (library) SDL_UnloadObject(library);
    SDL_Quit();
    nes_content_free(&nes.cartridge);
    SDL_free(nes.save_dir);
    SDL_free(nes.system_dir);
    SDL_free(base_path);
    SDL_free(core_path);
    SDL_free(path);
    return status;
}
