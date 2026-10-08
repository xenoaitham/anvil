# 2026-10-09 — vehicle root causes (attempts 004/005)

## Problem
No 6.6 GKI kernel (fragments or not) reached `sys.boot_completed` on the
Android 17 image (build 16373615). Two independent userspace-compat gaps in
the boot vehicle, both reproduced on the CLEAN control (zero fragments):

### Gap 1 — missing DMA-BUF system heap (kernel config)
- Origin `arch/x86/configs/gki_defconfig` (android15-6.6 @ c905c29016dd) has
  `CONFIG_DMABUF_HEAPS=y` but NOT `CONFIG_DMABUF_HEAPS_SYSTEM=y`; the 6.12
  image kernel has the heap set.
- Without `/dev/dma_heap/system` the image's
  `android.hardware.graphics.allocator-service.minigbm` exits 1 at startup →
  the recurring console spam "Could not find
  'aidl/android.hardware.graphics.allocator.IAllocator/default'".
- The composer then hits an UNCHECKED null:
  `GuestFrameComposer::onDisplayCreate` assigns
  `displayInfo.swapchain = DrmSwapchain::create(...)` (nullptr on failure)
  and immediately calls `displayInfo.swapchain->getNextImage()`
  (device/generic/goldfish/hals/hwc3/GuestFrameComposer.cpp) → SIGSEGV
  SEGV_MAPERR @0x18, crash loop, surfaceflinger SIGABRT, no boot.
- Logcat marker: `RanchuHwc: create: Failed to allocate drm ahb`.
- Tombstone captured on the stockgpu run (composer3-service.ranchu).
- FIX (config-only, boot-vehicle class): `CONFIG_DMABUF_HEAPS_SYSTEM=y` in
  the FIXED preamble of `bisect-build.sh`.

### Gap 2 — kernel SELinux predates the memfd_class policycap (kernel feature)
- The image's libcutils `__use_memfd()` (system/core/libcutils/ashmem-dev.cpp)
  requires `access("/sys/fs/selinux/policy_capabilities/memfd_class")` to
  succeed, else it falls back to the `/dev/ashmem<boot_id>` compat devnode.
- 6.6 SELinux knows policycaps only up to `POLICYDB_CAP_IOCTL_SKIP_CLOEXEC`
  (security/selinux/include/security.h) — `memfd_class` is a 6.7+ policycap.
  The compat devnode open is DENIED by the image policy
  (`avc: denied { open } ... tcontext=u:object_r:ashmem_libcutils_device:s0
  tclass=chr_file permissive=0`) →
  `java.lang.RuntimeException: Failed to create ashmem: Permission denied`
  → system_server/zygote fatal loop.
- The same denial exists in the 6.12 console (benign there: memfd is used).
- FIX (guest property, no kernel change): `setprop sys.use_memfd 1` —
  `__use_memfd()` honors this override BEFORE the capability check; set via
  adb root immediately after adb comes up (bisect-boot.sh, VEHICLE FIX 2/2).

## Result
`stockgpu-heap` = stock x86_64 gki_defconfig + FIXED preamble (virtio/GPU
built-ins + `DMABUF_HEAPS_SYSTEM=y`, INIT_ON_FREE off) + `sys.use_memfd=1`:
**`sys.boot_completed=1` at t=786 s** (adb getprop; boot console
`20261009-vehicle-fix/boot-console-stockgpu-heap.log.gz`). Zero fragments.
The vehicle was never proven for 6.6 before this run; every earlier "clean
boot" (2026-09 t=173s, 2026-10-08 attempt 000) was a GPU-less/heap-less
crawl.

## Why the fragment-crash claims change
- Attempt 003 (exact #4 config, bit-identical `.config.anvil-ref`): no kernel
  crash in 900 s. Attempt 005's clean control also passes the 10–15 s window.
  The 2026-09 rcuop/2 + #DF signatures were build-dependent (RANDSTRUCT/
  layout seeds differ per build) — they do NOT deterministically reproduce
  from the committed config on this toolchain today.
- The ashmem EACCES seen on attempt 003 was THIS vehicle gap (gap 2), not a
  fragment effect: the clean control reproduces it exactly.
