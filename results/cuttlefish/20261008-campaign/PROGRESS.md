# Cuttlefish bisect campaign — 2026-10-08 (round 2)

Goal: make the Anvil fragment kernel reach `sys.boot_completed` on Cuttlefish
(Android 17 image, build 16373615), under the identical rootless namespace
harness the 2026-09 campaign validated. Live page: repo `progress/index.html`.

## Environment incidents (documented per the honesty policy)

- ~22:20 the campaign tree `/home/potato/anvil-cf` was deleted by an external
  disk-cleanup process on this machine (not by this campaign; free space also
  jumped elsewhere in /home, docker images pruned). Everything was
  reconstructed: kernel source re-fetched at the exact pinned commit
  `c905c29016dd`, Android CI artifacts re-downloaded at byte-identical sizes
  (host package 898,832,913 B; img zip 1,163,638,742 B; same build 16373615 =
  identical Android 17 pairing), toolchain debs re-fetched at the same
  versions (libelf 0.190-1.1ubuntu0.1, dwarves 1.25, libzstd 1.5.5), and all
  campaign scripts rewritten identically (now mirrored under `scripts/`).
  The repo (this directory) is the protected mirror; evidence is committed
  per attempt.
- `/mnt/NewVolume` is mounted read-only (fuseblk): the SDK there is reusable
  read-only; builds run in-tree (identical to the 2026-09 environment).

## Attempt ledger

| # | kernel | config | result |
|---|--------|--------|--------|
| 000 | stock-control 6.6 (committed bzImage-stock-control) | `.config.stock` | **TIMEOUT 600s, no crash, no boot_completed** — vendor early-init `wait /dev/dri/card0` fails; `vendor.graphics.allocator` exits 1; service storm crawls (`20261008-phase0/boot-console-ctrl66.log`) |
| 001 | anvil #4 (committed bzImage-anvil-last) | `.config.anvil` (INIT_ON_FREE=n) | **CRASH t=9.77s** — reproduced. Primary: `rcuop/2` in `rcu_do_batch` → `rcu_cblist_dequeue` dereferences unmapped direct-map pointer `ffff904b00000ff4`; then hardened-usercopy abort; panic (`20261008-phase0/boot-console-anvil-ctl.log`) |
| 002 | control + GPU=y (rebuilt #6) | `.config.stock` + FIXED(GPU=y) | **GPU live at t=0.7s**, services storm faster — BUT `vendor.hwcomposer-3` SIGSEGVs from t=9.4s, `system_server` crash-loops (~80 deaths by t=300s) → no boot_completed (console lost with the tree deletion; verdict + key lines in git history/progress page) |
| 003 | anvil-ref: exact #4 config rebuilt post-reconstruction | `.config.anvil-ref` — **bit-identical** to committed `.config.anvil` (empty `diff`), GPU=m, INIT_ON_FREE=n | **NO kernel crash in 900 s** (kernel alive at t=845s; zero Oops/#DF/rcuop lines). First stage passed (`Release specific kernel module dir found`, no sig rejections). Userspace failure instead: `system_server` died once at t≈93 s (`ashmem_create_region: Permission denied`, no matching avc — non-SELinux EACCES), zygote restart-loop, no boot_completed. No modules ended up loaded (`/proc/modules` empty — repacker splits the initramfs module dir into dlkm partitions), so still no `/dev/dri/card0` (`20261009-anvilref/boot-console-anvil-ref.log.gz`) |
| 004 | stockgpu control (no fragments) | `.config.stock` + FIXED(GPU=y) | composer SIGSEGV loop (tombstone: `DrmSwapchain::create()==nullptr` deref) — **reproduces without fragments**: vehicle gap, `logcat` "Failed to allocate drm ahb" (`20261009-vehicle-fix/`) |
| 005 | stockgpu-heap | + `CONFIG_DMABUF_HEAPS_SYSTEM=y` | **`sys.boot_completed=1` t=786 s** (with `sys.use_memfd=1` set mid-loop) — vehicle fully solved on the CLEAN control (`20261009-vehicle-fix/`) |
| 006 | anvil-veh | full fragments + vehicle fixes | **CRASH t=17 s** — `LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY` rejects crosvm's `ramoops.mem_address` (module_param_hw) → pstore console bound to phys 0 → `memcpy_toio` #PF (`20261009-anvil-crash/`) |
| 007 | anvil-veh2 | + `ramoops-n` (PSTORE_RAM off, lockdown kept) | **`sys.boot_completed=1` t=103 s** + 42-file live posture dump (`20261009-boot-completed/`) — **campaign goal** |
| 008 | anvil-initfree | + INIT_ON_FREE=y (initonfree) | **BOOT_COMPLETED t=103 s**, zero swap-corruption lines — §4 signature was build-era-specific (`20261009-initonfree-confirm/`) |
| 009 | anvil-final | + `ioring-n` (IO_URING+BLK_DEV_UBLK off, blind-critic gap) | **BOOT_COMPLETED t=92 s** — fastest; final hardened set (`20261009-final/`) |
| 010 | anvil-final-memfd (same kernel bytes, memfd overlay in initramfs only) | anvil-final + ramdisk-overlay | **TIMEOUT t=902 s** — overlay loses the cpio last-write race to the init_boot generic ramdisk (extracts after the vendor pieces); system_server ashmem loop, 66 deaths; root-caused to ramdisk-piece ordering (`20261009-memfd-bake/FINDINGS.md`) |
| 011 | anvil-final-memfd2 | + patched init_boot (`init_boot-anvil.img`: union build.prop in the generic ramdisk, AVB re-signed with the CF test key) | **BOOT_COMPLETED t=96 s, `sys.use_memfd=1` from boot defaults, 0 ashmem deaths, NO adb setprop issued** — vehicle fix 2/2 is deterministic (`20261009-memfd-bake/`) |

Blind review round 2 (fresh-context critic, labels stripped, both pairings
resolved through real kconfig): **WINNER = the Anvil fragment set**; gap
(IO_URING) acted on and verified by attempt 009. `20261009-review-round2/REVIEW.md`.

## Session 2026-10-09 (follow-up): objectives 1/2/3/4/6 closed

- Obj 1: INIT_ON_FREE x86_64 retention policy written into
  `20260928-022435/CUTTLEFISH_EVIDENCE.md` §4 (exclusion stays until
  root-caused under repro, or a bounded soak passes; line remains in the
  fragment set for arm64).
- Obj 2: upstream draft committed at `patches/kernel-gki/` (patch applies
  clean to c905c29016dd; ISSUE.md paste-ready; filing needs Gerrit
  credentials). FINDINGS 6.12-heap claim corrected (dated note).
- Obj 3: BPF_UNPRIV keep=n decided (documented); dead-letter MODVERSIONS
  line dropped (byte-identical 7575-line olddefconfig proof,
  `20261009-round2-followup/`); merge-order requirement documented in
  `hardening/kernel/README.md` (reversed-merge resurrection demonstrated).
- Obj 4: attempts 010/011 — `sys.use_memfd` now baked (attempt 010
  initramfs-only FAILS as negative control; attempt 011 patched+AVB-signed
  init_boot: BOOT_COMPLETED t=96 s, prop from boot defaults, 0 ashmem
  deaths, no adb). `20261009-memfd-bake/FINDINGS.md`.
- Obj 6: `20261009-release/RELEASE.md` — canonical bzImage sha256 table;
  archive decision: repo is the primary record, `anvil-cf` stays in place.

### Obj 5 (arm64 parity) — blocked, readiness state

System volume at 99% (8.3 GiB free as of this note) — below this
campaign's own 8 GB pre-build df_guard and far under the ~60 GiB resume
floor CUTTLEFISH_EVIDENCE §6 calls for. An arm64 build plus an arm64
cuttlefish image set cannot fit; starting it would end the campaign the
way 2026-09 did (ENOSPC at the volume floor). Prerequisites for the next
session: (a) ≥ 60 GiB free on the build volume, (b) arm64 CF pairing
downloaded (aosp_cf_arm64-only image set, build 16373615 or newer),
(c) then: arm64 gki_defconfig + FIXED preamble (virtio/GPU/heap/memfd
vehicle class, INIT_ON_FREE=y ON — it is the arm64 target's default) and
the boot/posture matrix as in attempts 007–009.

## Findings so far (updated 2026-10-09)

0. **The vehicle wall is missing `/dev/dri/card0`, and it hits every 6.6 boot
   so far** — including the clean control (attempt 000) and anvil-ref (003).
   The Android 17 image's graphics allocator HAL cannot start without a DRM
   device, and no 6.6 kernel in this campaign has delivered one: GPU=m needs
   modules that the repacker strips from the ramdisk; GPU=y (attempt 002)
   had card0 but then `drm_hwcomposer` SIGSEGV'd. Attempt 004 (stockgpu
   control: stock defconfig + GPU built-in, zero fragments) discriminates:
   if it boots → hwcomposer SIGSEGV was fragment-caused and the vehicle is
   solved; if it SIGSEGVs the same way → the Android 17 image's composer is
   incompatible with 6.6 virtio-gpu as such.

1. **GPU is mandatory for `sys.boot_completed` on any 6.6 kernel here.** The
   6.12 stock kernel loads `virtio-gpu.ko` from its first-stage ramdisk
   (20260928 stock/ns-control). A 6.6 kernel gets no driver: first-stage
   loads no modules, /vendor modules are 6.12-built (vermagic), and
   `MODULE_SIG_FORCE` would reject 6.6-built modules too. The old "control
   boots clean past t=173 s" was a crawl, not a boot. All campaign kernels
   build `DRM_VIRTIO_GPU=y` (documented deviation; `gpu-y.cfg`).
1b. **Module loading from a custom initramfs is silently neutralized by the
   assembly repacker** (`SplitRamdiskModules`): the versioned
   `/lib/modules/<release>/` dir survives first stage (init logs "found ...
   no fallbacks") but the .ko files are split into vendor_dlkm/system_dlkm
   staging and never load at runtime under this harness (`/proc/modules`
   empty in attempt 003). Consequence: kernel-internal GPU/m module paths
   are unusable here; anything boot-critical must be built-in (`=y`).
2. **With GPU built-in, the image's `drm_hwcomposer` APEX SIGSEGVs against
   the 6.6 kernel** (userspace from the Android 17 image vs 6.6 virtio-gpu
   KMS) and takes system_server down in a crash loop — open problem; the
   GPU-less boot keeps system_server healthy (0 crashes in 600s) but never
   finishes its service storm. Long-timeout GPU-less control experiment is
   queued (bisect variant `gpu-n.cfg`).
3. **The fragment-crash signature is RCU-callback corruption**, not primarily
   stack overflow: the #DF/guard-page lines in the 2026-09 captures are
   downstream. The primary fault is inside the RCU nocb offload path
   (`rcu_nocb_cb_kthread` → `rcu_do_batch`). Residue delta includes
   `CONFIG_RCU_NOCB_CPU_DEFAULT_ALL=y` + `RCU_LAZY` unpinned (inherited from
   the 6.12 image config; the 6.6 gki control pins `RCU_LAZY_DEFAULT_OFF=y`).
   Prime suspect for the group bisect.
4. Bisect machinery: `.config.stock` + FIXED preamble (virtio built-ins +
   GPU=y + INIT_ON_FREE=n) + verified delta groups reproduces
   `.config.anvil` exactly, modulo the two intended GPU-fix lines
   (`verify-groups.sh` output quoted in the attempt log).

## Scripts (mirrored under scripts/)

`cf-env.sh` (env + disk guards + fresh-console grab), `bisect-build.sh`
(config apply + olddefconfig + in-tree build), `bisect-boot.sh` (boot under
`unshare -Urn`, full console capture, crash + `VIRTUAL_DEVICE_BOOT_COMPLETED`
detection, teardown), `gen-groups.py` + `verify-groups.sh` (delta machinery),
`make-configs.sh` (config reconstruction), `make-initramfs.sh`,
`update-progress.py` (live page).
