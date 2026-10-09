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

All ten pieces passed blind review ([protocol](docs/review-protocol.md),
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
| emulator-milestone | [results/emulator/EVIDENCE.md](results/emulator/EVIDENCE.md), [emulator/](emulator/README.md) | Won round 1 |
| arm64-native | [.github/workflows/arm64.yml](.github/workflows/arm64.yml), [results/hmalloc/tests-20260928-aarch64-gcc-14.json](results/hmalloc/tests-20260928-aarch64-gcc-14.json) | Won round 1 |
| cuttlefish-kernel | [results/cuttlefish/](results/cuttlefish/20260928-022435/CUTTLEFISH_EVIDENCE.md) | Won round 1 |

Defects critics caught and got fixed:

- **hmalloc:** the upstream test-binary count was overstated (63); corrected to
  62, matching upstream's `test/Makefile`
  ([results/hmalloc/SUMMARY.md](results/hmalloc/SUMMARY.md)).
- **ci:** the kernel Kconfig gate went red on GitHub because its fetch tracked
  the upstream branch head, which had drifted from the pinned tree; fixed by
  pinning the fetch to a tree SHA (`KERNEL_TREE_PIN`,
  [.github/workflows/ci.yml](.github/workflows/ci.yml)).
- **emulator-milestone:** EVIDENCE.md section numbering gap; the smoke JSON's
  pass predicate was looser than the shell gates — both fixed.
- **cuttlefish-kernel:** the documented `scripts/config` merge recipe was a
  no-op (its `--file` flag overwrites, it cannot merge); replaced with
  `merge_config.sh` in both READMEs, and base.cfg's RANDSTRUCT/MODVERSIONS
  comment was backwards for this branch (RANDSTRUCT_FULL selects MODVERSIONS)
  — corrected.

Ledger: the full per-piece record — every round verdict, every named gap,
and the aggregate tally (10 critic wins, 12 review rounds) — is in
[progress/progress.json](progress/progress.json) and rendered on the
[live progress page](https://xenoaitham.github.io/anvil/).

## Emulator milestone

Anvil's userland stack now **runs** on a real Android system, not just
compiles: a booted SDK emulator (Android 16, userdebug) executes the
pinned-commit hardened_malloc build under `LD_PRELOAD` with verified
malloc-family traffic, refuses `dlopen` with upstream's own initial-exec TLS
signature, and runs a zygote-launched app under the allocator via the
sanctioned `wrap.<package>` property. The campaign also pinned two
reproducible toolchain defects with committed probes: NDK emutls recursing
through interposed malloc below API 29 (build floor raised to 29), and NDK
clang 19 in C23 mode silently dropping bare `alignas` on struct members —
which had collapsed hardened_malloc's page-aligned regions table and aborted
its first allocation. Full narrative with raw captures:
[results/emulator/EVIDENCE.md](results/emulator/EVIDENCE.md); harness and
honest limits: [emulator/README.md](emulator/README.md); platform evidence:
[matrix/evidence/sdk-emulator.md](matrix/evidence/sdk-emulator.md).

Not claimed from this milestone: kernel fragments were not executed on the
stock goldfish kernel (the Cuttlefish campaign below covers custom-kernel
execution), the aarch64 **Android** artifacts are still compile-checked only
(native aarch64 execution now runs in CI on glibc —
[arm64.yml](.github/workflows/arm64.yml)), and nothing transfers to hardware
claims. This milestone passed blind review round 1
([protocol](docs/review-protocol.md), [ledger](progress/progress.json)).

## Kernel-on-Cuttlefish campaign

A self-built `android15-6.6` android-common kernel (`c905c29016dd`, clang 18
LLVM build) with `base.cfg` + `arch-x86_64.cfg` merged over the stock
Cuttlefish kernel config **boots and executes into Android userspace** on
Cuttlefish (Android 17 image): first-stage init, ext4 first-stage mounts,
second-stage init, servicemanager and HALs by t≈15 s. From the running
kernel's own console, the hardening is **live**: lockdown LSM in
confidentiality mode, init-on-alloc + stack zeroing, the full x86_64
mitigation set (eIBRS, BHI clearing, MMIO stale data, Retbleed), KASLR.

The honest boundary, updated 2026-10-09: **`sys.boot_completed=1` at t=103 s
— reached** with the full fragment set on the same 6.6 source tree
([evidence](results/cuttlefish/20261009-boot-completed/): verdict, full
serial console, and a 42-file live-kernel posture dump — lockdown
`[confidentiality]`, KFENCE 500, module sig_enforce Y, `vm.mmap_rnd_bits`
32, sysrq 0, `/dev/mem`/`/dev/port`/binfmt_misc/TIPC/hibernation/
memory-hotplug absent, 234 randomized kmalloc caches). Getting there
required root-causing two 6.6-vs-image gaps that are **not fragment
issues** — both reproduce on the clean stock-defconfig control: the origin
x86_64 `gki_defconfig` omits `CONFIG_DMABUF_HEAPS_SYSTEM=y` (the image's
minigbm allocator HAL then dies and the composer SIGSEGVs on an unchecked
null; upstream draft: [patches/kernel-gki/](patches/kernel-gki/)), and 6.6
SELinux predates the `memfd_class` policycap (the image's libcutils then
needs the `sys.use_memfd=1` override or system_server dies on ashmem —
since 2026-10-09 baked deterministically into the boot artifacts rather
than set by an adb race: attempt 011 booted t=96 s with the prop from
boot defaults and zero ashmem deaths, no adb involved;
[record](results/cuttlefish/20261009-memfd-bake/FINDINGS.md)). One genuine
fragment-vehicle interaction also had to be
neutralized: `LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY` correctly rejects the
crosvm `ramoops.mem_address` hardware module_param at boot parse, whereupon
ramoops binds a pstore console to physical address 0 and panics the kernel
(t=17 s, forensics committed); the vehicle-compatible fix disables
`CONFIG_PSTORE_RAM` on Cuttlefish and keeps forced lockdown intact. The
2026-09 "crashes in the 10–15 s window every attempt" claim is corrected:
that signature was build-dependent and did not reproduce from the committed
config on today's toolchain; the earlier consoles remain valid records for
the builds they captured.
Full record, controls, forensics and the deviation classes:
[results/cuttlefish/](results/cuttlefish/20260928-022435/CUTTLEFISH_EVIDENCE.md).
Passed blind review round 1.

## Quickstarts

### ROM maintainer

- **Emulator smoke** — validate the hardened_malloc stack on a live Android
  system before touching a device tree:
  ```sh
  emulator/setup-host.sh      # SDK + NDK + AVD (honours ANDROID_HOME)
  emulator/boot.sh --keep     # headless boot, KVM
  emulator/smoke.sh           # LD_PRELOAD interposition + wrap demo
  emulator/posture.sh         # platform security posture dump
  ```
  ([details](emulator/README.md))

- **Kernel hardening** — merge the fragments in order base → arch → soc → your
  device config, then validate before building
  ([details](hardening/kernel/README.md)):
  ```sh
  ARCH=arm64 scripts/kconfig/merge_config.sh -m arch/arm64/configs/gki_defconfig \
      "$ANVIL/hardening/kernel/base.cfg" \
      "$ANVIL/hardening/kernel/arch-arm64.cfg" \
      "$ANVIL/hardening/kernel/soc/qualcomm.cfg"
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
  "Does NOT prove" per job). The one Android-system execution claims are
  scoped to emulators/virtual machines: the SDK emulator
  ([results/emulator/](results/emulator/EVIDENCE.md)) and cuttlefish
  ([results/cuttlefish/](results/cuttlefish/20260928-022435/CUTTLEFISH_EVIDENCE.md))
  — and the cuttlefish campaign's fragment kernel does **not** reach
  `sys.boot_completed` (see the Kernel-on-Cuttlefish section above).
- **aarch64: glibc execution, not Android execution.** Since
  [arm64.yml](.github/workflows/arm64.yml), upstream's full test suite
  executes natively on aarch64 in CI (58/58, gcc-14, pinned commit —
  [results/hmalloc/tests-20260928-aarch64-gcc-14.json](results/hmalloc/tests-20260928-aarch64-gcc-14.json)).
  Still compile-check only: the **Android/bionic** aarch64 artifacts
  ([integration/hardened_malloc/README.md](integration/hardened_malloc/README.md) §5) —
  no aarch64 Android system has run them.
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
