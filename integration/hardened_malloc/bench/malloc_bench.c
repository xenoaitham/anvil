/*
 * Anvil allocator-agnostic malloc benchmark.
 *
 * WHY THIS EXISTS: upstream hardened_malloc ships NO benchmark harness.
 * Its third_party/ contains only libdivide.h (a build-time dependency),
 * and `calculate-waste` is a static size-class fragmentation table
 * generator, not a runtime benchmark. Upstream's README explicitly
 * de-prioritizes "allocator micro-benchmarks". So Anvil provides a small,
 * honest workload of its own and drives different allocators against the
 * SAME binary via upstream's own documented usage mode (LD_PRELOAD /
 * preload.sh). The allocation sequence is identical for every allocator:
 * a fixed-seed xorshift64* PRNG decides every size and slot, so the only
 * variable between runs is the allocator itself.
 *
 * Build: gcc -O2 -std=c11 -Wall -Wextra -o malloc_bench malloc_bench.c -lpthread
 * Run:   ./malloc_bench <ops_per_phase>          (phases printed to stdout)
 *        LD_PRELOAD=.../libhardened_malloc.so ./malloc_bench <ops>
 *
 * Output format (one line per phase, fixed fields, machine-parseable):
 *   phase <name> ops <n> seconds <s.sec> ops_per_sec <n>
 *
 * NOTE ON HONESTY: this is a microbenchmark of allocator throughput on one
 * machine. It says nothing about tail latency on contended locks, memory
 * overhead, or the security value of hardened_malloc's mitigations, which
 * are the actual point of the project (see upstream README, "Core design").
 */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_SLOTS 4096

static unsigned long long rng_state = 0x9E3779B97F4A7C15ULL; /* fixed seed */

static unsigned long long rng_split(unsigned long long *state) {
    unsigned long long x = *state;
    x ^= x >> 12; x ^= x << 25; x ^= x >> 27;   /* xorshift64* */
    *state = x;
    return x * 0x2545F4914F6CDD1DULL;
}

static unsigned long long rng(void) { return rng_split(&rng_state); }

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void report(const char *name, long ops, double sec) {
    printf("phase %s ops %ld seconds %.6f ops_per_sec %.1f\n",
           name, ops, sec, (double)ops / sec);
    fflush(stdout);
}

/* touch a byte every ~64B so pages are really faulted in */
static void touch(unsigned char *p, size_t n) {
    for (size_t i = 0; i < n; i += 64) p[i] = (unsigned char)i;
}

static void churn(const char *name, long ops, size_t lo, size_t hi) {
    static unsigned char *slots[MAX_SLOTS];
    for (int i = 0; i < MAX_SLOTS; i++) slots[i] = NULL;
    double t0 = now_sec();
    for (long i = 0; i < ops; i++) {
        unsigned idx = (unsigned)(rng() % MAX_SLOTS);
        free(slots[idx]);
        size_t sz = lo + (size_t)(rng() % (hi - lo + 1));
        slots[idx] = malloc(sz);
        if (!slots[idx]) { fprintf(stderr, "oom %zu\n", sz); exit(1); }
        touch(slots[idx], sz);
    }
    for (int i = 0; i < MAX_SLOTS; i++) free(slots[i]);
    report(name, ops, now_sec() - t0);
}

static void realloc_pattern(long ops) {
    unsigned char *slots[512] = {0};
    double t0 = now_sec();
    for (long i = 0; i < ops; i++) {
        unsigned idx = (unsigned)(rng() % 512);
        size_t nsz = 32 + (size_t)(rng() % 16384);
        unsigned char *p = realloc(slots[idx], nsz);
        if (!p) { fprintf(stderr, "oom\n"); exit(1); }
        p[nsz - 1] = 1;
        slots[idx] = p;
        if ((rng() & 7) == 0) { free(slots[idx]); slots[idx] = NULL; }
    }
    for (int i = 0; i < 512; i++) free(slots[i]);
    report("realloc_pattern", ops, now_sec() - t0);
}

static void calloc_zero(long ops) {
    double t0 = now_sec();
    for (long i = 0; i < ops; i++) {
        size_t sz = 64 + (size_t)(rng() % 8192);
        void *p = calloc(1, sz);
        if (!p) { fprintf(stderr, "oom\n"); exit(1); }
        free(p);
    }
    report("calloc_zero", ops, now_sec() - t0);
}

struct thread_arg { long ops; int id; };

static void *thread_churn_fn(void *ap) {
    /* per-thread fixed-seed PRNG: identical allocation sequence for every
     * allocator and every run, no shared mutable state */
    struct thread_arg *a = ap;
    unsigned long long st = 0xC0FFEE123456789ULL
                          ^ (unsigned long long)(unsigned)a->id * 0x9E3779B9ULL;
    enum { N = 256 };
    unsigned char *slots[N] = {0};
    for (long i = 0; i < a->ops; i++) {
        unsigned idx = (unsigned)(rng_split(&st) % N);
        free(slots[idx]);
        size_t sz = 16 + (size_t)(rng_split(&st) % 4096);
        slots[idx] = malloc(sz);
        if (!slots[idx]) { fprintf(stderr, "oom\n"); exit(1); }
        slots[idx][0] = 1;
    }
    for (int i = 0; i < N; i++) free(slots[i]);
    return NULL;
}

static void thread_churn(long ops_per_thread, int nthreads) {
    pthread_t t[16];
    struct thread_arg args[16];
    double t0 = now_sec();
    for (int i = 0; i < nthreads; i++) {
        args[i].ops = ops_per_thread;
        args[i].id = i;
        if (pthread_create(&t[i], NULL, thread_churn_fn, &args[i]) != 0) {
            fprintf(stderr, "pthread_create failed\n"); exit(1);
        }
    }
    for (int i = 0; i < nthreads; i++) pthread_join(t[i], NULL);
    report("thread_churn", ops_per_thread * nthreads, now_sec() - t0);
}

int main(int argc, char **argv) {
    long ops = 2000000;
    if (argc > 1) {
        char *end = NULL;
        ops = strtol(argv[1], &end, 10);
        if (end == argv[1] || ops <= 0 || errno == ERANGE) {
            fprintf(stderr, "bad ops: %s\n", argv[1]); return 2;
        }
    }

    churn("small_churn",  ops, 16, 2048);          /* slab size classes */
    churn("medium_churn", ops / 4, 4096, 65536);   /* extended classes  */
    churn("large_churn",  ops / 40, 131072, 1048576); /* large allocs   */
    realloc_pattern(ops / 8);
    calloc_zero(ops / 2);
    thread_churn(ops / 4, 4);

    printf("done ops_base %ld\n", ops);
    return 0;
}
