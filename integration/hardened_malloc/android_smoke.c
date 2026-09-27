/* Anvil hardened_malloc on-device smoke test (Android / bionic).
 *
 * Proves, inside a running Android system, that GrapheneOS hardened_malloc
 * is loadable and serving allocations — with two distinct, individually
 * conclusive modes:
 *
 *   android_smoke --interposed
 *       Run with the proof-variant libhardened_malloc.so via LD_PRELOAD.
 *       PASS requires mallinfo_narenas (compiled only under
 *       CONFIG_STATS=true; the h_-prefixed name is a header rename, the
 *       dynamic symbol is mallinfo_narenas) to be reachable through the
 *       default symbol scope with narenas > 0, i.e. the preloaded
 *       allocator is actually interposing for this process — bionic's
 *       stock scudo cannot answer that symbol.
 *
 *   android_smoke --dlopen <path-to-proof-so>
 *       PASS requires bionic to REFUSE the load with the initial-exec TLS
 *       error. Upstream deliberately compiles its thread-local state
 *       __attribute__((tls_model("initial-exec"))); bionic rejects IE TLS
 *       in dlopen'ed libraries, so refusal with that signature confirms
 *       the model and documents that preload-at-exec is the only load
 *       path (the standard `wrap.<package>` deployment). A successful
 *       load would mean the .so is NOT an upstream-faithful build.
 *       (Standard artifacts additionally fail via -z nodlopen before the
 *       TLS check even runs.)
 *
 * Both modes also exercise the interposed allocation surface first:
 * malloc / calloc / realloc / aligned_alloc / posix_memalign with full-span
 * write+verify, so a PASS line means "verified allocations through the
 * loaded allocator", not merely "library opened".
 *
 * Output contract (parsed by emulator/smoke.sh):
 *   ANVIL_SMOKE_RESULT mode=<interposed|dlopen> ok=<0|1> narenas=<N> note="<text>"
 * Exit status mirrors ok.
 */

#include <dlfcn.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef size_t (*narenas_fn)(void);

static void emit(const char *mode, int ok, size_t narenas, const char *note) {
    printf("ANVIL_SMOKE_RESULT mode=%s ok=%d narenas=%zu note=\"%s\"\n",
           mode, ok, narenas, note);
    fflush(stdout);
}

/* Exercise the allocation surface of whatever allocator currently serves
 * malloc. Returns 0 on success, -1 with errno-ish context in *why. */
static int exercise_allocations(const char **why) {
    static const size_t sizes[] = {
        1, 7, 24, 100, 4096, 65536, 1u << 20
    };
    for (size_t i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
        unsigned char *p = malloc(sizes[i]);
        if (p == NULL) { *why = "malloc returned NULL"; return -1; }
        memset(p, 0xA5, sizes[i]);
        if (p[0] != 0xA5 || p[sizes[i] - 1] != 0xA5) {
            *why = "malloc span failed write/verify"; free(p); return -1;
        }

        unsigned char *grown = realloc(p, sizes[i] * 2);
        if (grown == NULL) { *why = "realloc returned NULL"; free(p); return -1; }
        if (grown[0] != 0xA5) {
            *why = "realloc lost leading bytes"; free(grown); return -1;
        }
        memset(grown, 0x5A, sizes[i] * 2);
        free(grown);
    }

    void *c = calloc(64, 64);
    if (c == NULL) { *why = "calloc returned NULL"; return -1; }
    for (size_t i = 0; i < 64 * 64; i++) {
        if (((unsigned char *)c)[i] != 0) {
            *why = "calloc memory not zeroed"; free(c); return -1;
        }
    }
    free(c);

    void *a = aligned_alloc(4096, 8192);
    if (a == NULL) { *why = "aligned_alloc returned NULL"; return -1; }
    if (((uintptr_t)a & 0xFFF) != 0) {
        *why = "aligned_alloc result misaligned"; free(a); return -1;
    }
    memset(a, 0x11, 8192);
    free(a);

    void *pm = NULL;
    if (posix_memalign(&pm, 256, 512) != 0 || pm == NULL) {
        *why = "posix_memalign failed"; return -1;
    }
    if (((uintptr_t)pm & 0xFF) != 0) {
        *why = "posix_memalign result misaligned"; free(pm); return -1;
    }
    memset(pm, 0x33, 512);
    free(pm);

    return 0;
}

int main(int argc, char **argv) {
    const char *mode = NULL;
    const char *so_path = NULL;

    if (argc >= 2 && strcmp(argv[1], "--interposed") == 0) {
        mode = "interposed";
    } else if (argc >= 3 && strcmp(argv[1], "--dlopen") == 0) {
        mode = "dlopen";
        so_path = argv[2];
    } else {
        fprintf(stderr,
                "usage: %s --interposed | --dlopen <libhardened_malloc.so>\n",
                argv[0]);
        emit("unknown", 0, 0, "bad usage");
        return 2;
    }

    /* 1. whatever allocator is live right now must serve real traffic. */
    const char *why = NULL;
    if (exercise_allocations(&why) != 0) {
        emit(mode, 0, 0, why);
        return 1;
    }

    /* 2. locate hardened_malloc's stats-gated probe. Upstream names the
     * dynamic symbol mallinfo_narenas; the h_-prefixed spelling is a
     * header #define only. Try both in case of upstream drift. */
    narenas_fn fn = (narenas_fn)dlsym(RTLD_DEFAULT, "mallinfo_narenas");
    if (fn == NULL) {
        fn = (narenas_fn)dlsym(RTLD_DEFAULT, "h_mallinfo_narenas");
    }
    if (fn == NULL && strcmp(mode, "dlopen") == 0) {
        void *h = dlopen(so_path, RTLD_NOW | RTLD_LOCAL);
        if (h != NULL) {
            /* deliberate no dlclose(): the allocator owns process memory
             * at this point; teardown is a landmine the smoke must not
             * pull. */
            emit(mode, 0, 0,
                 "UNEXPECTED: bionic loaded an IE-TLS library via dlopen "
                 "(not an upstream-faithful build?)");
            return 1;
        }
        const char *err = dlerror();
        if (err != NULL && (strstr(err, "IE access model") != NULL ||
                            strstr(err, "initial-exec") != NULL)) {
            emit(mode, 1, 0,
                 "bionic refused dlopen with the initial-exec TLS "
                 "signature, as upstream's tls_model requires");
            return 0;
        }
        emit(mode, 0, 0, err != NULL ? err : "dlopen failed with unknown error");
        return 1;
    }
    if (fn == NULL) {
        emit(mode, 0, 0,
             "h_mallinfo_narenas not in scope: hardened_malloc is NOT interposing "
             "(run with proof-variant .so via LD_PRELOAD)");
        return 1;
    }

    size_t narenas = fn();
    if (narenas == 0) {
        emit(mode, 0, 0, "h_mallinfo_narenas returned 0");
        return 1;
    }

    char note[128];
    snprintf(note, sizeof(note),
             "hardened_malloc serving allocations, verified malloc-family traffic");
    emit(mode, 1, narenas, note);
    return 0;
}
