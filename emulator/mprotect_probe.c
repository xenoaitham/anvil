/* Anvil emulator platform probe: reproduce hardened_malloc's init-time
 * mprotect pattern and report the raw errno.
 *
 * Context: hm init maps a fresh anonymous region (PROT_NONE,
 * MAP_NORESERVE) and then mprotect()s a sub-range to RW. On the API 36
 * emulator image this mprotect fails with a non-ENOMEM errno (the fatal
 * message is "non-ENOMEM mprotect failure"), killing the first malloc —
 * which happens to come from bionic's own __libc_preinit via sysconf.
 * This probe isolates the syscall pattern from the allocator.
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static const char *errno_name(int e) {
    switch (e) {
        case EACCES: return "EACCES";
        case EINVAL: return "EINVAL";
        case ENOMEM: return "ENOMEM";
        case EPERM:  return "EPERM";
        case ENOSYS: return "ENOSYS";
        default:     return "other";
    }
}

int main(void) {
    const size_t page = sysconf(_SC_PAGESIZE);
    printf("page_size=%zu\n", page);

    /* 1. plain small mmap PROT_NONE -> mprotect RW */
    void *a = mmap(NULL, 1 << 20, PROT_NONE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    printf("mmap_1M=%s\n", a == MAP_FAILED ? "FAIL" : "ok");
    if (a != MAP_FAILED) {
        int r = mprotect(a, 4096, PROT_READ | PROT_WRITE);
        printf("mprotect_1M_start=%d errno=%s\n", r,
               r ? errno_name(errno) : "-");
    }

    /* 2. hm-shaped: guard pages around the payload, payload starts at
     *    guard_size offset, mprotect unprotects from the payload start */
    const size_t guard = 64 * (size_t)page;
    const size_t total = guard * 2 + page;
    void *b = mmap(NULL, total, PROT_NONE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    printf("mmap_guarded=%s ptr=%p\n", b == MAP_FAILED ? "FAIL" : "ok", b);
    if (b != MAP_FAILED) {
        int r = mprotect((char *)b + guard, page, PROT_READ | PROT_WRITE);
        printf("mprotect_offset_guard=%d errno=%s\n", r,
               r ? errno_name(errno) : "-");
    }

    /* 3. no-NORESERVE variant */
    void *c = mmap(NULL, 1 << 20, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (c != MAP_FAILED) {
        int r = mprotect(c, 4096, PROT_READ | PROT_WRITE);
        printf("mprotect_1M_noreserve_off=%d errno=%s\n", r,
               r ? errno_name(errno) : "-");
    }

    /* 4. huge NORESERVE region like hm's class regions (32 GiB) */
    const size_t big = (size_t)32 << 30;
    void *d = mmap(NULL, big, PROT_NONE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    printf("mmap_32G=%s\n", d == MAP_FAILED ? "FAIL" : "ok");
    if (d != MAP_FAILED) {
        int r = mprotect(d, 4096, PROT_READ | PROT_WRITE);
        printf("mprotect_32G_start=%d errno=%s\n", r,
               r ? errno_name(errno) : "-");
    }

    printf("PROBE_DONE\n");
    return 0;
}
