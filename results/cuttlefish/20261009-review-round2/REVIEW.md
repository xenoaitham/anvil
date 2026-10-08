# Blind review round 2 — fragment set vs origin gki_defconfigs (2026-10-09)

Protocol: fresh-context critic, labels stripped, origin x86_64
`gki_defconfig` as baseline; both pairings resolved through the actual
android15-6.6 tree's kconfig (`conf --olddefconfig`, clang) so the verdict
is empirical, not stylistic. Campaign protocol: builder/critic per fix.

## Verdict (verbatim structure, full text below)

- **WINNER: the Anvil fragment set** (`base.cfg` + `arch-x86_64.cfg`
  merged after origin, last-write-wins).
- Decisive empirical fact: after kconfig resolution the two pairings
  produce **byte-identical `.config`** — the contest is decided on
  robustness: explicit `# ... is not set` negatives (vs the candidate's
  silent omissions that any upstream re-sync resurrects), pinned
  drift-prone defaults (full x86 mitigation + KASLR surface), and no
  deleted load-bearing lines (the candidate's deleted `MODULE_SIG=y`
  only survived via this tree's own default).
- **SINGLE BIGGEST GAP: `CONFIG_IO_URING=y` left open** — with the
  required companion line, since `BLK_DEV_UBLK` (=y in origin) does
  `select IO_URING`:
  ```
  # CONFIG_BLK_DEV_UBLK is not set
  # CONFIG_IO_URING is not set
  ```
  → acted on: `ioring-n.cfg`, verified by boot (see below).
- Secondary notes (3):
  1. `# CONFIG_BPF_UNPRIV_DEFAULT_OFF is not set` — carried from GOS;
     on a production GKI the mainline default (unpriv BPF off) is
     strictly safer; flip deliberately.
  2. base.cfg's `# CONFIG_MODVERSIONS is not set` is a dead letter
     (`RANDSTRUCT_FULL` selects it back `=y` — verified); ~30 lines
     restate origin values verbatim — keep as drift canaries.
  3. Ordering hazard: fragments must concatenate AFTER origin
     (kbuild `override: reassigning to symbol` warnings are the correct
     outcome); reversed concatenation silently resurrects
     HIBERNATION/TIPC/BINFMT_MISC.
- VERDICT CONFIDENCE: high.

## Action taken on the gap

`campaign2/groups/ioring-n.cfg` adds both negative lines; boot
`anvil-final` = fragments + vehicle fixes + ioring-n — result recorded in
`../20261009-final/` (boot console + verdict; whether Android 17
userspace tolerates io_uring-off is exactly what that run determines).

## Full critic output

<details><summary>unedited</summary>

All verification complete. Here is the review.

**Baseline note:** `.review-src/kernel-theirs/gki_defconfig` is the
**arm64** defconfig (ARCH_QCOM, ARM64_VA_BITS_48, SHADOW_CALL_STACK); the
operative x86_64 origin baseline is
`/home/potato/anvil-cf/kernel/common/arch/x86/configs/gki_defconfig`.
Both pairings were resolved through that actual 6.6 tree's kconfig
(`conf --olddefconfig`, clang toolchain) — several claims below are
empirically settled, not guessed.

**1. Delta summaries**

**Candidate** (`gos-gki-x86-defconfig`, full file): **22 added / 9
removed / 2 changed values** vs origin. The 9 removals are *silent
omissions* — no `# ... is not set` line exists for them. Most
consequential: `CONFIG_INIT_ON_FREE_DEFAULT_ON=y` (zeroing on free),
`CONFIG_RANDSTRUCT_FULL=y` (empirically verified it `select MODVERSIONS`
back `=y`, so its deleted `CONFIG_MODVERSIONS=y` line self-heals),
`CONFIG_LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY=y` (+LSM+EARLY),
`CONFIG_RANDOM_KMALLOC_CACHES=y`, `CONFIG_MODULE_SIG_FORCE=y`+`SHA256`
replacing `MODULE_SIG`/`MODULE_SIG_PROTECT` (empirical: `MODULE_SIG`
resolves `=y` anyway via this tree's own `default y`).
Removals: `HIBERNATION=y`, `MEMORY_HOTPLUG/HOTREMOVE=y`, `TIPC=m`,
`BINFMT_MISC=y`, plus `MODULE_SIG=y`.

**Theirs** (`base.cfg` + `arch-x86_64.cfg` merged onto origin,
last-write-wins): **32 added / 0 removed / 7 changed** (5 real
disablements; `DEFAULT_MMAP_MIN_ADDR` 32768→65536; 1 phantom
`MODVERSIONS` select-restored). Same five core adds, **plus the entire
set the candidate never touches**: `PAGE_TABLE_ISOLATION`, `RETPOLINE`,
`RETHUNK`, `CPU_UNRET_ENTRY`, `CPU_IBRS_ENTRY`, `CPU_SRSO`,
`CALL_DEPTH_TRACKING`, `MITIGATION_SPECTRE_BHI`, `MITIGATION_RFDS`,
`RANDOMIZE_BASE`, `RANDOMIZE_MEMORY`. Every removal of an origin `=y`
line is an explicit `# CONFIG_X is not set`.

Decisive empirical fact: after kconfig resolution on this tree with
clang, the two pairings produce **byte-identical `.config`** (0-line diff
across all 7541 lines). The contest is decided on robustness, not value.

**2. WINNER: their set** — equality is where pairing discipline decides.
The candidate is a comment-free fork whose hardening deltas exist only as
diffs from upstream: its removals are invisible omissions that any
mechanical re-sync silently resurrects, and it relies on unexamined
Kconfig defaults for the entire x86 CPU mitigation/KASLR surface — the
exact regression class a production pairing exists to prevent. Theirs
encodes every removal as an explicit negative line, tags every value with
its upstream commit, and pins the eleven drift-prone defaults. It also
never deletes load-bearing lines it depends on.

**3. SINGLE BIGGEST GAP in the winner: `CONFIG_IO_URING=y` is left wide
open.** Neither fragment mentions it; it resolves `=y` in the winner's
final config. io_uring is the single richest kernel attack surface of the
last five years; Google blocks it for Android apps at the policy layer
precisely because it cannot be trusted kernel-side. A pairing that kills
TIPC but leaves io_uring untouched has inverted priorities. Close it with
`# CONFIG_BLK_DEV_UBLK is not set` + `# CONFIG_IO_URING is not set`
(both required: the former selects the latter).

**4. SECONDARY NOTES:** (1) `# CONFIG_BPF_UNPRIV_DEFAULT_OFF is not set`
— on a production GKI with third-party apps the mainline default is
strictly safer and costs nothing. (2) Dead-letter `MODVERSIONS` line
(`RANDSTRUCT_FULL` selects it back — verified); ~30 lines restate origin
values verbatim — keep as drift canaries. (3) Ordering hazard: fragments
must concatenate *after* origin; reversed concatenation silently
resurrects HIBERNATION, TIPC, BINFMT_MISC. The candidate's one genuine
operational virtue is having no such hazard.

**5. VERDICT CONFIDENCE: high** — both pairings were resolved through the
real 6.6 tree's kconfig with a clang toolchain, proving value-equivalence
and exposing the structural drift/guarantee differences that decide the
winner.

</details>
