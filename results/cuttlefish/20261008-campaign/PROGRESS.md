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
