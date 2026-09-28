# Anvil CI

Two workflows guard the repo. `ci.yml` runs on every push to `main` and every
pull request (x86_64 runners); `arm64.yml` runs on pushes to `main` and manual
`workflow_dispatch` on GitHub's free arm64-hosted runners
(`ubuntu-24.04-arm`). Together they run the repository's real verification
gates — the same scripts a contributor runs locally — plus the GitHub Pages
deploy of the live progress page. Nothing here is a mock: every job maps to a
real script and a real artifact in the repo.

## Jobs

| Job | Workflow | Runs | Gates |
|---|---|---|---|
| `hmalloc` (matrix: `clang`, `gcc`) | `ci.yml` | `integration/hardened_malloc/build.sh --variant <cc> --config both`, `run_tests.sh --compiler <cc>`, `cross-check.sh` and `run_bench.sh --repeats 3 --ops 500000` (clang leg) | pinned-commit upstream builds, upstream test suite, cross-arch probe, bench harness |
| `hmalloc-native-aarch64` (gcc) | `arm64.yml` | `build.sh --variant gcc --config both`, `run_tests.sh --compiler gcc`, LD_PRELOAD interposition proof | native aarch64/glibc build + execution of the pinned upstream suite; the built .so really interposes allocation |
| `kernel-fragments` | `ci.yml` | `tools/kernelconfig/check.py` (warm, then `--offline`), `tools/kernelconfig/test_check.py` | every fragment symbol exists in the pinned upstream tree's real Kconfig; manifest coverage; offline reproducibility |
| `matrix` | `ci.yml` | `tools/matrix/matrix_lint.py --render`, then `git diff --exit-code matrix/README.md` | device YAML schema + honesty lint; rendered README is never stale |
| `patches` | `ci.yml` | `tools/patches/apply_check.sh` | patch portability — each patch must apply against its pinned upstream blob; fails on drift |
| `pages` | `ci.yml` | `tools/progress/generate.py`, then Pages upload/deploy on main pushes only | progress page is regenerable from `progress.json` |

## What each job proves — and what it deliberately does not

### hmalloc

**Proves:**

- The pinned upstream commit (`01df350c…` in `build.sh`) builds cleanly with
  both toolchains, in both upstream variants (`default`, `light`), using
  upstream's own Makefile unmodified. The gcc leg installs `gcc-14` because
  the scripts' probe rejects gcc-13 (`-std=c23`); upstream's stated minimum
  is gcc 14.2.0 / clang 19.1.7, and clang 18 on the runner is known to build
  the tree cleanly (documented in `build.sh`).
- Upstream's own test suite passes against the library each matrix leg just
  built. Hard gate: nonzero exit fails the job.
- clang's aarch64 backend emits real `EM_AARCH64` objects, and every upstream
  source file's exact first blocker under `--target=aarch64-linux-gnu` is
  recorded in the cross-check JSON.

**Does NOT prove:**

- **No device boots. Nothing runs on Android.** No bionic variant is built;
  no Android NDK is involved.
- **No aarch64 execution in this workflow.** `cross-check.sh` is
  compile-only by design (see its header: no sysroot, no NDK, no qemu-user
  in this environment). It *reports* blockers and exits 0 unless its own
  probe machinery breaks. Native aarch64 execution is `arm64.yml`'s job
  (next section) — and that proves glibc-Linux execution only, never
  Android.
- The upstream test suite covers the **default config only** — upstream's
  `test/Makefile` rejects non-default variants. `light` is built and shipped
  as an artifact, not tested by upstream's suite.
- Bench numbers from shared CI runners are noisy. Timing values never gate
  anything; the comparable number is each allocator's `ratio_vs_glibc`
  within a single run on a single machine. CI uses 3 timed reps of 500k ops
  (vs 5×2M locally) to keep the job short — means are coarser, the harness
  and its aggregation are identical.

**Reading a red `hmalloc` job:** look at which *step* failed.

- `build.sh` step red → the pinned upstream tree stopped building (upstream
  force-push, compiler regression, or a pin that needs updating).
- `run_tests.sh` step red → upstream's own suite failed at the pin. This is
  the loudest correctness signal this workflow produces.
- `cross-check.sh` step red → the probe environment broke (clang/readelf
  missing or misbehaving), not a finding about aarch64 portability — the
  script records findings, it does not gate on them.
- `run_bench.sh` step red → the bench harness failed to build or a run
  crashed. Red bench never means "slow" — timing is not gated.

Artifacts: `hmalloc-tests-<cc>`, `hmalloc-crosscheck-bench`, and
`hmalloc-logs-<cc>` (only on failure) under `results/hmalloc/`.

### hmalloc-native-aarch64 (`arm64.yml`)

Runs on GitHub's free arm64-hosted runner (`ubuntu-24.04-arm`), on pushes to
`main` and manual dispatch. gcc toolchain only.

**Proves:**

- The pinned upstream commit (`01df350c…` in `build.sh`) builds **natively
  on real aarch64/glibc hardware** with gcc-14, in both upstream variants
  (`default`, `light`), using upstream's own Makefile unmodified.
- Upstream's own test suite **executes natively on aarch64**: every test
  binary runs as a real arm64 process under upstream's unittest backend, and
  the suite must pass or the job is red. This closes the "aarch64 is
  compile-check only" gap for native Linux/glibc: ci.yml proves x86_64
  execution, `cross-check.sh` proves aarch64 *compilation*, this job proves
  aarch64 *execution*.
- The built default `.so` genuinely **interposes allocation**: a trivial
  dynamic binary runs under `LD_PRELOAD=…/libhardened_malloc.so` and the
  step fails unless `libhardened_malloc.so` shows up in the child's
  `/proc/self/maps`; `readelf` additionally confirms the library is
  `EM_AARCH64`.
- Result files are named for the arch that actually ran them (the scripts
  derive the arch from `uname -m`): `tests-<date>-aarch64-gcc-14.json` here,
  with the existing `tests-<date>-x86_64-*` history unchanged.

**Does NOT prove:**

- **The Android/bionic aarch64 artifacts under `build/hmalloc-android/` are
  still NOT executed anywhere** — not in this job, not in ci.yml, not
  locally. This is glibc Linux execution, not Android: no bionic sysroot,
  no NDK, no emulator, no device boots.
- `light` is built but not tested — upstream's `test/Makefile` rejects
  non-default variants (same caveat as the x86 legs).
- Only gcc runs here; there is no clang-on-aarch64 execution claim yet.
- Nothing about performance: arm64 runner hardware is a different machine
  class than the x86 bench host, no bench runs in this job, and no timing
  value gates anything.

**Reading a red `hmalloc-native-aarch64` job:** build step red → the pinned
tree stopped building natively on aarch64/gcc-14. test step red → upstream's
suite failed natively on aarch64 (the loudest signal this workflow adds).
interposition step red → the `.so` is not a real aarch64 object or was not
mapped into a preloaded child — a genuine execution-gap finding, not
flakiness.

Artifacts: `hmalloc-aarch64-tests` and `hmalloc-aarch64-logs` under
`results/hmalloc/`.

### kernel-fragments

**Proves:**

- Every line of every fragment (`base.cfg`, both arch configs, all four soc
  configs) resolves against the *real* Kconfig definitions of
  `GrapheneOS/kernel_common-6.6` @ branch `17`: symbol existence, prompt
  status, `depends on` evaluation, `select` conflicts, cross-layer
  consistency, and full `MANIFEST.yaml` coverage (no uncovered fragment
  lines, no orphan manifest rows). Exit code 1 on any error fails the job.
- The validation is **reproducible offline**: the identical invocation must
  pass a second time with `--offline` against the cache the warm run
  (re)built — this is exactly what a contributor with a warm cache runs
  locally, so CI red here means local red too.
- `base.cfg` alone passes offline (minimal pin assertion).
- `test_check.py` unit suite (19 tests, fixture-based, fully offline).

**Does NOT prove:**

- **No kernel is configured, built, or booted.** This validates fragments
  against Kconfig *definitions*, not a merged `.config`.
- The dependency evaluator is a deliberate subset parser: clauses it cannot
  parse are reported as `info`, not errors. Documented warnings
  (`INET`, `DEBUG_KERNEL`, `EFI_STUB` chains — see
  `hardening/kernel/README.md`, "Known gaps") are expected; `--strict` is
  intentionally not used because those warnings are documented, not bugs.

Mechanics: `check.py` shells out to `gh api` (preinstalled on runners,
authenticated with the workflow's read-only token — only needed on a cold
cache; a warm cache run makes zero API calls). `.cache/kconfig` is cached
with `actions/cache`, keyed on `hashFiles('tools/kernelconfig/check.py')`,
so a change to the tool (including its pinned repo/branch) re-warms rather
than silently reusing a stale snapshot.

**Honest caveat:** a cold cache fetches the branch's *current* head; the
README pins head `f97a55ff191d`. Once the cache is warm (both on CI and in
the repo's documented local workflow), the walk is pinned to the cached
snapshot. If GrapheneOS moves the branch and you want CI to see it, clear
the cache (bump the key or delete it in the Actions cache UI).

**`test_check.py` step:** the fixture cache (`tools/kernelconfig/testdata/`)
is not committed yet; the step skips loudly with a `::warning` annotation
until it lands, then runs unconditionally.

### matrix

**Proves:** every `matrix/devices/*.yaml` parses and validates against
`matrix/schema.json`, scores match the declared weights, every capability
claim (including every "unverified") carries an evidence id that exists in
that device's `matrix/evidence/<id>.md`, no orphan citations, every
non-Pixel family has at least one limitation, and the committed
`matrix/README.md` is exactly what `--render` produces.

**Does NOT prove:** that any claim about any device is *true* — only that
every claim is cited and internally consistent. Truth lives in the evidence
files; read them.

**Reading a red `matrix` job:** the lint step red → a YAML/schema/evidence
rule is broken (stderr names the file and rule). The diff step red → the
data is fine but someone edited devices/evidence without re-rendering:
run `python3 tools/matrix/matrix_lint.py --render`, commit the README.

### patches

Placeholder by design: probes for the patch piece's runner script
(`tools/patches/apply_check.sh`, then any `patches/**/apply_check.sh` — the
piece is being built in parallel) and runs the first one that exists;
otherwise it emits a `::warning` naming what was looked for — a visible
skip, not a silent green. Until then this job proves nothing.

### pages

Regenerates `progress/index.html` from `progress.json` and deploys
`progress/` to GitHub Pages (https://xenoaitham.github.io/anvil/). It is
deliberately **independent** of the gate jobs so a docs/status commit
deploys in seconds without waiting for a hardened_malloc build. Deploys
happen only on pushes to `main`; pull requests run the generation as a
validation step but do not deploy. Deployments serialize through the
`pages` concurrency group.

## Versions and permissions

`actions/checkout@v4`, `actions/setup-python@v5` (3.11),
`actions/cache@v4`, `actions/upload-artifact@v4`,
`actions/upload-pages-artifact@v3`, `actions/deploy-pages@v4`.
`arm64.yml` uses the same pinned `checkout@v4` / `upload-artifact@v4`.
Top-level `permissions: {}`; each job grants the minimum (`contents: read`
everywhere; the pages job adds `pages: write` + `id-token: write`).

## Timeouts

`hmalloc` 30 min (includes the bench leg), `hmalloc-native-aarch64` 30 min
(x86 evidence: the 58-test suite takes ~40 s per run plus a few minutes of
LTO build — the arm64 runner is slower but the margin holds), `kernel-fragments` 25 min (a
cold-cache Kconfig walk makes hundreds of small API calls),
`matrix`/`pages` 10 min, `patches` 15 min. A timeout is a failure, never a
retry-and-hope: if the cold walk starts tripping it, the cache is doing its
job wrong and that is worth a red run.
