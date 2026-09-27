# Anvil — plan and honesty policy

**Anvil** brings GrapheneOS's portable security hardening to Android devices beyond
the Pixel line, and measures itself against the GrapheneOS org's *actual public
repositories* — never against descriptions of them.

## The bar

Every artifact here is compared side-by-side, labels stripped, against GrapheneOS's
nearest equivalent:

| Anvil piece | GrapheneOS equivalent it is judged against |
|---|---|
| `docs/grapheneos-baseline.md` | `grapheneos.org` docs, `platform_manifest`, repo inventories |
| `hardening/kernel/` fragments | kernel hardening configs in `GrapheneOS/kernel_common-6.x` trees |
| `matrix/` device security matrix | device-support documentation and public feature tables |
| `integration/hardened_malloc/` | upstream `GrapheneOS/hardened_malloc` (Makefile, bench suite, tests) |
| `patches/platform/` | upstream platform commits in GrapheneOS mirrors of AOSP repos |
| `.github/workflows/` | GrapheneOS release/CI tooling (`platform_build_release`, `.github`) |

A separate critic agent with fresh context receives both artifacts with labels
stripped, picks a winner, and names the single biggest gap. Pieces iterate until
the critic picks Anvil's work blind.

## Honesty policy (non-negotiable)

1. **No claim without an artifact.** Every number in this repository traces to a
   committed build log, test output, benchmark result, or a cited public source
   (URL + access date).
2. **No fake boots.** CI verifies what CI can verify: compilations, test suites,
   static analysis, patch applicability, data lint. Booting a device requires the
   device; where that is impossible, the matrix says `unverified` — never `yes`.
3. **Hardware limits are documented, not hidden.** If a device family cannot take
   a feature (no MTE support, no re-locked bootloader with rollback protection,
   no hardware attestation), the row says so and cites the evidence.
4. **Upstream is upstream.** GrapheneOS's `hardened_malloc` is integrated, not
   forked or claimed. The contribution is portability glue, verification tooling,
   benchmarking, and honest device-level analysis.

## Pieces

1. `baseline` — inventory of GrapheneOS's portable hardening surface, measured
   from the real repos (counts, sizes, commits, configs), feeding the taxonomy
   every later piece is scored against.
2. `kernel-config` — layered kernel config fragments (base → arch → SoC) ported
   from GrapheneOS's kernel trees, plus a dependency-checking validator.
3. `matrix` — per-device-family security matrix, every cell cited, schema-linted.
4. `hmalloc` — hardened_malloc build glue for non-Pixel integration, test-suite
   runs, and benchmarks on documented hardware.
5. `platform-patches` — upstream-quality AOSP platform patches, apply-checked
   against pinned upstream sources.
6. `ci` — GitHub Actions that run the real gates; Pages deployment of this page.
7. `readme` — the front door, written last so it can't lie about what exists.
