#include "nes_content.h"
#ifndef MINIZ_NO_ZLIB_APIS
#define MINIZ_NO_ZLIB_APIS
#endif
#include "miniz/miniz.h"
#include <SDL.h>
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif

#define NES_CONTENT_LIMIT (64u * 1024 * 1024)

static bool has_extension(const char *name, const char *extension)
{
    const char *dot = strrchr(name, '.');
    return dot && SDL_strcasecmp(dot, extension) == 0;
}

static bool is_cartridge(const char *name)
{
    return has_extension(name, ".nes") || has_extension(name, ".unf") ||
           has_extension(name, ".unif") || has_extension(name, ".fds");
}

static bool read_file(NesContent *content, const char *path)
{
    SDL_RWops *file = SDL_RWFromFile(path, "rb");
    if (!file) {
        fprintf(stderr, "NES: cannot open '%s': %s\n", path, SDL_GetError());
        return false;
    }

    Sint64 size = SDL_RWsize(file);
    if (size <= 0 || size > NES_CONTENT_LIMIT) {
        fprintf(stderr, "NES: '%s' must contain between 1 byte and 64 MiB\n", path);
        SDL_RWclose(file);
        return false;
    }
    content->size = (size_t)size;
    content->data = SDL_malloc(content->size);
    bool ok = content->data && SDL_RWread(file, content->data, 1, content->size) == content->size;
    SDL_RWclose(file);
    if (!ok) {
        fprintf(stderr, "NES: could not read '%s'\n", path);
    }
    return ok;
}

static bool extract_cartridge(NesContent *content, const NesContent *archive, const char *path)
{
    mz_zip_archive zip = {0};
    if (!mz_zip_reader_init_mem(&zip, archive->data, archive->size, 0)) {
        fprintf(stderr, "NES: cannot read ZIP '%s': %s\n", path,
                mz_zip_get_error_string(mz_zip_peek_last_error(&zip)));
        return false;
    }

    unsigned matches = 0;
    mz_zip_archive_file_stat cartridge = {0};
    for (mz_uint index = 0; index < mz_zip_reader_get_num_files(&zip); index++) {
        mz_zip_archive_file_stat entry;
        if (mz_zip_reader_file_stat(&zip, index, &entry) && !entry.m_is_directory &&
            is_cartridge(entry.m_filename)) {
            cartridge = entry;
            matches++;
        }
    }

    bool ok = false;
    if (matches != 1) {
        fprintf(stderr, "NES: '%s' must contain exactly one NES/Famicom ROM (found %u)\n",
                path, matches);
    } else if (!cartridge.m_is_supported || cartridge.m_uncomp_size == 0 ||
               cartridge.m_uncomp_size > NES_CONTENT_LIMIT) {
        fprintf(stderr, "NES: unsupported ZIP entry '%s' in '%s'\n", cartridge.m_filename, path);
    } else {
        content->size = (size_t)cartridge.m_uncomp_size;
        content->data = SDL_malloc(content->size);
        content->name = SDL_strdup(cartridge.m_filename);
        content->archive_path = SDL_strdup(path);
        ok = content->data && content->name && content->archive_path &&
             mz_zip_reader_extract_to_mem(&zip, cartridge.m_file_index, content->data,
                                          content->size, 0);
        if (!ok) {
            fprintf(stderr, "NES: could not unpack '%s' from '%s'\n", cartridge.m_filename, path);
        }
    }
    mz_zip_reader_end(&zip);
    return ok;
}

bool nes_content_load(NesContent *content, const char *path)
{
    *content = (NesContent){0};
    bool zipped = has_extension(path, ".zip");
    if (!zipped && !is_cartridge(path)) {
        fprintf(stderr, "NES: expected .nes, .unf, .unif, .fds or .zip, got '%s'\n", path);
        return false;
    }

    NesContent file = {0};
    bool ok = read_file(&file, path);
    if (ok && zipped) {
        ok = extract_cartridge(content, &file, path);
    } else if (ok) {
        *content = file;
        file = (NesContent){0};
        content->name = SDL_strdup(path);
        ok = content->name != NULL;
        if (!ok) fprintf(stderr, "NES: out of memory reading '%s'\n", path);
    }
    nes_content_free(&file);
    if (!ok) nes_content_free(content);
    return ok;
}

void nes_content_free(NesContent *content)
{
    SDL_free(content->data);
    SDL_free(content->name);
    SDL_free(content->archive_path);
    *content = (NesContent){0};
}

unsigned long nes_content_checksum(const NesContent *content)
{
    return mz_crc32(MZ_CRC32_INIT, content->data, content->size);
}

bool nes_save_write(const char *path, const void *data, size_t size)
{
#ifdef _WIN32
    unsigned long process = GetCurrentProcessId();
#else
    unsigned long process = (unsigned long)getpid();
#endif
    char *temporary = NULL;
    if (SDL_asprintf(&temporary, "%s.tmp.%lu", path, process) < 0) return false;
    SDL_RWops *file = SDL_RWFromFile(temporary, "wb");
    bool complete = false;
    if (file) {
        complete = SDL_RWwrite(file, data, 1, size) == size;
        if (SDL_RWclose(file) != 0) complete = false;
    }

    /* Leave the previous save intact if writing or replacing fails. */
#ifdef _WIN32
    wchar_t *from = (wchar_t *)SDL_iconv_string("UTF-16LE", "UTF-8", temporary,
                                                strlen(temporary) + 1);
    wchar_t *to = (wchar_t *)SDL_iconv_string("UTF-16LE", "UTF-8", path, strlen(path) + 1);
    bool saved = complete && from && to && MoveFileExW(from, to, MOVEFILE_REPLACE_EXISTING);
    if (!saved && from) DeleteFileW(from);
    SDL_free(from);
    SDL_free(to);
#else
    bool saved = complete && rename(temporary, path) == 0;
    if (!saved) unlink(temporary);
#endif
    SDL_free(temporary);
    return saved;
}
