/* Anvil diagnostic: does alignas(PAGE_SIZE) actually apply under the NDK
 * with C23, the way hardened_malloc's struct allocator_state relies on?
 * Compile-time only: static_asserts fire at build. */
#include <stddef.h>
#include <stdint.h>

#define PAGE_SHIFT 12
#ifndef PAGE_SIZE
#define PAGE_SIZE ((size_t)1 << PAGE_SHIFT)
#endif

#ifdef PAGE_SIZE_IS_DEFINED_BEFORE
#error "PAGE_SIZE was already defined by bionic headers"
#endif

struct inner {
    char a[328];
};

struct probe_state {
    alignas(PAGE_SIZE) struct inner big;
    struct inner tail;
    alignas(PAGE_SIZE) struct inner padded;
    char c;
};

_Static_assert(offsetof(struct probe_state, padded) % 4096 == 0,
               "alignas(PAGE_SIZE) NOT honored");
_Static_assert(PAGE_SIZE == 4096, "PAGE_SIZE unexpected");

int main(void) { return 0; }
