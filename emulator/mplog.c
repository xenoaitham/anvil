/* Anvil diagnostic: log failing mprotect calls made under preload.
 * Interposes mprotect and logs address/length/prot/errno for every failure
 * so the allocator's init-time protection failure can be pinned to a
 * concrete syscall triple. Writes go straight to fd 2 — no allocation, no
 * dlsym (bionic's dlsym can malloc, which recurses into the interposed
 * allocator mid-init); the real call goes through the raw syscall.
 * Diagnostic instrument only; not part of the integration surface.
 */
#include <errno.h>
#include <stdio.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

int mprotect(void *addr, size_t len, int prot) {
    long r = syscall(SYS_mprotect, addr, len, prot);
    if (r != 0) {
        char buf[160];
        int n = snprintf(buf, sizeof(buf),
                         "MPLOG FAIL addr=%p len=%zu prot=%d errno=%d\n",
                         addr, len, prot, errno);
        ssize_t w = write(2, buf, (size_t)n);
        (void)w;
    }
    return (int)r;
}
