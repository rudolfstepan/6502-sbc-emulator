/*
 * bench_mandelbrot.c — Mandelbrot SIMD benchmark
 *
 * Renders a 1280×960 Mandelbrot set using a scalar float path and a SIMD
 * path (SSE2 on x86-64, NEON on ARM), then compares wall-clock times.
 *
 * Build via:  make bench-mandelbrot
 * Or manually:
 *   gcc -std=c99 -O3 -msse2 -I src tests/bench_mandelbrot.c -o bench_mandelbrot
 *
 * Optional argument:  bench_mandelbrot mandelbrot.ppm
 *   Saves the rendered image as a binary PPM (P6) for visual inspection.
 */

#ifndef _WIN32
#  define _POSIX_C_SOURCE 200809L
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#ifdef _WIN32
#  include <windows.h>
#else
#  include <time.h>
#endif

#include "../src/simd.h"

#if defined(SIMD_SSE2)
#  include <xmmintrin.h>   /* _mm_cmple_ps, _mm_movemask_ps (SSE, pulled in by emmintrin.h) */
#endif

/* ------------------------------------------------------------------ */
/* Configuration                                                        */
/* ------------------------------------------------------------------ */

#define WIDTH       1280
#define HEIGHT       960
#define MAX_ITER     512
#define BENCH_RUNS     5   /* timed passes; best is reported */

/* Mandelbrot region: covers [-2.5,1.5] × [-1.5,1.5], 4:3 aspect */
#define X_MIN  (-2.5f)
#define X_MAX  ( 1.5f)
#define Y_MIN  (-1.5f)
#define Y_MAX  ( 1.5f)

/* ------------------------------------------------------------------ */
/* High-resolution monotonic timer                                      */
/* ------------------------------------------------------------------ */

#ifdef _WIN32
static void monotonic_now(struct timespec *ts)
{
    static LARGE_INTEGER freq;
    static int init = 0;
    LARGE_INTEGER ctr;
    if (!init) { QueryPerformanceFrequency(&freq); init = 1; }
    QueryPerformanceCounter(&ctr);
    ts->tv_sec  = (time_t)(ctr.QuadPart / freq.QuadPart);
    ts->tv_nsec = (long)(((ctr.QuadPart % freq.QuadPart) * 1000000000LL)
                         / freq.QuadPart);
}
#else
static void monotonic_now(struct timespec *ts)
{
    clock_gettime(CLOCK_MONOTONIC, ts);
}
#endif

static double ts_diff_ms(struct timespec a, struct timespec b)
{
    return (b.tv_sec - a.tv_sec) * 1000.0
         + (b.tv_nsec - a.tv_nsec) * 1e-6;
}

/* ------------------------------------------------------------------ */
/* Pixel buffer and PPM output                                          */
/* ------------------------------------------------------------------ */

static uint16_t g_pixels[HEIGHT * WIDTH];  /* 16-bit iter counts */

/* Simple smooth colormap: black interior, banded exterior.
   Maps iter in [0..MAX_ITER) to an ARGB colour; MAX_ITER → black. */
static void iter_to_rgb(int iter, uint8_t *r, uint8_t *g, uint8_t *b)
{
    if (iter >= MAX_ITER) { *r = *g = *b = 0; return; }
    /* Cycle the palette 8 times across max iter range */
    unsigned t = (unsigned)((iter * 8) & 0xFF);
    if (t < 85u) {
        *r = (uint8_t)(t * 3u);
        *g = 0;
        *b = (uint8_t)(255u - t * 3u);
    } else if (t < 170u) {
        t -= 85u;
        *r = (uint8_t)(255u - t * 3u);
        *g = (uint8_t)(t * 3u);
        *b = 0;
    } else {
        t -= 170u;
        *r = 0;
        *g = (uint8_t)(255u - t * 3u);
        *b = (uint8_t)(t * 3u);
    }
}

static int save_ppm(const char *path, const uint16_t *px, int w, int h)
{
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); return -1; }
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    for (int i = 0; i < w * h; i++) {
        uint8_t r, g, b;
        iter_to_rgb((int)px[i], &r, &g, &b);
        fputc(r, f); fputc(g, f); fputc(b, f);
    }
    fclose(f);
    return 0;
}

/* BMP writer — no external dependencies, opens natively on Windows.
 * Writes a 24-bit top-down BMP (negative biHeight).
 * Row stride is padded to a 4-byte boundary. */
static void bmp_w16(FILE *f, uint16_t v)
{
    fputc(v & 0xFF, f); fputc(v >> 8, f);
}
static void bmp_w32(FILE *f, uint32_t v)
{
    fputc( v        & 0xFF, f); fputc((v >>  8) & 0xFF, f);
    fputc((v >> 16) & 0xFF, f); fputc((v >> 24) & 0xFF, f);
}

static int save_bmp(const char *path, const uint16_t *px, int w, int h)
{
    /* Row size padded to 4-byte boundary; BGR pixel order */
    const int row_stride = (w * 3 + 3) & ~3;
    const uint32_t px_bytes = (uint32_t)(row_stride * h);
    const uint32_t file_size = 54u + px_bytes;

    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); return -1; }

    /* BITMAPFILEHEADER (14 bytes) */
    fputc('B', f); fputc('M', f);
    bmp_w32(f, file_size);
    bmp_w16(f, 0); bmp_w16(f, 0);   /* reserved */
    bmp_w32(f, 54);                  /* pixel data offset */

    /* BITMAPINFOHEADER (40 bytes) */
    bmp_w32(f, 40);                  /* header size */
    bmp_w32(f, (uint32_t)w);
    bmp_w32(f, (uint32_t)-h);        /* negative = top-down storage */
    bmp_w16(f, 1);                   /* color planes */
    bmp_w16(f, 24);                  /* bits per pixel */
    bmp_w32(f, 0);                   /* BI_RGB — no compression */
    bmp_w32(f, px_bytes);
    bmp_w32(f, 2835); bmp_w32(f, 2835); /* 72 dpi */
    bmp_w32(f, 0); bmp_w32(f, 0);   /* palette entries */

    /* Pixel data: BGR, rows padded to row_stride */
    uint8_t *row_buf = (uint8_t *)calloc(1, (size_t)row_stride);
    if (!row_buf) { fclose(f); return -1; }
    for (int y = 0; y < h; y++) {
        const uint16_t *src = px + y * w;
        for (int x = 0; x < w; x++) {
            uint8_t r, g, b;
            iter_to_rgb((int)src[x], &r, &g, &b);
            row_buf[x * 3 + 0] = b;  /* BMP stores BGR */
            row_buf[x * 3 + 1] = g;
            row_buf[x * 3 + 2] = r;
        }
        fwrite(row_buf, 1, (size_t)row_stride, f);
    }
    free(row_buf);
    fclose(f);
    return 0;
}

/* Save PPM or BMP depending on file extension */
static int save_image(const char *path, const uint16_t *px, int w, int h)
{
    const char *ext = strrchr(path, '.');
    if (ext && (strcmp(ext, ".bmp") == 0 || strcmp(ext, ".BMP") == 0))
        return save_bmp(path, px, w, h);
    return save_ppm(path, px, w, h);
}

/* ------------------------------------------------------------------ */
/* Scalar implementation                                                */
/* ------------------------------------------------------------------ */

static void mandelbrot_scalar(uint16_t * restrict out, int w, int h,
                               int max_iter)
{
    const float dx = (X_MAX - X_MIN) / (float)w;
    const float dy = (Y_MAX - Y_MIN) / (float)h;

    for (int row = 0; row < h; row++) {
        const float cy = Y_MIN + (float)row * dy;
        uint16_t * restrict row_out = out + row * w;

        for (int col = 0; col < w; col++) {
            const float cx = X_MIN + (float)col * dx;
            float zr = 0.0f, zi = 0.0f;
            int iter = 0;
            while (iter < max_iter) {
                const float zr2 = zr * zr;
                const float zi2 = zi * zi;
                if (zr2 + zi2 > 4.0f) break;
                zi = 2.0f * zr * zi + cy;
                zr = zr2 - zi2 + cx;
                iter++;
            }
            row_out[col] = (uint16_t)iter;
        }
    }
}

/* ------------------------------------------------------------------ */
/* SSE2 implementation (4 × float32 per iteration)                     */
/* ------------------------------------------------------------------ */

#if defined(SIMD_SSE2)

static void mandelbrot_simd(uint16_t * restrict out, int w, int h,
                             int max_iter)
{
    const float dx = (X_MAX - X_MIN) / (float)w;
    const float dy = (Y_MAX - Y_MIN) / (float)h;

    const __m128 v4   = _mm_set1_ps(4.0f);
    const __m128 v2   = _mm_set1_ps(2.0f);

    for (int row = 0; row < h; row++) {
        const float cy_f = Y_MIN + (float)row * dy;
        const __m128 cy  = _mm_set1_ps(cy_f);
        uint16_t * restrict row_out = out + row * w;

        /* Process 4 pixels per iteration */
        int col = 0;
        for (; col + 4 <= w; col += 4) {
            __m128 cx = _mm_set_ps(
                X_MIN + (float)(col + 3) * dx,
                X_MIN + (float)(col + 2) * dx,
                X_MIN + (float)(col + 1) * dx,
                X_MIN + (float)(col + 0) * dx);

            __m128  zr    = _mm_setzero_ps();
            __m128  zi    = _mm_setzero_ps();
            __m128i count = _mm_setzero_si128();

            for (int iter = 0; iter < max_iter; iter++) {
                const __m128 zr2  = _mm_mul_ps(zr, zr);
                const __m128 zi2  = _mm_mul_ps(zi, zi);
                const __m128 mag2 = _mm_add_ps(zr2, zi2);

                /* active[i] = 0xFFFFFFFF if pixel i has not yet escaped */
                const __m128 active = _mm_cmple_ps(mag2, v4);
                if (_mm_movemask_ps(active) == 0) break;

                /* count++ for still-active lanes (subtract -1 = add 1) */
                count = _mm_sub_epi32(count, _mm_castps_si128(active));

                /* Update z only for active lanes */
                const __m128 new_zi = _mm_add_ps(
                    _mm_mul_ps(_mm_mul_ps(v2, zr), zi), cy);
                const __m128 new_zr = _mm_add_ps(
                    _mm_sub_ps(zr2, zi2), cx);

                zi = _mm_or_ps(_mm_and_ps(active, new_zi),
                               _mm_andnot_ps(active, zi));
                zr = _mm_or_ps(_mm_and_ps(active, new_zr),
                               _mm_andnot_ps(active, zr));
            }

            int32_t c[4];
            _mm_storeu_si128((__m128i *)c, count);
            row_out[col + 0] = (uint16_t)c[0];
            row_out[col + 1] = (uint16_t)c[1];
            row_out[col + 2] = (uint16_t)c[2];
            row_out[col + 3] = (uint16_t)c[3];
        }

        /* Scalar tail for widths not divisible by 4 */
        for (; col < w; col++) {
            const float cx = X_MIN + (float)col * dx;
            float zr = 0.0f, zi = 0.0f;
            int iter = 0;
            while (iter < max_iter) {
                const float zr2 = zr * zr, zi2 = zi * zi;
                if (zr2 + zi2 > 4.0f) break;
                zi = 2.0f * zr * zi + cy_f;
                zr = zr2 - zi2 + cx;
                iter++;
            }
            row_out[col] = (uint16_t)iter;
        }
    }
}

/* ------------------------------------------------------------------ */
/* NEON implementation (4 × float32 per iteration)                     */
/* ------------------------------------------------------------------ */

#elif defined(SIMD_NEON)

static void mandelbrot_simd(uint16_t * restrict out, int w, int h,
                             int max_iter)
{
    const float dx = (X_MAX - X_MIN) / (float)w;
    const float dy = (Y_MAX - Y_MIN) / (float)h;

    for (int row = 0; row < h; row++) {
        const float cy_f = Y_MIN + (float)row * dy;
        const float32x4_t cy = vdupq_n_f32(cy_f);
        uint16_t * restrict row_out = out + row * w;

        int col = 0;
        for (; col + 4 <= w; col += 4) {
            const float cx_arr[4] = {
                X_MIN + (float)(col + 0) * dx,
                X_MIN + (float)(col + 1) * dx,
                X_MIN + (float)(col + 2) * dx,
                X_MIN + (float)(col + 3) * dx
            };
            float32x4_t cx = vld1q_f32(cx_arr);

            float32x4_t zr = vdupq_n_f32(0.0f);
            float32x4_t zi = vdupq_n_f32(0.0f);
            uint32x4_t  count = vdupq_n_u32(0);

            for (int iter = 0; iter < max_iter; iter++) {
                const float32x4_t zr2  = vmulq_f32(zr, zr);
                const float32x4_t zi2  = vmulq_f32(zi, zi);
                const float32x4_t mag2 = vaddq_f32(zr2, zi2);

                /* active[i] = 0xFFFFFFFF if not escaped */
                const uint32x4_t active = vcleq_f32(mag2, vdupq_n_f32(4.0f));

                /* Early exit: check if any lane is non-zero */
                uint64x2_t r64 = vreinterpretq_u64_u32(active);
                if (vgetq_lane_u64(r64, 0) == 0 && vgetq_lane_u64(r64, 1) == 0)
                    break;

                count = vaddq_u32(count, vandq_u32(active, vdupq_n_u32(1)));

                const float32x4_t new_zi = vaddq_f32(
                    vmulq_f32(vdupq_n_f32(2.0f), vmulq_f32(zr, zi)), cy);
                const float32x4_t new_zr = vaddq_f32(
                    vsubq_f32(zr2, zi2), cx);

                zi = vbslq_f32(active, new_zi, zi);
                zr = vbslq_f32(active, new_zr, zr);
            }

            uint32_t c[4];
            vst1q_u32(c, count);
            row_out[col + 0] = (uint16_t)c[0];
            row_out[col + 1] = (uint16_t)c[1];
            row_out[col + 2] = (uint16_t)c[2];
            row_out[col + 3] = (uint16_t)c[3];
        }

        for (; col < w; col++) {
            const float cx = X_MIN + (float)col * dx;
            float zr = 0.0f, zi = 0.0f;
            int iter = 0;
            while (iter < max_iter) {
                const float zr2 = zr * zr, zi2 = zi * zi;
                if (zr2 + zi2 > 4.0f) break;
                zi = 2.0f * zr * zi + cy_f;
                zr = zr2 - zi2 + cx;
                iter++;
            }
            row_out[col] = (uint16_t)iter;
        }
    }
}

#else   /* no SIMD */

static void mandelbrot_simd(uint16_t * restrict out, int w, int h,
                             int max_iter)
{
    mandelbrot_scalar(out, w, h, max_iter);
}

#endif  /* SIMD dispatch */

/* ------------------------------------------------------------------ */
/* Benchmark harness                                                    */
/* ------------------------------------------------------------------ */

typedef void (*render_fn)(uint16_t *, int, int, int);

static double run_bench(render_fn fn, uint16_t *buf, int runs)
{
    double best = 1e18;

    /* Warmup */
    fn(buf, WIDTH, HEIGHT, MAX_ITER);

    for (int r = 0; r < runs; r++) {
        struct timespec t0, t1;
        monotonic_now(&t0);
        fn(buf, WIDTH, HEIGHT, MAX_ITER);
        monotonic_now(&t1);
        double ms = ts_diff_ms(t0, t1);
        if (ms < best) best = ms;
    }
    return best;
}

/* ------------------------------------------------------------------ */
/* main                                                                  */
/* ------------------------------------------------------------------ */

int main(int argc, char *argv[])
{
    const char *out_path = (argc > 1) ? argv[1] : "mandelbrot.bmp";

    /* Platform info */
    printf("Mandelbrot benchmark  %dx%d  max_iter=%d  runs=%d\n",
           WIDTH, HEIGHT, MAX_ITER, BENCH_RUNS);
#if defined(SIMD_SSE2)
    printf("SIMD backend : SSE2 (4 x float32)\n");
#elif defined(SIMD_NEON)
    printf("SIMD backend : NEON (4 x float32)\n");
#else
    printf("SIMD backend : none (scalar fallback)\n");
#endif
    printf("Total pixels : %d (%.1f Mpix)\n\n",
           WIDTH * HEIGHT, WIDTH * HEIGHT / 1e6);

    /* --- Scalar --- */
    printf("Scalar  ... ");
    fflush(stdout);
    double scalar_ms = run_bench(mandelbrot_scalar, g_pixels, BENCH_RUNS);
    printf("best %7.1f ms   %5.1f Mpix/s\n",
           scalar_ms, (WIDTH * HEIGHT / 1e6) / (scalar_ms / 1000.0));

    /* Save scalar result for comparison */
    uint16_t *ref = malloc((size_t)WIDTH * HEIGHT * sizeof(uint16_t));
    if (!ref) { fputs("out of memory\n", stderr); return 1; }
    memcpy(ref, g_pixels, (size_t)WIDTH * HEIGHT * sizeof(uint16_t));

    /* --- SIMD --- */
    printf("SIMD    ... ");
    fflush(stdout);
    double simd_ms = run_bench(mandelbrot_simd, g_pixels, BENCH_RUNS);
    printf("best %7.1f ms   %5.1f Mpix/s\n",
           simd_ms, (WIDTH * HEIGHT / 1e6) / (simd_ms / 1000.0));

    /* --- Summary --- */
    printf("\nSpeedup : %.2fx\n", scalar_ms / simd_ms);

    /* --- Correctness check --- */
    int diffs = 0;
    for (int i = 0; i < WIDTH * HEIGHT; i++)
        if (g_pixels[i] != ref[i]) diffs++;
    if (diffs == 0)
        printf("Correctness: PASS (scalar == SIMD, every pixel identical)\n");
    else
        printf("Correctness: %d pixels differ (%.2f%%)\n",
               diffs, 100.0 * diffs / (WIDTH * HEIGHT));
    free(ref);

    /* --- Image output --- */
    if (save_image(out_path, g_pixels, WIDTH, HEIGHT) == 0)
        printf("Image saved : %s\n", out_path);

    return 0;
}
