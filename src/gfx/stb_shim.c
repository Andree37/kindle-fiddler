// Thin wrapper so Zig does not depend on translating stb_truetype.h.
#include <stddef.h>
/* stb's memory comes from noface's budgets: see gfx/c_memory.zig. */
void *noface_malloc(size_t size);
void noface_free(void *p);
void *noface_realloc(void *p, size_t size);
#define STBTT_malloc(x, u) ((void)(u), noface_malloc(x))
#define STBTT_free(x, u) ((void)(u), noface_free(x))
#define STBI_MALLOC(size) noface_malloc(size)
#define STBI_REALLOC(p, size) noface_realloc(p, size)
#define STBI_FREE(p) noface_free(p)
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#include "stb_image.h"
#include <stdlib.h>

void *ft_open(const unsigned char *ttf) {
    stbtt_fontinfo *f = noface_malloc(sizeof *f);
    if (!f) return 0;
    if (!stbtt_InitFont(f, ttf, stbtt_GetFontOffsetForIndex(ttf, 0))) {
        noface_free(f);
        return 0;
    }
    return f;
}

void ft_close(void *f) {
    noface_free(f);
}
float ft_scale(void *f, float px) { return stbtt_ScaleForPixelHeight(f, px); }
void ft_vmetrics(void *f, int *asc, int *desc, int *gap) { stbtt_GetFontVMetrics(f, asc, desc, gap); }
int ft_index(void *f, int cp) { return stbtt_FindGlyphIndex(f, cp); }
void ft_hmetrics(void *f, int g, int *adv, int *lsb) { stbtt_GetGlyphHMetrics(f, g, adv, lsb); }
int ft_kern(void *f, int a, int b) { return stbtt_GetGlyphKernAdvance(f, a, b); }
unsigned char *ft_bitmap(void *f, float scale, int g, int *w, int *h, int *xo, int *yo) {
    return stbtt_GetGlyphBitmap(f, scale, scale, g, w, h, xo, yo);
}

unsigned char *img_gray(const unsigned char *data, int len, int *w, int *h) {
    int channels;
    return stbi_load_from_memory(data, len, w, h, &channels, 1);
}
void img_free(unsigned char *p) { stbi_image_free(p); }
