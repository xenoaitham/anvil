# Upstream issue draft — cuttlefish/android15-6.6 pairing needs DMABUF_HEAPS_SYSTEM

Status 2026-10-09: **draft, not yet filed.** Filing requires AOSP Gerrit /
Issue Tracker credentials that this environment does not have. Everything
below is ready to paste; the patch next to this file applies cleanly to
android15-6.6 @ `c905c29016dd2dbf8df45e7c0287455f67ef165b`
(`git apply --check` verified 2026-10-09).

## Where to file

1. **Preferred:** Gerrit CL against `kernel/common` (`android15-6.6`
   branch) — defconfig-only change, reviewable as a one-liner. Attach the
   patch; keep the commit message from the patch header (drop the
   placeholder `Bug:`/`Signed-off-by` only after replacing them).
2. Alternative/parallel: Android Issue Tracker under Components →
   Android → Kernel / Cuttlefish, referencing the CL.

## Issue body (paste-ready)

**Title:** cuttlefish cannot boot android15-6.6 GKI without
CONFIG_DMABUF_HEAPS_SYSTEM=y (missing from x86_64 gki_defconfig)

**Body:**

`arch/x86/configs/gki_defconfig` on android15-6.6 enables the dma-buf
heap framework (`CONFIG_DMABUF_HEAPS=y`) and two heap helper libraries
(`DMABUF_HEAPS_DEFERRED_FREE`, `DMABUF_HEAPS_PAGE_POOL`) but not the
system heap (`CONFIG_DMABUF_HEAPS_SYSTEM`), so `/dev/dma_heap/system`
never exists. AOSP's own cuttlefish pairing then fails to boot:

- Repro: build android15-6.6 @ `c905c29016dd2dbf8df45e7c0287455f67ef165b`
  with x86_64 `gki_defconfig` (+ the virtio/GPU built-ins cuttlefish
  needs on 6.6, since 6.12-built vendor modules cannot load on a 6.6
  kernel), boot `aosp_cf_x86_64_only_phone` CP2A.260605.016 (build
  16373615) under cuttlefish.
- Failure chain (captured, serial console + tombstone):
  `android.hardware.graphics.allocator-service.minigbm` exits at startup
  without `/dev/dma_heap/system` →
  `android.hardware.graphics.allocator.IAllocator/default` is never
  registered → the hwc3 composer (`GuestFrameComposer::onDisplayCreate`,
  device/generic/goldfish) assigns `displayInfo.swapchain =
  DrmSwapchain::create(...)` (null on failure) and immediately calls
  `displayInfo.swapchain->getNextImage()` → SIGSEGV SEGV_MAPERR crash
  loop → `sys.boot_completed` never reached (TIMEOUT t=1204 s).
- Fix: `CONFIG_DMABUF_HEAPS_SYSTEM=y` — one resolved-config line
  (verified by diffing the two full resolved `.config`s). With it, the
  identical build reaches `sys.boot_completed=1` at t=786 s.
- Notes: `DMABUF_HEAPS_SYSTEM` help text says "If in doubt, say Y";
  Android userspace broadly uses the system heap for CPU-accessible
  buffers. `arch/arm64/configs/gki_defconfig` has the same omission —
  not demonstrated there (x86_64-only evidence), but likely worth the
  same one-liner.

## Evidence provenance (campaign-internal)

- Attempt 004 (`stockgpu`, config without the heap) vs attempt 005
  (`stockgpu-heap`, config with the heap): configs committed at
  `results/cuttlefish/20261009-vehicle-fix/config.stockgpu{,-heap}`
  — `diff` = exactly the one line; verdicts
  `verdict-stockgpu{,-heap}.txt`; consoles `boot-console-stockgpu{,-heap}.log.gz`;
  narrative in the same dir's `FINDINGS.md`.
- Corrected claim (2026-10-09): the Android 17 image's 6.12 kernel also
  has the system heap OFF (`stock/stock-kernel.config` line 5668,
  `# CONFIG_DMABUF_HEAPS_SYSTEM is not set`) and its allocator still
  starts — the 6.12 pairing boots via some path that does not require
  the node (mechanism not established from our captures; we did not
  probe /dev on the 6.12 guest). The issue therefore claims the 6.6
  requirement, which is single-line-proven, and does NOT claim the
  6.12 pairing is broken. FINDINGS.md originally asserted the 6.12
  kernel "has the heap set" — corrected there with a dated note.
