# 2026-10-09 — final hardened set (`anvil-final`): boot_completed at t=92 s

Composition (origin android15-6.6 x86_64 `gki_defconfig` @ c905c29016dd +
full Anvil fragment set + all three boot-vehicle deviation classes):

- `base.cfg` (22) + `arch.cfg` (4) + `residue.cfg` (109) — the fragments.
- FIXED preamble: virtio built-ins, `DRM_VIRTIO_GPU=y`,
  `DMABUF_HEAPS_SYSTEM=y`, INIT_ON_FREE excluded (§4).
- `ramoops-n` group: `# CONFIG_PSTORE_RAM is not set` (lockdown ×
  module_param_hw interaction; forced lockdown KEPT).
- `ioring-n` group: `# CONFIG_BLK_DEV_UBLK is not set` +
  `# CONFIG_IO_URING is not set` (blind-critic round-2 gap).
- Guest property `sys.use_memfd=1` (set at adb-up by the boot script).

Result: **`sys.boot_completed=1` at t=92 s** — fastest of the campaign
(veh2 103 s, initonfree 103 s, clean control 786 s). Full console
(`boot-console-anvil-final.log.gz`), verdict, resolved config.

Matrix of today's runs (all on the identical harness + image):

| run | set | INIT_ON_FREE | io_uring | result |
|---|---|---|---|---|
| stockgpu (004) | origin defconfig + FIXED only | off | on | composer SIGSEGV loop (no dma_heap) — vehicle gap 1 |
| stockgpu-heap (005) | + `DMABUF_HEAPS_SYSTEM=y` | off | on | BOOT_COMPLETED t=786 s (prop set mid-loop) |
| anvil-veh (006) | + full fragments | off | on | CRASH t=17 s — lockdown × ramoops (gap 3) |
| anvil-veh2 (007) | + `ramoops-n` | off | on | **BOOT_COMPLETED t=103 s** + posture dump |
| anvil-initfree (008) | + `initonfree` | **on** | on | BOOT_COMPLETED t=103 s, zero swap lines |
| anvil-final (009) | + `ioring-n` | off | **off** | **BOOT_COMPLETED t=92 s** |

The §4-era crash signatures (INIT_ON_FREE swap-corruption, 10–15 s window
crash) did not reproduce on any of today's builds from the committed
configs; they remain recorded for the 2026-09 toolchain/build.
