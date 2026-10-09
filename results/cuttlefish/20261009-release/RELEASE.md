# Release note — Anvil cuttlefish campaign bzImages (2026-10-09)

The repo's copy of the campaign artifacts is by policy hashes-only: the
built bzImages live in the campaign tree (`/home/potato/anvil-cf/kernel/`)
and were, until this note, recorded only in per-attempt logs
(`campaign2/logs/bzimage-sha256.txt`). This is the canonical hash table.

Every kernel below is Linux 6.6.142-gc905c29016dd (AOSP `kernel/common`,
branch `android15-6.6`, pinned commit
`c905c29016dd2dbf8df45e7c0287455f67ef165b`), built in-tree with Ubuntu
clang/LLD 18.1.3, `LLVM=1`, `KCONFIG_CONFIG` per variant. Reproduction
path: `results/cuttlefish/20261008-campaign/scripts/` (bisect-build.sh +
the config inputs it names) on that pinned tree.

| variant | bzImage sha256 | role (ledger) |
|---|---|---|
| all-gpu | `ba7bb2053c2e1040b83575d3174e3cd47d1e3948dde51fd963e2926d371b20fa` | modules/initramfs staging build (`.config.all-gpu`), pre-bisect |
| stockgpu | `35c8c897e6ef858b5a62ae7e9b0f21e12c16689e5a41374416caee0d104bb25f` | attempt 004 control: stock defconfig + vehicle fixes, no heap — composer SIGSEGV loop |
| stockgpu-heap | `2045a86e9982f0ebbf51f90bebcd21f0eb37035113070d8931c6c68490fd947b` | attempt 005: + DMABUF_HEAPS_SYSTEM=y — first 6.6 sys.boot_completed (t=786 s) |
| anvil-veh | `a6ee8f92762730ee1efbcb9c5640d965eee95008bed6a7acce61d737bfb274a6` | attempt 006: fragments + vehicle fixes — ramoops/lockdown #PF crash t=17 s |
| anvil-veh2 | `068cb84eefc49605fc25075e5a09446fd1679e29b56729b53d19ea96465c1511` | attempt 007: + ramoops-n — **sys.boot_completed t=103 s (campaign goal)** |
| anvil-initfree | `08c5f33162616b3763fe8ea57e63f6cc177f7e9d43d3ec26f1a48e0ed40e0c86` | attempt 008: + initonfree — boot clean t=103 s, zero swap-corruption lines |
| anvil-final | `573a3ad9f296d188c32859c266565228b715c9abce1ff47168fd37595c96f823` | attempt 009: + ioring-n — **final hardened set, boot t=92 s** |
| anvil-ref | `065e766e38ce03b8763125413ef551faba0ace46a036508db36fedaf4ddbe84b` | attempt 003: exact 2026-09 #4 config rebuilt (bit-identical `.config`), 900 s no-crash |

Resolved per-variant configs (`config.*`) hash to the values in
`campaign2/logs/`; the decision-relevant ones are committed verbatim:
`results/cuttlefish/20261009-vehicle-fix/config.stockgpu{,-heap}`,
`results/cuttlefish/20261009-final/config.anvil-final`, and
`results/cuttlefish/20260928-022435/anvil-merged-kernel*.conf*` (2026-09).

`bzImage-anvil-final-memfd` and `bzImage-anvil-final-memfd2` are symlinks
to `bzImage-anvil-final` (same kernel bytes) — attempts 010/011 boot those
bytes with memfd-baked initramfs/init_boot variants; the variants are the
boot artifacts, not the kernel (`../20261009-memfd-bake/FINDINGS.md`).

## Archive decision (recorded 2026-10-09)

The repo is now the primary record: every attempt's console, verdict,
config, and the scripts to rebuild from the pinned tree are committed.
`/home/potato/anvil-cf` remains in place (it holds the only bzImage
copies, whose identity this note pins); it is rebuildable — source tree
at the pinned commit + committed scripts + committed config inputs — but
rebuilds are NOT bit-reproducible in general (RANDSTRUCT/layout seeds are
per-build), which is exactly why the hash table above pins the
boot-demonstrated artifacts rather than relying on reproducibility.
