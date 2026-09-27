# hardened_malloc — results summary (honest rollup)

Every number below traces to a committed JSON or log in this directory.
Nothing here was borrowed from upstream CI, extrapolated, or invented.
Anything this machine could not run is listed under "Not run" with the
reason.

## Machine and provenance

- Host: Intel Core i5-10400F @ 2.90 GHz (12 threads), 15 GiB RAM,
  Pop!_OS 24.04 LTS, kernel 7.1.5-76070105-generic, glibc 2.39.
  `vm.max_map_count` = 1048576 (already raised; guard-slab mappings fit).
- Upstream: GrapheneOS/hardened_malloc pinned at
  `01df350c62441e163a8b9324fb7e156acdad2c1e` (2026-09-25, HEAD of the local
  shallow reference clone; every script re-verifies this SHA before use).
- Toolchains actually used: clang 18.1.3 (Ubuntu) and gcc 14.2.0
  (Ubuntu 24.04). The default `gcc` on this host is 13.3.0, which **cannot**
  build upstream (rejects `-std=c23`; upstream's floor is GCC 14.2.0) — the
  scripts probe for a c23-capable gcc and pick `gcc-14`.
- Honesty note on versions: glibc 2.39, clang 18 and kernel 7.1 are all
  older/different from upstream's supported floors (glibc 2.41, clang
  19.1.7+, Linux 6.12). Everything below therefore demonstrates "builds and
  passes on this host", not "supported configuration" — those are upstream's
  words, and upstream does not support this exact stack.

## Builds (build.sh → build/hmalloc/, gitignored artifacts)

| Variant | Result | Compiler |
|---|---|---|
| clang-default | built, clean (`-Werror`, LTO) | Ubuntu clang 18.1.3 |
| clang-light | built, clean | Ubuntu clang 18.1.3 |
| gcc-14-default | built, clean | gcc 14.2.0 |
| gcc-14-light | built, clean | gcc 14.2.0 |

All four use upstream's own `config/{default,light}.mk` unmodified,
`make -j8`, native x86_64, glibc. `gcc` 13.3.0: build failure recorded
here honestly (not worked around by patching upstream): `gcc: error:
unrecognized command-line option '-std=c23'`.

## Tests (run_tests.sh → tests-20260927-x86_64-{clang,gcc-14}.json)

Upstream's suite, driven exactly as upstream's `make test` drives it:
`make -C test/` builds 62 binaries linked against the freshly built
`out/libhardened_malloc.so`, then `python3 -m unittest discover` runs
`test/test_smc.py` (58 checks of exit codes and fatal-error messages).
Default config only — upstream's `test/Makefile` rejects non-default
variants ("testing non-default variants not yet supported").

| Suite | Runs (timed) | Passed | Failed | Wall per run |
|---|---|---|---|---|
| clang 18.1.3 / default | 3 | 58 × 3 = 174/174 | 0 | 37.9–40.2 s |
| gcc 14.2.0 / default | 3 | 58 × 3 = 174/174 | 0 | 38.1–40.3 s |

Per-test statuses (58 entries per run, e.g. `test_double_free_small ... ok`)
are in the JSONs; full transcripts in `logs/tests-20260927-x86_64-*.log`
(including upstream's own benign build warnings: `-Walloc-size-larger-than=`
pragmas unknown to clang, and the intentional non-power-of-2 alignment in
`aligned_alloc_einval.c`). No flakiness observed across 6 consecutive suite
runs. **Committed failures: none** — the honest negative result is that
none occurred, not that none was hidden.

## Benchmark (bench/run_bench.sh → bench-20260927-x86_64.json)

Workload: Anvil's `bench/malloc_bench.c` — allocator-agnostic, fixed-seed
xorshift64\* sequences (identical allocation stream for every allocator),
binary built once with `gcc -O2 -std=c11`. Allocators selected via
upstream's documented `LD_PRELOAD` mechanism; glibc baseline = same binary
unpreloaded. 1 untimed warmup + 5 timed repeats per allocator. Upstream
ships no benchmark harness of its own (third_party/ = `libdivide.h` only;
`calculate-waste` is a static table) — see README §4 for why this harness
is the faithful option.

Throughput, ops/s, mean ± stdev over 5 runs:

| Phase | glibc | hmalloc-default | hmalloc-light |
|---|---|---|---|
| small_churn (16 B–2 KiB) | 10,151,693 ± 151,688 | 4,066,992 ± 327,786 | 10,025,421 ± 312,379 |
| medium_churn (4–64 KiB) | 204,657 ± 16,731 | 113,477 ± 12,288 | 133,922 ± 4,532 |
| large_churn (128 KiB–1 MiB) | 11,346 ± 569 | 4,990 ± 239 | 5,268 ± 215 |
| realloc_pattern | 5,050,227 ± 113,311 | 1,170,866 ± 166,509 | 2,448,698 ± 190,405 |
| calloc_zero | 6,550,340 ± 111,685 | 3,898,340 ± 284,177 | 11,265,231 ± 573,052 |
| thread_churn (4 threads) | 44,476,357 ± 7,363,222 | 4,216,055 ± 688,485 | 37,173,156 ± 2,012,109 |

Ratio vs glibc (harness-computed): default 0.095×–0.60× across phases;
light 0.46×–1.72× (light `calloc_zero` beats glibc because freshly mapped
upstream pages are already zero, while glibc must memset).

Observed variance: coefficient of variation 1.5–11% on all single-thread
phases, 16–17% on `thread_churn` (scheduler noise on a desktop with no
thermal/frequency isolation). Treat any re-run differences inside those
bands as the same result. Reproduce with
`integration/hardened_malloc/bench/run_bench.sh`.

## Cross-arch (cross-check.sh → cross-check-20260927-x86_64.json)

Locally verified:

- clang's aarch64 backend emits genuine `EM_AARCH64` relocatable objects on
  this host (freestanding probe verified with readelf).

Exact first blockers under `clang --target=aarch64-linux-gnu -c` with
upstream default-config defines (no sysroot/NDK on this machine):

- `chacha.c`: `'bits/libc-header-start.h' file not found` (host glibc
  headers, x86_64 multiarch path not on the aarch64 include path)
- `memory.c`, `pages.c`, `random.c`, `util.c`, `h_malloc.c`:
  `'bits/wordsize.h' file not found`
- `new.cc`: `'new' file not found` (no aarch64 C++ standard library)
- Stage-2 probe: adding `-I /usr/include/x86_64-linux-gnu` moves the failure
  to `'gnu/stubs-32.h' file not found` (`__x86_64__` undefined for the
  target) — i.e. there is no shortcut; a real aarch64 sysroot is required.
- Absent on this host: `aarch64-linux-gnu-gcc`, Android NDK, qemu-user.

## Not run on this machine (and why)

- **aarch64 full build + test execution** — no aarch64 sysroot/toolchain and
  no qemu-user here. CI-planned: `gcc-aarch64-linux-gnu` +
  `make CONFIG_NATIVE=false`, a native `ubuntu-24.04-arm` runner for
  execution, optional `qemu-user-static` (mirrors upstream's own CI).
- **Android bionic variant** — requires an AOSP/NDK bionic sysroot; the
  `Android.bp`-based build was not exercised here and no claim is made
  about it.
- **musl build** — upstream CI covers Alpine; no musl toolchain on this
  host.
- **WSAN/MTE arm paths** (`arm_mte.h`, memtag) — arm64-only runtime paths;
  not reachable on x86_64, and not faked.
- **Whole-OS integration** (GrapheneOS `platform_bionic` integration commit
  inside an AOSP tree) — out of scope for this host; documented as
  guidance in `integration/hardened_malloc/README.md` §1, not as done.

## Traceability

| Claim above | Evidence file |
|---|---|
| 4/4 builds clean, gcc-13 failure | `logs/tests-*.log` (build sections), `build/hmalloc/*/build.log` (artifact-side), gcc-13 error quoted in this file |
| 58/58 × 3 runs × 2 compilers | `tests-20260927-x86_64-clang.json`, `tests-20260927-x86_64-gcc-14.json`, `logs/tests-20260927-x86_64-*.run{1,2,3}.log` |
| Bench means/stdev/ratios | `bench-20260927-x86_64.json`, raw transcripts `logs/bench-20260927-x86_64-*.run{1..5}.txt` |
| aarch64 blockers | `cross-check-20260927-x86_64.json` |
