#ifndef SIMD_H
#define SIMD_H

#include <stdint.h>
#include <stddef.h>

/*
 * ISA detection — checked in priority order so that x86-64 MSVC (_M_X64)
 * and GCC/Clang (__SSE2__) both resolve to SSE2, and every ARM64 target
 * resolves to NEON without extra compiler flags.
 */
#if defined(__SSE2__) || defined(_M_X64) || \
    (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
#  define SIMD_SSE2 1
#  include <emmintrin.h>   /* SSE2 intrinsics */
#elif defined(__aarch64__) || defined(_M_ARM64) || defined(__ARM_NEON__)
#  define SIMD_NEON 1
#  include <arm_neon.h>
#endif

/*
 * simd_fill_u32
 *   Fill `n` elements of dst[] with the 32-bit value `val`.
 *   Falls back to a plain loop the compiler will auto-vectorise.
 */
static inline void simd_fill_u32(uint32_t * restrict dst, uint32_t val,
                                  size_t n) {
#if defined(SIMD_SSE2)
    __m128i v = _mm_set1_epi32((int)val);
    size_t i = 0;
    for (; i + 4 <= n; i += 4)
        _mm_storeu_si128((__m128i *)(dst + i), v);
    for (; i < n; i++)
        dst[i] = val;
#elif defined(SIMD_NEON)
    uint32x4_t v = vdupq_n_u32(val);
    size_t i = 0;
    for (; i + 4 <= n; i += 4)
        vst1q_u32(dst + i, v);
    for (; i < n; i++)
        dst[i] = val;
#else
    for (size_t i = 0; i < n; i++)
        dst[i] = val;
#endif
}

/*
 * simd_render_char_row_x2
 *   Expand one 8-pixel font row (`pat`, LSB = leftmost pixel) to 2x scale
 *   and write two identical output rows into the framebuffer.
 *
 *   dst[0..15]          = output row 0  (16 x uint32_t, 8 pixels × 2 wide)
 *   dst[stride..+15]    = output row 1  (identical, for 2x vertical scale)
 *
 *   Caller must ensure dst + stride + 16 stays within the framebuffer.
 */
static inline void simd_render_char_row_x2(uint32_t * restrict dst,
                                            size_t stride,
                                            uint8_t pat,
                                            uint32_t fg, uint32_t bg) {
#if defined(SIMD_SSE2)
    __m128i vfg = _mm_set1_epi32((int)fg);
    __m128i vbg = _mm_set1_epi32((int)bg);

    /* Build per-lane masks: -(bit) gives 0x00000000 or 0xFFFFFFFF */
    __m128i m03 = _mm_set_epi32(-((pat>>3)&1), -((pat>>2)&1),
                                  -((pat>>1)&1), -(pat&1));
    __m128i m47 = _mm_set_epi32(-((pat>>7)&1), -((pat>>6)&1),
                                  -((pat>>5)&1), -((pat>>4)&1));

    /* Select fg where mask=0xFFFFFFFF, bg where mask=0x00000000 */
    __m128i p03 = _mm_or_si128(_mm_and_si128(m03, vfg),
                                _mm_andnot_si128(m03, vbg));
    __m128i p47 = _mm_or_si128(_mm_and_si128(m47, vfg),
                                _mm_andnot_si128(m47, vbg));

    /* 2x horizontal: interleave each pixel with itself */
    __m128i r0 = _mm_unpacklo_epi32(p03, p03); /* [c0,c0,c1,c1] */
    __m128i r1 = _mm_unpackhi_epi32(p03, p03); /* [c2,c2,c3,c3] */
    __m128i r2 = _mm_unpacklo_epi32(p47, p47); /* [c4,c4,c5,c5] */
    __m128i r3 = _mm_unpackhi_epi32(p47, p47); /* [c6,c6,c7,c7] */

    /* row 0 */
    _mm_storeu_si128((__m128i *)(dst      ), r0);
    _mm_storeu_si128((__m128i *)(dst +  4), r1);
    _mm_storeu_si128((__m128i *)(dst +  8), r2);
    _mm_storeu_si128((__m128i *)(dst + 12), r3);
    /* row 1 — 2x vertical */
    _mm_storeu_si128((__m128i *)(dst + stride      ), r0);
    _mm_storeu_si128((__m128i *)(dst + stride +  4), r1);
    _mm_storeu_si128((__m128i *)(dst + stride +  8), r2);
    _mm_storeu_si128((__m128i *)(dst + stride + 12), r3);

#elif defined(SIMD_NEON)
    uint32x4_t vfg = vdupq_n_u32(fg);
    uint32x4_t vbg = vdupq_n_u32(bg);

    const uint32_t a03[4] = { -(uint32_t)( pat     &1), -(uint32_t)((pat>>1)&1),
                               -(uint32_t)((pat>>2)&1), -(uint32_t)((pat>>3)&1) };
    const uint32_t a47[4] = { -(uint32_t)((pat>>4)&1), -(uint32_t)((pat>>5)&1),
                               -(uint32_t)((pat>>6)&1), -(uint32_t)((pat>>7)&1) };

    uint32x4_t p03 = vbslq_u32(vld1q_u32(a03), vfg, vbg);
    uint32x4_t p47 = vbslq_u32(vld1q_u32(a47), vfg, vbg);

    /* 2x horizontal: zip each vector with itself */
    uint32x4x2_t z03 = vzipq_u32(p03, p03); /* val[0]=[c0,c0,c1,c1] val[1]=[c2,c2,c3,c3] */
    uint32x4x2_t z47 = vzipq_u32(p47, p47);

    vst1q_u32(dst,          z03.val[0]);
    vst1q_u32(dst +  4,     z03.val[1]);
    vst1q_u32(dst +  8,     z47.val[0]);
    vst1q_u32(dst + 12,     z47.val[1]);
    /* row 1 */
    vst1q_u32(dst + stride,      z03.val[0]);
    vst1q_u32(dst + stride +  4, z03.val[1]);
    vst1q_u32(dst + stride +  8, z47.val[0]);
    vst1q_u32(dst + stride + 12, z47.val[1]);

#else   /* scalar fallback */
    for (int px = 0; px < 8; px++) {
        uint32_t c = (pat & (1u << px)) ? fg : bg;
        dst[px * 2]               = c;
        dst[px * 2 + 1]           = c;
        dst[stride + px * 2]      = c;
        dst[stride + px * 2 + 1]  = c;
    }
#endif
}

#endif /* SIMD_H */
