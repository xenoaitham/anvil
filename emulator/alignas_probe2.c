/* Anvil diagnostic: which alignment-specifier form actually applies under
 * this toolchain? Each variant guarded by its own static_assert so the
 * compiler error names the failing form. */
#include <stddef.h>

struct a_lit {
    char a[328];
    alignas(4096) char b[1];
};
_Static_assert(offsetof(struct a_lit, b) % 4096 == 0, "alignas-literal broken");

struct b_kw {
    char a[328];
    _Alignas(4096) char b[1];
};
_Static_assert(offsetof(struct b_kw, b) % 4096 == 0, "_Alignas broken");

int main(void) { return 0; }
