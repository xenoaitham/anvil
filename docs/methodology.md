# Methodology

How Anvil measures, scores, benchmarks, and reviews. One page; every rule here
is enforced by a tool or artifact in the repo.

## Measurement

**Sources are the real repositories.** Local reference clones of the
GrapheneOS org's repos at pinned HEADs (table at the top of
[docs/grapheneos-baseline.md](grapheneos-baseline.md), all accessed
2026-09-27) plus GitHub API calls cited inline with access dates. Never a
description of upstream in place of upstream.

**Divergence numbers come from API commit-log sampling, not full diffs.** For
each fork (e.g. `platform_bionic`), a paginated listing of all commits since
2024-09-27 including AOSP-merge traffic, with author attribution; "team
share" is the fraction authored by GrapheneOS developers (measured example:
51 of 2361 bionic commits, ~2.2%). Representative commits are cited by SHA so
any claim can be re-checked through the API. This is stated in the baseline
wherever the numbers appear.

**What counts as verified** (the matrix legend in
[matrix/README.md](../matrix/README.md), applied repo-wide per the honesty
policy in [docs/plan.md](plan.md)):

- **yes** — a citation exists in `matrix/evidence/<device>.md`; cloned
  GrapheneOS docs arbitrate Pixel claims.
- **no** — the hardware or vendor policy forbids the feature, with evidence.
  A finding, not an insult.
- **unverified** — we looked, could not confirm from a public source, and the
  cell names its verification path. Not a soft yes.

Coverage: 13 device families, 156 capability cells, 55 marked unverified
(35%) — printed by [tools/matrix/matrix_lint.py](../tools/matrix/matrix_lint.py)
on every run and re-printed in CI.

## Scoring

Matrix scores are weighted capability counts, not rankings
([tools/matrix/matrix_lint.py](../tools/matrix/matrix_lint.py) recomputes
every declared score; a mismatch fails the lint):

| Criterion | Weight |
|---|---|
| MTE implemented by the SoC's cores | 3 |
| Own OS with locked bootloader + verified boot (partial: 1.5) | 3 |
| Anti-rollback (partial: 1) | 2 |
| Hardware-backed key attestation | 2 |
| ≥ 48-month vendor security-update period | 1 |

Maximum 11; Pixel rows score full marks as reference rows. The linter also
requires an evidence id for every claim (including every unverified), no
orphan citations, at least one documented limitation per non-Pixel family,
and byte-identical `--render` output against the committed
[matrix/README.md](../matrix/README.md) — the staleness gate in CI.

The upstream measuring stick is
[taxonomy/portable-taxonomy.yaml](../taxonomy/portable-taxonomy.yaml):
73 entries — 60 `portable` (device-independent), 9 `partial` (carry under
conditions), 4 `pixel-only` (impossible without vendor/OEM cooperation,
recorded for honesty).

## Benchmarks

Upstream hardened_malloc ships no benchmark harness (measured:
[docs/grapheneos-baseline.md](grapheneos-baseline.md) §a), so Anvil built one
that follows upstream's own evaluation doctrine — swap the allocator under an
identical workload via upstream's documented `LD_PRELOAD` mechanism
([integration/hardened_malloc/README.md](../integration/hardened_malloc/README.md) §4):

- **Workload:** `bench/malloc_bench.c` — fixed-seed xorshift64* allocation
  sequences (small/medium/large churn, realloc, calloc, 4-thread churn); the
  allocation stream is bit-identical across allocators; the binary is
  compiled once (`gcc -O2`), never per allocator.
- **Comparators:** glibc baseline (same binary, unpreloaded), hmalloc
  `default`, hmalloc `light`.
- **Repeats:** 1 untimed warmup + 5 timed runs per allocator locally; the CI
  leg uses 3 runs of a shorter op count, aggregation identical
  ([.github/workflows/README.md](../.github/workflows/README.md)).
- **Statistics:** per-phase mean/stdev/min/max ops/s, coefficient of
  variation, glibc-relative ratios. Observed CV: 1.5–11% single-threaded,
  16–17% on the 4-thread phase — re-run differences inside those bands are
  the same result ([results/hmalloc/SUMMARY.md](../results/hmalloc/SUMMARY.md)).
- **Machine:** one desktop (Intel i5-10400F, 15 GiB RAM, Pop!_OS 24.04);
  raw per-run transcripts are committed under `results/hmalloc/logs/`.
  Timing never gates anything.

**Test method:** upstream's own `make test` — 62 test binaries driven by 58
checks in `test/test_smc.py`, default config only (upstream's `test/Makefile`
rejects variants), 3 timed runs per compiler × 2 compilers (clang 18.1.3,
gcc 14.2.0), every run committed. Details and the not-run list:
[results/hmalloc/SUMMARY.md](../results/hmalloc/SUMMARY.md).

## Review protocol

Full text: [docs/review-protocol.md](review-protocol.md). Per piece: build →
`tools/review/anonymize.py` pairs the finished artifact with GrapheneOS's
nearest *real* equivalent (cloned or fetched, never a description) into
anonymous `candidate_A`/`candidate_B` directories → a fresh-context critic
sees both plus the piece spec, picks a winner, names the loser's biggest gap
→ iterate until the critic picks ours blind (cap 3 rounds, then honest
failure) → verdicts recorded in
[progress/progress.json](../progress/progress.json) and rendered to the live
progress page by `tools/progress/generate.py`.

Tally: 6 critic wins across 8 rounds; every piece won in round 1. Two critic
findings produced fixes along the way: an overstated test-binary count
(63 → 62) and a CI kernel gate that fetched the upstream branch head instead
of the pinned tree (now pinned by SHA).
