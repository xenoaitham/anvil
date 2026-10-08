# 2026-10-09 — `sys.boot_completed=1` on the Anvil kernel (attempt 007)

## The run

- Kernel: `bzImage-anvil-veh2` — origin android15-6.6 `gki_defconfig`
  (x86_64, @ c905c29016dd) + **the full Anvil fragment set**
  (`base.cfg` 22 lines + `arch.cfg` 4 lines + `residue.cfg` 109 lines)
  + three documented boot-vehicle deviations (FIXED preamble:
  virtio built-ins + `DRM_VIRTIO_GPU=y` + `DMABUF_HEAPS_SYSTEM=y`;
  `ramoops-n` group: `# CONFIG_PSTORE_RAM is not set`;
  guest property `sys.use_memfd=1`). `INIT_ON_FREE_DEFAULT_ON` stays
  excluded per CUTTLEFISH_EVIDENCE §4 (swap-corruption signature on the
  6.12-era vehicle; see below for today's status).
- Boot: identical rootless namespace harness (`unshare -Urn` +
  hostshim + crosvm), Android 17 image build 16373615,
  `--gpu_mode=guest_swiftshader`.
- Result: **`adb shell getprop sys.boot_completed` → `1` at t=103 s**
  (verdict file, serial console `boot-console-anvil-veh2.log.gz`).
  No kernel crash, zero Oops lines.

## Running-kernel posture (posture/ — 42 probe files, run-probes.sh)

| Observable | Value on the running kernel |
|---|---|
| `/sys/kernel/security/lockdown` | `none integrity [confidentiality]` — forced confidentiality ACTIVE |
| kfence sample_interval | 500 (KFENCE live) |
| `/sys/module/module/parameters/sig_enforce` | Y (MODULE_SIG_FORCE) |
| SELinux | Enforcing |
| `vm.mmap_rnd_bits` | 32 (fragment ARCH_MMAP_RND_BITS=32) |
| `/proc/sys/kernel/sysrq` | 0 (MAGIC_SYSRQ_DEFAULT_ENABLE=0x0) |
| `/dev/mem`, `/dev/port` | absent |
| binfmt_misc | absent (fragment) |
| TIPC | absent (fragment) |
| `/sys/power/disk` | absent (`# CONFIG_HIBERNATION is not set`) |
| `/sys/devices/system/memory/` | absent (`# CONFIG_MEMORY_HOTPLUG is not set`) |
| kmalloc caches | 234 (RANDOM_KMALLOC_CACHES) |
| `/proc/version` | 6.6.142-gc905c29016dd #6 SMP PREEMPT, clang 18.1.3 |

## Claim status this run flips

- The fragment kernel **does** reach `sys.boot_completed` on Cuttlefish.
- The running kernel demonstrably enforces the Anvil hardening posture
  above — the "no kernel validated" language is obsolete for this
  configuration.
- The 2026-09 crash attribution ("fragments crash every attempt in the
  10–15 s service-start window") is corrected: the crash was
  build-dependent (RANDSTRUCT/ABI seeds) AND the vehicle had two
  independent 6.6-compat gaps (see `20261009-vehicle-fix/FINDINGS.md`).
  With those fixed and the ramoops/lockdown interaction neutralized,
  the same fragment set boots to completion.

## What changed vs the crashing set — honest statement

Three kernel-config deviations beyond the fragments, all boot-vehicle
class (required for ANY 6.6 kernel to boot this image, fragment or not):

1. `CONFIG_DRM_VIRTIO_GPU=y` (built-in GPU) — vendor early-init requires
   /dev/dri/card0; modules can't be loaded from a repacked ramdisk here.
2. `CONFIG_DMABUF_HEAPS_SYSTEM=y` — origin x86_64 gki_defconfig omits it;
   the image's minigbm allocator HAL requires /dev/dma_heap/system.
3. `# CONFIG_PSTORE_RAM is not set` (ramoops-n group) — crosvm passes
   `ramoops.mem_address` on the cmdline; a module_param_hw rejected under
   forced lockdown leaves ramoops bound to phys 0x0 → guaranteed #PF
   (attempt 006, console committed). Keeping ramoops would require
   weakening forced lockdown or a kernel source change; neither serves
   Anvil's goals on this vehicle.
Plus the guest-side property `sys.use_memfd=1` (no kernel change): 6.6
SELinux predates the `memfd_class` policycap; without the override the
image's libcutils takes a policy-denied /dev/ashmem compat path and
system_server dies (reproduced on the clean control).

## Follow-ups queued

- `INIT_ON_FREE_DEFAULT_ON=y` re-confirm on today's toolchain (one boot,
  full console) — the §4 swap-corruption signature was never reproduced
  post-reconstruction.
- Builder + blind harsh critic review of the fragment set vs the origin
  gki_defconfigs (labels stripped), per campaign protocol.
