# kernel-gki patches — upstream candidates against AOSP kernel/common

Drafts for submission to AOSP (`android15-6.6` / `common`). See
`ISSUE.md` for the filing procedure and paste-ready issue body. None of
these are integrated into the Anvil fragment set (`hardening/kernel/`) —
they are boot-vehicle fixes proposed upstream, orthogonal to hardening
fragments by design.

| # | patch | evidence | status |
|---|---|---|---|
| 0001 | `0001-ANDROID-x86_64-gki_defconfig-enable-DMABUF_HEAPS_SYSTEM.patch` | attempts 004/005 (2026-10-09), single-line causal pair, `results/cuttlefish/20261009-vehicle-fix/` | draft; applies clean to c905c29016dd (`git apply --check` 2026-10-09); needs Gerrit credentials to file |

Discipline (same as `../platform/`): every patch cites captured runs;
claims name the vehicle deviations separately from fragment content;
placeholder `Bug:`/`Signed-off-by` must be replaced at submission time.
