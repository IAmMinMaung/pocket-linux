/* memcp: copy bytes between a file and physical memory through an mmap of /dev/mem.
 * read()/write() on /dev/mem fail on arm64 for no-map memory (valid_phys_addr_range), mmap works.
 *   memcp write <physaddr> <file>      file -> RAM (at most 1 MiB)
 *   memcp read  <physaddr> <nbytes>    RAM -> stdout
 * Static, no libc beyond the basics; used by the stage-1 chainloader. */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#define MAXLEN (1u << 20)
int main(int argc, char **argv) {
    if (argc != 4) { fprintf(stderr, "usage: memcp write <physaddr> <file> | memcp read <physaddr> <nbytes>\n"); return 2; }
    unsigned long long pa = strtoull(argv[2], NULL, 0);
    int wr = strcmp(argv[1], "write") == 0;
    int fd = open("/dev/mem", wr ? O_RDWR | O_SYNC : O_RDONLY | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 1; }
    unsigned char *buf = malloc(MAXLEN); size_t n = 0;
    if (wr) {
        FILE *f = fopen(argv[3], "rb"); if (!f) { perror(argv[3]); return 1; }
        n = fread(buf, 1, MAXLEN, f); fclose(f);
    } else {
        n = strtoul(argv[3], NULL, 0); if (n > MAXLEN) n = MAXLEN;
    }
    size_t off = pa & 0xfff; size_t maplen = (off + n + 0xfff) & ~0xfffUL;
    unsigned char *m = mmap(NULL, maplen, wr ? PROT_READ | PROT_WRITE : PROT_READ, MAP_SHARED, fd, pa & ~0xfffULL);
    if (m == MAP_FAILED) { perror("mmap"); return 1; }
    if (wr) { memcpy(m + off, buf, n); msync(m, maplen, MS_SYNC); fprintf(stderr, "wrote %zu bytes at 0x%llx\n", n, pa); }
    else { fwrite(m + off, 1, n, stdout); }
    munmap(m, maplen); close(fd); return 0;
}
