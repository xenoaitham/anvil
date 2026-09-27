# Anvil hardened_malloc integration

Bringing [GrapheneOS's hardened_malloc](https://github.com/GrapheneOS/hardened_malloc)
to non-Pixel Android devices — **without forking it**.

> **What Anvil does and does not do.** Anvil does **not** fork, vendor, or
> modify hardened_malloc. Every build here clones upstream at a pinned commit
> and invokes upstream's own Makefile, config files, test suite and preload
> mechanism unmodified. What Anvil adds is the *integration glue around the
> upstream project*: pinned-commit builds, machine-readable test/bench
> results, an allocator-agnostic benchmark harness, and cross-arch checks —
> so that results are reproducible and honestly tracked. When upstream's
> README answers a question, we link it instead of restating it.

---

## 1. Integrating into an AOSP / LineageOS-based ROM

The model to follow is upstream's own documentation:
[README.md § "OS integration — Android-based operating systems"](https://github.com/GrapheneOS/hardened_malloc/blob/main/README.md#android-based-operating-systems).
GrapheneOS integrates hardened_malloc into the Bionic C library itself; other
Android-based operating systems can reuse
[that integration code](https://github.com/GrapheneOS/platform_bionic/commit/20160b81611d6f2acd9ab59241bebeac7cf1d71c)
(the linked commit in GrapheneOS's `platform_bionic` tree).

Practical shape for a LineageOS-based tree, keeping upstream authoritative:

1. **Vendor the source as a pinned snapshot, not a submodule of convenience.**
   Add upstream as a git dependency pinned to the exact commit our scripts
   pin (currently `01df350c62441e163a8b9324fb7e156acdad2c1e`, 2026-09-25).
   Re-pin deliberately, never by tracking a branch. `build.sh` in this
   directory shows the pin-and-verify flow (`clone → rev-parse → compare →
   build`), which is the same discipline an AOSP `*.bp`/`soong` vendor dir
   should follow.
2. **Build with upstream's own build definition.** Upstream ships
   `Android.bp` (used by its `androidtest` harness) with the same
   configuration knobs as the Makefile. Prefer adapting *their* module
   definitions into your tree over inventing new flags. Anvil has **not**
   validated an AOSP/Soong build on this machine (no Android tree or NDK
   here — see `SUMMARY.md`), so we state that plainly rather than pretend.
3. **Raise `vm.max_map_count`.** Quoting upstream (same README section):
   guard slabs create a very large number of mappings; raise the limit in
   `init.rc` (`system/core/rootdir/init.rc`) near the other virtual memory
   configuration:

       write /proc/sys/vm/max_map_count 1048576

   This is unnecessary if you build with a very large
   `CONFIG_GUARD_SLABS_INTERVAL` (their words, our emphasis: don't — the
   feature is cheap and valuable).
4. **Kernel requirements on arm64** (upstream README, same section): 4 KiB
   pages only (no 16k/64k page support yet), and 4-level page tables / full
   48-bit address space for the default 32 GiB class region — or shrink
   `CONFIG_CLASS_REGION_SIZE` for 39-bit-address-space devices.
5. **Version floors.** Upstream supports only the current AOSP maintenance
   branch (stated as `android17-release` at the time of our pin) and Linux
   GKI 6.1/6.6/6.12. Older targets are untested and unsupported *by
   upstream*; a ROM ignoring that does so at its own risk.

What Anvil contributes on top (and what this directory actually contains):

- `build.sh` — pinned-commit clone + reproducible native builds of upstream's
  `{default, light}` configs under both clang and gcc, with per-artifact
  provenance (`meta.json`: SHA, compiler, versions).
- `run_tests.sh` — real upstream test-suite runs with machine-readable
  per-test results (the JSONs under `results/hmalloc/`).
- `bench/` — allocator-agnostic benchmark workload + driver (see §4).
- `cross-check.sh` — locally verifiable aarch64 checks with an exact blocker
  report, and the CI plan for full cross builds (see §5).

## 2. Standalone build on Linux (glibc / musl)

Requirements (upstream "Dependencies" section: glibc 2.41, Linux 6.12,
Clang 19.1.7+ or GCC 14.2.0+ are upstream's supported floors). Observed on
this machine: clang 18.1.3 and gcc 14.2.0 both build the pinned tree cleanly
with `-Werror` on, and pass the full test suite — but treat clang < 19 /
glibc < 2.41 as *working yet unsupported* by upstream, exactly as we state
it here.

```sh
# what build.sh does under the hood:
git clone https://github.com/GrapheneOS/hardened_malloc
cd hardened_malloc
make -j8                          # default config -> out/libhardened_malloc.so
make VARIANT=light -j8            # light config  -> out-light/libhardened_malloc-light.so
make CC=gcc-14 CXX=g++-14 -j8     # explicit compiler
```

On musl (Alpine), the same `make` works; upstream's CI builds and tests on
`alpine:latest`. Anvil has not run musl here — `SUMMARY.md` records that as
not-run, not as a claim.

Via this directory:

```sh
integration/hardened_malloc/build.sh                       # all variants
integration/hardened_malloc/build.sh --variant gcc --config default
integration/hardened_malloc/build.sh --variant clang --config light --force
```

Artifacts land in `build/hmalloc/<compiler>-<config>/` (gitignored), each
with a `build.log` and `meta.json` provenance record. The script is
idempotent (stamp-based: same pin + same compiler ⇒ skipped) and exits
nonzero on any failure. Note for this machine family: a plain `gcc` older
than 14 rejects `-std=c23` (`unrecognized command-line option`); the script
probes for the newest c23-capable gcc and prefers it.

## 3. Running the tests

Upstream's own entry point is `make test`, which builds the library, then
`make -C test/` (62 per-API test binaries, linked against the just-built
`out/libhardened_malloc.so`), then drives them with
`python3 -m unittest discover --start-directory test/` (`test/test_smc.py`:
58 checks asserting exit codes and fatal-error messages).

Two facts worth knowing before you improvise:

- The test suite only supports the **default** config — upstream's
  `test/Makefile` errors out with *"testing non-default variants not yet
  supported"* if you set `VARIANT`. Anvil runs tests against `default` only
  and does not "fix" that.
- The suite relies on hardening features being on (quarantines, canaries,
  zero-on-free, guard slabs), which is why the light config is not testable
  this way.

With the Anvil wrapper (builds, runs, parses, records):

```sh
integration/hardened_malloc/run_tests.sh                    # clang + gcc
integration/hardened_malloc/run_tests.sh --compiler clang --repeat 3
```

Outputs per compiler:

- `results/hmalloc/tests-<UTCdate>-x86_64-<compiler>.json` — schema
  `anvil.hmalloc.tests/1`: per-test status array (58 entries), totals,
  pass/fail, machine facts, upstream SHA, compiler versions.
- `results/hmalloc/logs/tests-*.log` — full make + unittest transcripts.

A failing or flaky test is **committed as a failure** with its log and a
diagnosis — never silently retried into green.

## 4. Running the benchmark

**Inventory honesty first:** upstream hardened_malloc ships **no benchmark
harness**. Its `third_party/` contains only `libdivide.h` (a build-time
dependency of the allocator itself); `calculate-waste` is a static
size-class fragmentation table generator, not a runtime benchmark; and the
README explicitly optimizes for "long-term performance and memory usage
rather than allocator micro-benchmarks". Any claim of "running upstream's
benchmark" would be fiction — so Anvil ships a small one instead, in the
only way that is faithful to how upstream says the allocator should be
evaluated: by swapping the allocator under an identical, allocator-agnostic
workload using upstream's own documented `LD_PRELOAD` mechanism
(`preload.sh`; README § "Traditional Linux-based operating systems").

`bench/malloc_bench.c` is a fixed-seed (xorshift64\*) workload: small/medium/
large churn, realloc patterns, calloc, and 4-thread churn. The allocation
sequence is bit-identical across allocators; only the allocator varies. The
binary is compiled once (`gcc -O2`) and never recompiled per allocator.

```sh
integration/hardened_malloc/build.sh          # needs artifacts first
integration/hardened_malloc/bench/run_bench.sh             # 5 timed repeats
integration/hardened_malloc/bench/run_bench.sh --repeats 10 --ops 4000000
```

Runs: `glibc` (no preload, baseline) vs `hmalloc-default` vs
`hmalloc-light` (each preloaded). Output:
`results/hmalloc/bench-<UTCdate>-x86_64.json` (schema
`anvil.hmalloc.bench/1`) with per-phase mean/stdev/min/max ops-per-sec,
coefficient of variation, repeats count, glibc-relative ratios, machine
facts, and the upstream SHA. Raw per-run transcripts are kept under
`results/hmalloc/logs/`.

Interpretation guardrails, stated up front: these are single-machine
microbenchmark numbers. They measure allocator throughput on this specific
desktop and say **nothing** about hardened_malloc's actual goals (use-after-
free detection, quarantine, guard pages, layout randomization) — the point
of the project is security at acceptable cost, not winning this table. See
`results/hmalloc/SUMMARY.md` for the current results and observed variance.

## 5. Cross-arch status (read before trusting anything aarch64 here)

This machine has **no aarch64 glibc sysroot, no Android NDK, and no
qemu-user**. `cross-check.sh` therefore does only what is locally
verifiable, and labels everything else as CI-planned:

- Verified locally: clang's aarch64 backend emits genuine `EM_AARCH64`
  objects on this host; and for every upstream source, the exact first
  blocker under `--target=aarch64-linux-gnu` is recorded (currently: all C
  sources stop inside host glibc headers — `bits/wordsize.h`,
  `bits/libc-header-start.h` live only under the x86_64 multiarch include
  dir — and `new.cc` stops at missing C++ standard headers, `'new' file not
  found`; pointing `-I` at the host multiarch dir merely moves the failure
  to `gnu/stubs-32.h`, because `__x86_64__` is undefined for the target).
  Result: `results/hmalloc/cross-check-<UTCdate>-x86_64.json`.
- **Not run here, CI-planned** (mirroring upstream's own
  `.github/workflows/build-and-test.yml`): cross build with
  `apt gcc-aarch64-linux-gnu g++-aarch64-linux-gnu` and
  `make CONFIG_NATIVE=false`; native build+`make test` on an
  `ubuntu-24.04-arm` runner; optional `qemu-user-static` to execute the
  test binaries from x86_64 CI. The Android bionic variant additionally
  requires an AOSP/NDK bionic sysroot, which is Android-CI territory.

## 6. Results directory

Everything numeric lives under `results/hmalloc/`:

| File | Content |
|---|---|
| `tests-<date>-x86_64-<compiler>.json` | per-test suite results (schema v1) |
| `bench-<date>-x86_64.json` | allocator bench means/stdev (schema v1) |
| `cross-check-<date>-x86_64.json` | aarch64 blockers + CI plan |
| `logs/` | full human-readable transcripts of every run |
| `SUMMARY.md` | the honest rollup tying every number to its JSON/log |

The rule this directory follows: **every number in `SUMMARY.md` traces to a
committed JSON or log**, and anything not actually run on this machine is
listed as not-run with the reason. No invented benchmarks, no green ticks
borrowed from upstream CI.
