/* fbtext: print text lines on ABL's splash framebuffer through /dev/mem.
 * Stage 1 of the dodge chain runs on stock's DTB without any display
 * driver, but MDSS keeps scanning the splash buffer ABL drew the unlocked
 * warning into (0xfc800000, 1440x3168, stride 5760, a8r8g8b8: the same
 * numbers stage 2's simple-framebuffer node uses).
 *   fbtext [-c] [line ...]    -c clears to black first; lines wrap; the
 *                             next row is kept in /omamobile/fb.row
 * Font: /omamobile/font.psf (PSF1 or PSF2, glyph index = ASCII). */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define FB_PHYS 0xfc800000UL
#define W 1440
#define H 3168
#define STRIDE 5760
#define FB_SIZE ((size_t)STRIDE * H)
#define STATE "/omamobile/fb.row"
#define FONT "/omamobile/font.psf"

static uint8_t *font;
static int gw, gh, gbytes, nglyph;

static int load_font(void) {
    FILE *f = fopen(FONT, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc(n);
    if (!b || fread(b, 1, n, f) != (size_t)n) return -1;
    fclose(f);
    if (b[0] == 0x36 && b[1] == 0x04) {               /* PSF1 */
        gw = 8; gh = b[3]; gbytes = gh; nglyph = (b[2] & 1) ? 512 : 256; font = b + 4;
    } else if (b[0] == 0x72 && b[1] == 0xb5 && b[2] == 0x4a && b[3] == 0x86) { /* PSF2 */
        uint32_t h[8]; memcpy(h, b, 32);
        nglyph = h[4]; gbytes = h[5]; gh = h[6]; gw = h[7]; font = b + h[2];
    } else return -1;
    return 0;
}

static void glyph(uint32_t *fb, int col, int row, int c, int scale) {
    if (c < 32 || c >= nglyph) c = '?';
    const uint8_t *g = font + c * gbytes;
    int bpr = (gw + 7) / 8, x0 = col * gw * scale, y0 = row * gh * scale;
    for (int y = 0; y < gh; y++)
        for (int x = 0; x < gw; x++) {
            uint32_t px = ((g[y * bpr + x / 8] >> (7 - (x % 8))) & 1) ? 0xffffffffu : 0xff000000u;
            for (int sy = 0; sy < scale; sy++)
                for (int sx = 0; sx < scale; sx++) {
                    int X = x0 + x * scale + sx, Y = y0 + y * scale + sy;
                    if (X < W && Y < H) fb[Y * (STRIDE / 4) + X] = px;
                }
        }
}

static void clear(uint32_t *fb) {
    for (size_t i = 0; i < FB_SIZE / 4; i++) fb[i] = 0xff000000u;
}

int main(int argc, char **argv) {
    int clr = 0, a = 1;
    if (argc > 1 && !strcmp(argv[1], "-c")) { clr = 1; a = 2; }
    if (load_font()) { fprintf(stderr, "fbtext: no font\n"); return 1; }
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("fbtext: /dev/mem"); return 1; }
    uint32_t *fb = mmap(NULL, FB_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, FB_PHYS);
    if (fb == MAP_FAILED) { perror("fbtext: mmap"); return 1; }
    int scale = gw >= 16 ? 2 : 3, cols = W / (gw * scale), rows = H / (gh * scale), row = 0;
    FILE *s = fopen(STATE, "r");
    if (s) { if (fscanf(s, "%d", &row) != 1) row = 0; fclose(s); }
    if (clr) { clear(fb); row = 0; }
    for (; a < argc; a++) {
        const char *t = argv[a]; size_t len = strlen(t);
        do {
            if (row >= rows) { clear(fb); row = 0; }
            size_t n = len > (size_t)cols ? (size_t)cols : len;
            for (size_t i = 0; i < n; i++) glyph(fb, i, row, (unsigned char)t[i], scale);
            row++; t += n; len -= n;
        } while (len > 0);
    }
    s = fopen(STATE, "w");
    if (s) { fprintf(s, "%d\n", row); fclose(s); }
    return 0;
}
