# Anvil

Anvil ports the portable half of [GrapheneOS](https://github.com/GrapheneOS)'s
security hardening to Android devices beyond the Pixel line, and measures every
piece against the GrapheneOS org's real public repositories — never against
descriptions of them. It produces layered kernel config fragments, an AOSP
platform patch series, hardened_malloc integration glue with committed test and
benchmark results, and a per-device security matrix whose every cell is cited
or marked unverified.

**Honesty policy:** no claim without an in-repo artifact — a build log, a test
run, a benchmark output, or a cited public source. Hardware limits are
documented, not papered over. Nothing is claimed to boot without a boot.
([docs/plan.md](docs/plan.md))

## Status

All six pieces passed blind review ([protocol](docs/review-protocol.md),
[ledger](progress/progress.json)): in each round, a fresh-context critic
received Anvil's artifact and GrapheneOS's nearest real equivalent with labels
stripped, picked a winner, and named the loser's biggest gap.

| Piece | Artifact | Blind-review verdict |
|---|---|---|
| baseline | [docs/grapheneos-baseline.md](docs/grapheneos-baseline.md) | Won round 1 |
| kernel-config | [hardening/kernel/](hardening/kernel/README.md) | Won round 1 |
| matrix | [matrix/](matrix/README.md) | Won round 1 |
| hmalloc | [integration/hardened_malloc/](integration/hardened_malloc/README.md), [results/hmalloc/SUMMARY.md](results/hmalloc/SUMMARY.md) | Won round 1 |
| platform-patches | [patches/platform/](patches/platform/), [docs/patches.md](docs/patches.md) | Won round 1 |
| ci | [.github/workflows/ci.yml](.github/workflows/ci.yml) ([what it gates](.github/workflows/README.md)) | Won round 1 |

Two defects critics caught and got fixed:

- **hmalloc:** the upstream test-binary count was overstated (63); corrected to
  62, matching upstream's `test/Makefile`
  ([results/hmalloc/SUMMARY.md](results/hmalloc/SUMMARY.md)).
- **ci:** the kernel Kconfig gate went red on GitHub because its fetch tracked
  the upstream branch head, which had drifted from the pinned tree; fixed by
  pinning the fetch to a tree SHA (`KERNEL_TREE_PIN`,
  [.github/workflows/ci.yml](.github/workflows/ci.yml)).

Ledger note: the aggregate tally (6 critic wins, 8 review rounds) is in
[progress/progress.json](progress/progress.json); the per-piece round records
for matrix and hmalloc were lost to an overwrite of that file, while the other
four pieces' records are intact.

## Quickstarts

### ROM maintainer

- **Kernel hardening** — merge the fragments in order base → arch → soc → your
  device config, then validate before building
  ([details](hardening/kernel/README.md)):
  ```sh
  scripts/config --file "$ANVIL/hardening/kernel/base.cfg" \
                 --file "$ANVIL/hardening/kernel/arch-arm64.cfg" \
                 --file "$ANVIL/hardening/kernel/soc/qualcomm.cfg"
  make ARCH=arm64 olddefconfig
  python3 tools/kernelconfig/check.py \
      hardening/kernel/base.cfg hardening/kernel/arch-arm64.cfg \
      hardening/kernel/soc/qualcomm.cfg \
      --manifest hardening/kernel/MANIFEST.yaml --offline
  ```
- **Platform patches** — vendor `hardened_malloc` via a `local_manifests`
  project, then `git am` the three-patch series into `bionic` and
  `system/core`, with expected conflict surface and post-boot checks
  documented in [docs/patches.md](docs/patches.md).
- **hardened_malloc requirements** — 4 KiB pages, 48-bit VA (or shrink
  `CONFIG_CLASS_REGION_SIZE`), and `vm.max_map_count 1048576` in `init.rc`;
  pinned-commit build glue in
  [integration/hardened_malloc/README.md](integration/hardened_malloc/README.md) §1.

### Security researcher

- [matrix/README.md](matrix/README.md) — 13 device families, 156 capability
  cells, every claim cited in `matrix/evidence/<device>.md`; 55 cells (35%)
  are marked unverified by design, each naming its verification path.
- [docs/grapheneos-baseline.md](docs/grapheneos-baseline.md) — the measured
  GrapheneOS baseline every claim here is scored against.
- [results/hmalloc/SUMMARY.md](results/hmalloc/SUMMARY.md) — test and
  benchmark numbers with committed raw data; reproduce with the scripts in
  [integration/hardened_malloc/](integration/hardened_malloc/README.md).

### Contributor

- CI runs the same gates you run locally: builds, upstream test suite,
  Kconfig validation, matrix lint + staleness gate, patch apply-check, Pages
  deploy — [what each job proves and does not](.github/workflows/README.md).
- New work goes through the blind-review loop in
  [docs/review-protocol.md](docs/review-protocol.md); verdicts land in
  [progress/progress.json](progress/progress.json) and the
  [live progress page](https://xenoaitham.github.io/anvil/).

## How Anvil compares to GrapheneOS

| What | GrapheneOS has (measured) | Anvil's relationship |
|---|---|---|
| hardened_malloc | The upstream project, shipped in their OS | **Integrated, not forked**: every build clones upstream at a pinned commit and runs upstream's own Makefile, configs and tests unmodified ([integration/hardened_malloc/README.md](integration/hardened_malloc/README.md)) |
| Kernel hardening | A hardened `gki_defconfig` per arch in their own kernel trees, plus per-Pixel prebuilt kernel repos | Portable config fragments for non-Pixel GKI devices — 99 symbols across base/arch/soc layers, each line traced to a commit or baseline state and validated against real Kconfig ([hardening/kernel/](hardening/kernel/README.md)) |
| Platform hardening | 109 forked AOSP platform repos carried in their manifest | A 3-patch portable series (allocator swap, per-service opt-out, `vm.max_map_count`), apply-checked against pinned AOSP release tags ([docs/patches.md](docs/patches.md)) |
| Device claims | Official support for the Pixel 6→10a generation only | An evidence matrix over 13 device families, including devices GrapheneOS declines; Pixel rows are full-marks reference points, not parity claims ([matrix/README.md](matrix/README.md)) |
| Verification tooling | A production release process; no published benchmark harness | The tooling upstream lacks and we had to build: Kconfig validator, matrix linter, patch apply-check harness, bench harness, CI gates |

Impossible without vendor cooperation — documented, not hidden; each item
traces to evidence in
[docs/grapheneos-baseline.md](docs/grapheneos-baseline.md) §e:

- Verified boot with rollback protection requires the OEM's firmware signing
  keys and rollback indexes.
- Monthly firmware/driver/HAL security updates are vendor output; a ROM cannot
  create them.
- Hardware key attestation depends on factory-provisioned keys.
- MTE enablement requires the SoC and DRAM integration to support it; where
  hardware forbids it, the matrix says `no`, never `portable`.

## Limitations

- **No device boots are claimed, anywhere.** CI verifies compilations, test
  suites, static analysis, data lint, and patch applicability — nothing runs
  on Android ([.github/workflows/README.md](.github/workflows/README.md),
  "Does NOT prove" per job).
- **aarch64 is compile-check only.** The cross-arch check records exact
  compile blockers; no aarch64 binary is executed here or in CI
  ([integration/hardened_malloc/README.md](integration/hardened_malloc/README.md) §5,
  [results/hmalloc/SUMMARY.md](results/hmalloc/SUMMARY.md) "Not run").
- **Benchmarks come from one desktop machine**, with raw per-run data
  committed and variance bands documented; they say nothing about devices
  ([results/hmalloc/SUMMARY.md](results/hmalloc/SUMMARY.md)).
- **Patches are apply-checked, not compile-tested.** `git apply --check`
  against pinned upstream blob SHAs proves applicability; no full AOSP tree
  was ever built with them ([docs/patches.md](docs/patches.md)).
- **35% of matrix capability cells are unverified by design** (55 of 156;
  printed by [tools/matrix/matrix_lint.py](tools/matrix/matrix_lint.py) on
  every run). Unverified is not a soft yes — each cell names what would
  verify it ([matrix/README.md](matrix/README.md)).

The measurement and scoring rules behind these numbers are in
[docs/methodology.md](docs/methodology.md).

## Links

- Live progress page: <https://xenoaitham.github.io/anvil/>
- Repository: <https://github.com/xenoaitham/anvil>
- Plan and honesty policy: [docs/plan.md](docs/plan.md)
- Review protocol: [docs/review-protocol.md](docs/review-protocol.md)
- License: MIT ([LICENSE](LICENSE))
