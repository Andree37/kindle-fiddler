/* Decodes one JPEG XR picture from stdin to an 8-bit grayscale PGM on stdout.
 * With a width and height given, it scales the result to exactly that size.
 *
 * Kindle books store most pictures as JPEG XR. The Kindle's own decoder,
 * /usr/lib/libjpegXR.so (the ITU-T T.835 reference code), is loaded at run time,
 * so nothing of it is copied here. noface runs this for pages with pictures.
 * The calls follow Ghostscript's XPS reader, which uses the same library. */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void *image_t;
typedef void *container_t;
typedef void (*block_fn)(image_t image, int mx, int my, int *data);

static int width, height, channels;
static unsigned char *gray;
static int (*image_channels)(image_t);

/* Each call hands over one 16x16 macroblock, pixel by pixel, channel by channel. */
static void block(image_t image, int mx, int my, int *data) {
    if (channels == 0) channels = image_channels(image);
    for (int y = 0; y < 16; y++) {
        for (int x = 0; x < 16; x++) {
            int px = mx * 16 + x, py = my * 16 + y;
            if (px >= width || py >= height) continue;
            const int *v = data + (y * 16 + x) * channels;
            int g = channels >= 3 ? (v[0] * 299 + v[1] * 587 + v[2] * 114) / 1000 : v[0];
            gray[py * width + px] = g < 0 ? 0 : g > 255 ? 255 : g;
        }
    }
}

#define LOAD(name, ret, args) \
    ret(*name) args = (ret(*) args)dlsym(lib, #name); \
    if (!name) return fail("missing " #name)

static int fail(const char *why) {
    fprintf(stderr, "jxr2pgm: %s\n", why);
    return 1;
}

int main(int argc, char **argv) {
    size_t cap = 1 << 20, len = 0;
    unsigned char *in = malloc(cap);
    for (size_t n; in && (n = fread(in + len, 1, cap - len, stdin)) > 0;) {
        len += n;
        if (len == cap) in = realloc(in, cap *= 2);
    }
    if (!in || len == 0) return fail("no input");
    FILE *f = fmemopen(in, len, "rb");
    if (!f) return fail("fmemopen");

    void *lib = dlopen("libjpegXR.so", RTLD_NOW);
    if (!lib) return fail(dlerror());
    LOAD(jxr_create_container, container_t, (void));
    LOAD(jxr_read_image_container, int, (container_t, FILE *));
    LOAD(jxrc_image_offset, unsigned long, (container_t, int));
    LOAD(jxrc_image_width, unsigned long, (container_t, int));
    LOAD(jxrc_image_height, unsigned long, (container_t, int));
    LOAD(jxrc_image_pixelformat, int, (container_t, int));
    LOAD(jxrc_alpha_offset, unsigned long, (container_t, int));
    LOAD(jxrc_image_band_presence, unsigned char, (container_t, int));
    LOAD(jxrc_alpha_band_presence, unsigned char, (container_t, int));
    LOAD(jxr_create_input, image_t, (void));
    LOAD(jxr_set_block_output, void, (image_t, block_fn));
    LOAD(jxr_set_container_parameters, void, (image_t, int, unsigned, unsigned, unsigned, unsigned char, unsigned char, unsigned char));
    LOAD(jxr_set_PROFILE_IDC, void, (image_t, int));
    LOAD(jxr_set_LEVEL_IDC, void, (image_t, int));
    LOAD(jxr_set_pixel_format, void, (image_t, int));
    LOAD(jxr_read_image_bitstream, int, (image_t, FILE *));
    LOAD(jxr_get_IMAGE_CHANNELS, int, (image_t));
    image_channels = jxr_get_IMAGE_CHANNELS;

    container_t c = jxr_create_container();
    if (jxr_read_image_container(c, f) < 0) return fail("not a JPEG XR file");
    width = (int)jxrc_image_width(c, 0);
    height = (int)jxrc_image_height(c, 0);
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192) return fail("bad size");
    gray = malloc((size_t)width * height);
    if (!gray) return fail("out of memory");
    memset(gray, 255, (size_t)width * height);

    fseek(f, (long)jxrc_image_offset(c, 0), SEEK_SET);
    image_t image = jxr_create_input();
    int format = jxrc_image_pixelformat(c, 0);
    jxr_set_PROFILE_IDC(image, 111);
    jxr_set_LEVEL_IDC(image, 255);
    jxr_set_pixel_format(image, format);
    jxr_set_container_parameters(image, format, width, height, (unsigned)jxrc_alpha_offset(c, 0),
                                 jxrc_image_band_presence(c, 0), jxrc_alpha_band_presence(c, 0), 0);
    jxr_set_block_output(image, block);
    if (jxr_read_image_bitstream(image, f) < 0) return fail("decode failed");

    int out_w = argc == 3 ? atoi(argv[1]) : width;
    int out_h = argc == 3 ? atoi(argv[2]) : height;
    if (out_w <= 0 || out_h <= 0 || out_w > 8192 || out_h > 8192) return fail("bad output size");
    unsigned char *out = gray;
    if (out_w != width || out_h != height) {
        /* Box filter: each output pixel averages the source pixels it covers. */
        out = malloc((size_t)out_w * out_h);
        if (!out) return fail("out of memory");
        for (int y = 0; y < out_h; y++) {
            int y0 = (int)((long)y * height / out_h), y1 = (int)((long)(y + 1) * height / out_h);
            if (y1 <= y0) y1 = y0 + 1;
            for (int x = 0; x < out_w; x++) {
                int x0 = (int)((long)x * width / out_w), x1 = (int)((long)(x + 1) * width / out_w);
                if (x1 <= x0) x1 = x0 + 1;
                long sum = 0;
                for (int sy = y0; sy < y1; sy++)
                    for (int sx = x0; sx < x1; sx++) sum += gray[sy * width + sx];
                out[y * out_w + x] = (unsigned char)(sum / ((y1 - y0) * (x1 - x0)));
            }
        }
    }
    printf("P5\n%d %d\n255\n", out_w, out_h);
    fwrite(out, 1, (size_t)out_w * out_h, stdout);
    return 0;
}
