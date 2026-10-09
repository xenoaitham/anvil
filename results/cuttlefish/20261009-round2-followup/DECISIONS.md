# Round-2 critic follow-ups — decisions and evidence (2026-10-09)

Covers the three secondary notes from the blind-critic round 2
(`../20261009-review-round2/REVIEW.md`), each decided and, where the note
proposed a fragment change, verified through the real tree's kconfig.

## 1. BPF_UNPRIV_DEFAULT_OFF — KEEP `=n` (GOS parity); flip rejected

The critic noted the mainline default (unpriv BPF off) is "strictly safer"
for a production GKI. Considered and rejected for the fragment set:

- Anvil's contract is GOS-authored values with provenance ("no
  Anvil-invented values", base.cfg header). Flipping would introduce an
  Anvil-invented hardening delta with no upstream reference.
- GOS runs this exact state in production on third-party-app Pixels; their
  gate is userspace/SELinux policy, which a ROM builder must bring anyway
  (README, "Their userspace-side gating").
- The exposure delta is deployment-specific; making the flip is a one-line
  deliberate override, now documented as such in `base.cfg`'s BPF block.

Fragment content unchanged. Documentation updated (`base.cfg`, README).

## 2. Dead-letter `# CONFIG_MODVERSIONS is not set` — DROPPED from base.cfg

GOS's defconfig carries the negative; on this branch `RANDSTRUCT_FULL`
selects `MODVERSIONS`, so it resolves `=y` regardless. Verified before the
edit, on android15-6.6 @ c905c29016dd, in-tree `olddefconfig`, clang 18.1.3,
LLVM=1 (`repro-deadletter-and-order.sh`, output in `experiment-output.txt`):

- Concatenation A (with the line) vs B (without): **byte-identical resolved
  `.config`, 7575 lines**; both resolve `CONFIG_MODVERSIONS=y`.
- The committed `config.anvil-final` (attempt 009 boot kernel) has
  `CONFIG_MODVERSIONS=y` (line 877) — the boot claim is unaffected: the
  final set already ran with the select-back value.

Edits: `hardening/kernel/base.cfg` (line removed, provenance comment
rewritten), `hardening/kernel/MANIFEST.yaml` (row removed — manifest mode
rejects orphan rows). The A/B run was made with the pre-edit fragment; the
committed script re-run post-edit resolves to the same 7575-line config.

## 3. Merge-order requirement — DOCUMENTED (README, "Merge order is load-bearing")

Fragments must concatenate AFTER the origin `gki_defconfig`; the
`override: reassigning to symbol` warnings are the correct outcome.
Demonstrated empirically on the same tree: reversed concatenation
(origin lines last) resolves `CONFIG_HIBERNATION=y`, `CONFIG_TIPC=m`,
`CONFIG_BINFMT_MISC=y` again — silent resurrection, no warning that the
fragment negatives were overwritten. README now carries the ordering rule
plus a post-merge assertion grep.

## Also in this session (same follow-up work)

- INIT_ON_FREE x86_64 retention policy written into
  `../../results/cuttlefish/20260928-022435/CUTTLEFISH_EVIDENCE.md` §4.
- Upstream draft for the DMABUF_HEAPS_SYSTEM gap: `patches/kernel-gki/`
  (patch + ISSUE.md + README; `git apply --check` clean).
- FINDINGS.md correction: the 6.12 image kernel does NOT have the heap set
  (dated correction note in `../20261009-vehicle-fix/FINDINGS.md`); the
  6.6 causal attribution (attempts 004/005, one-line config delta) is
  unaffected.
