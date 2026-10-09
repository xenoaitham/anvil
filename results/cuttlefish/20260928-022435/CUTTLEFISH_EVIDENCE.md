# Cuttlefish campaign — self-built android-common kernel with Anvil fragments

Campaign window: 2026-09-28 02:24 → 2026-09-29 02:40 UTC (local machine,
12-core x86_64, 15 GiB RAM, KVM). Everything below is quoted from captured
raw files in this directory and its siblings; nothing is from memory.

## §1 — What was built

- **Kernel:** AOSP `kernel/common`, branch `android15-6.6`, shallow clone,
  HEAD `c905c29016dd2dbf8df45e7c0287455f67ef165b`
  (`kernel-head.txt`). Built with Ubuntu clang 18.1.3 + LLD 18.1.3, `LLVM=1`,
  `KCONFIG_CONFIG=.config.anvil` (`logs/build-kernel*.log`, final
  `BUILD_EXIT=0` in `logs/build-kernel-resume2.log`).
- **Config:** the stock Cuttlefish x86_64 kernel config as merge base
  (extracted from the image's own kernel via its embedded config —
  `stock/stock-kernel.config`), then the Anvil fragments merged with
  kbuild's own merger — `scripts/kconfig/merge_config.sh -m <base>
  base.cfg arch-x86_64.cfg` → `olddefconfig`
  (`logs/merge-fragment.log`, `logs/olddefconfig.log`, merged result
  committed as `anvil-merged-kernel.config` /
  `anvil-merged-kernel-last.conf`).
- **Boot vehicle:** public Android CI build `16373615`
  (`aosp_cf_x86_64_only_phone-userdebug`, Android 17 / sdk 37 — the newest
  public build whose artifacts were still live; the Android 15-era branches
  had zero public builds and aosp-main's older large artifacts were purged —
  see `pairing-notes.md` and `stock/` captures). GKI backward compatibility
  is the pairing rationale: Android userspace must run on older GKI kernels.

## §2 — Integration deviations (all documented, fragment lines untouched)

1. **Boot-critical virtio stack built in** (`VIRTIO_PCI/BLK/NET/CONSOLE`,
   `HW_RANDOM_VIRTIO`, `VIRTIO_INPUT`, `VIRTIO_VSOCKETS`, `FAILOVER`,
   `NET_FAILOVER` =y): the stock CF kernel loads its virtual-device modules
   from a vendor_boot ramdisk built against 6.12; a 6.6 kernel cannot use
   those blobs (vermagic), and first-stage init's module loading of the
   6.6-built module set did not complete in-guest (see §5), so the drivers
   first-stage mount depends on are linked in. Recorded in
   `module-deviation.md`.
2. **`INIT_ON_FREE_DEFAULT_ON=n` in the final boots** (`anvil-merged-kernel-last.conf`):
   excluded after it was implicated in a guest memory crash (§5, step 3).
   `INIT_ON_ALLOC_DEFAULT_ON=y` stays. The exclusion is boot-vehicle-specific
   and is not a fragment change upstream of this campaign.
3. **Rootless cuttlefish harness** (`anvil-cf/` outside the repo): the host
   has no cuttlefish-base deb and no passwordless sudo, so `cvd` runs under
   `LD_PRELOAD` shims (`hostshim.c/.so`: cvdnetwork group lookup → the
   process's own gid; deb-only capability probe → true) inside a
   `unshare -Urn` user+net namespace (CAP_NET_ADMIN in-ns is what TAP
   creation needs; /dev/kvm access comes from the node's ACL). The stock
   kernel boots fully under this harness (§4), which is the control that
   validates it.
4. **2026-10 boot-vehicle fixes (attempt-class: NOT fragment content).**
   Round 2 added, all on the FIXED preamble/vehicle side: `DRM_VIRTIO_GPU`
   built-in (6.6 gets no driver otherwise — `gpu-y`), `DMABUF_HEAPS_SYSTEM=y`
   (allocator HAL requires `/dev/dma_heap/system`; upstream draft
   `patches/kernel-gki/`), `PSTORE_RAM` off under forced lockdown
   (`ramoops-n`; see `../20261009-anvil-crash/`), and `sys.use_memfd=1`
   for the 6.6 `memfd_class` gap — originally set by an adb race
   (attempts 005–009), then made deterministic (attempt 011, t=96 s, zero
   ashmem deaths, no adb involved): the prop is baked into the generic
   ramdisk `build.prop` of an AVB-re-signed `init_boot` copy
   (`--init_boot_image`), because the init_boot ramdisk extracts after the
   vendor pieces in the guest initrd and wins the cpio last-write race
   (the initramfs-overlay-only variant, attempt 010, loses that race and
   fails — kept as the negative control). Full forensics:
   `../20261009-memfd-bake/FINDINGS.md`.

## §3 — Boot progress of the Anvil-fragment kernel (captured, quoted)

The fragment kernel (6.6.142-gc905c29016dd, config = stock CF x86_64 GKI +
base.cfg + arch-x86_64.cfg + §2 deviations) **boots and executes into
Android userspace** on cuttlefish. From the full serial console
(`custom/boot-hardening-lines.txt`, raw segment
`custom/boot-console-anvil-initonfree.log`):

```
[    0.000000] Linux version 6.6.142-gc905c29016dd (potato@pop-os) (Ubuntu clang version 18.1.3 ...
[    0.000000] Kernel is locked down from Kernel configuration; see man kernel_lockdown.7
[    0.203335] mem auto-init: stack:all(zero), heap alloc:on, heap free:off
[    0.340333] Spectre V2 : Mitigation: Enhanced / Automatic IBRS
[    3.649081] init: init first stage started!
[    3.649494] init: Release specific kernel module dir 6.6.142-gc905c29016dd found, loading modules from here with no fallbacks.
     ... first-stage ext4 mounts of system/vendor partitions succeed ...
[   15.152989] servicemanager: Caller(pid=741,uid=1041,sid=u:r:audioserver:s0) Found android.hardware.audio.core.IModule/default
```

Hardening observables live on the running system at boot (full extraction:
`custom/boot-hardening-lines.txt`): lockdown LSM in confidentiality mode
(three distinct enforcement messages), init-on-alloc + full stack zeroing,
the complete x86_64 mitigation set (IBRS/eIBRS, BHI SW clearing, MMIO stale
data, Retbleed, GDS-dependent, Spectre v1 usercopy barriers), KASLR
(physical+virtual+memory). These lines come from the running kernel's own
console, not from config files.

## §4 — The late-boot crash, and the controls that attribute it

> **STATUS UPDATE 2026-10-09 — superseded by later evidence, kept as the
> record of what was believed on 2026-09-28.** Round 2 of the campaign
> (see `../20261008-campaign/`, `../20261009-vehicle-fix/`,
> `../20261009-boot-completed/`) root-caused the "fragment crash":
> (a) two 6.6-vs-image gaps reproduce on the CLEAN control (missing
> `CONFIG_DMABUF_HEAPS_SYSTEM=y`; 6.6 SELinux predating the `memfd_class`
> policycap) — the old "clean boot" controls never reached
> `sys.boot_completed` either, they crawled GPU-less;
> (b) the exact #4 config rebuilt on today's toolchain does **not** crash
> in the 10–15 s window at all (bit-identical config, 900 s clean) — the
> window crash was build-dependent;
> (c) a genuine fragment-vehicle interaction was found and fixed
> (`LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY` rejects the crosvm
> `ramoops.mem_address` module_param_hw → pstore console bound to phys 0 →
> #PF at t=17 s; fixed by `# CONFIG_PSTORE_RAM is not set` on this vehicle,
> forced lockdown kept); and
> (d) with those three items, **the full fragment set reaches
> `sys.boot_completed=1` at t=103 s** with the hardening posture verified
> live (`../20261009-boot-completed/`). The original text below stands as
> the honest state of 2026-09-28.
>
> **INIT_ON_FREE x86_64 policy — decided 2026-10-09.** Attempt 008
> (`../20261009-initonfree-confirm/`) then attempt 009 (final set) showed
> the 2026-09 swap-corruption signature does **not** reproduce on today's
> toolchain even with `INIT_ON_FREE_DEFAULT_ON=y` (BOOT_COMPLETED t=103 s
> both runs, zero swap-corruption lines). Not reproduced is not
> root-caused: the only causal account on file is the build-era
> hypothesis (per-build RANDSTRUCT/layout seed inputs), which is
> unverified and identifies no mechanism; the original build environment
> that produced the signature is not reconstructable, so an instrumented
> repro is not available — there is nothing to instrument until something
> reproduces. The 2026-09 signature was kernel memory corruption
> ("Bad swap file entry" flood → page fault in `zap_huge_pmd` → init
> killed) — precisely the failure class the free-path zeroing setting can
> perturb, via page content/timing on the free path. **Policy: x86_64
> boot vehicles in this campaign keep `INIT_ON_FREE_DEFAULT_ON=n`** (the
> FIXED preamble), and the exclusion lifts only when either (a) the
> signature is reproduced under instrumentation and root-caused — showing
> INIT_ON_FREE innocent or the cause fixed — or (b) a bounded soak passes
> on the toolchain of record (≥ 3 consecutive full boots plus sustained
> post-boot runtime with the setting on). The line itself stays in the
> fragment set: it is GrapheneOS-authored (7749342e2592), it is the
> arm64 target's default, and this exclusion is a vehicle/build-provenance
> gate, not a fragment change.

The fragment kernel never reaches `sys.boot_completed`: every attempt dies
in the 10–15 s service-start window, with two signatures:

1. **With `INIT_ON_FREE_DEFAULT_ON=y`** (first built kernel, `#3`):
   `get_swap_device: Bad swap file entry` flood, then
   `BUG: unable to handle page fault` in `zap_huge_pmd`, init killed →
   `Kernel panic - not syncing: Attempted to kill init!`
   (`boot-console-anvil-initonfree.log` — the captured segment contains the
   swap-corruption flood and init's progress up to the service storm).
2. **With `INIT_ON_FREE=n`** (rebuild, `#4`): later, but still in the same
   window — `BUG: #DF stack guard page was hit` (kernel stack overflow)
   (`boot-console-anvil-nofree.excerpt.log` — excerpt; the full console was
   lost when the instance dir was reused by the control run).

Controls, all under the identical namespace harness:

| Control | Kernel | Result |
|---|---|---|
| stock image kernel | 6.12.74-android16 (from the image) | **`sys.boot_completed=1` at t=28 s** (`stock/ns-control/`) |
| same source tree, **pure stock x86_64 gki_defconfig** (no fragments; only the §2 virtio built-ins) | 6.6.142-gc905c29016dd `#5` | **clean boot past t=173 s**, deep in Android init, zero panics (`stockcfg-control/`) |
| Anvil fragments | 6.6.142 `#3`/`#4` | crash at t≈10–15 s, every attempt |

**Verdict forced by the controls:** the environment (namespace harness,
crosvm, Android 17 pairing) is sound — the stock 6.12 kernel fully boots
under it, and the *same 6.6 source tree* with the *same userspace pairing*
boots clean without the fragments. The late-boot crash is **attributed to
the Anvil fragment content (base.cfg and/or arch-x86_64.cfg) on x86_64
android15-6.6 GKI**. Which fragment line is responsible is NOT yet
bisected — that requires further boot cycles than this volume could hold
(§6).

This is a real finding about the x86_64 layer and it is recorded, not
hidden: GrapheneOS ships this hardening set on arm64 Pixels from their own
tree; nothing here makes any claim about arm64, and nothing transfers to
hardware claims.

## §5 — Known-honest limits of this campaign

> **STATUS UPDATE 2026-10-09:** the two headline limits below are now
> resolved — `sys.boot_completed=1` at t=103 s with a 42-file adb posture
> dump (`../20261009-boot-completed/`), and the fragment-crash attribution
> corrected (see the §4 status block). The INIT_ON_FREE exclusion and the
> t=173 s control-crawl notes remain accurate for the vehicles they were
> recorded on; the re-confirm ran (attempts 008/009, BOOT_COMPLETED, zero
> swap-corruption lines) and the x86_64 retention policy is decided —
> keep the exclusion on x86_64 vehicles until the 2026-09 signature is
> root-caused or a bounded soak passes; see the §4 policy block.

- **No `sys.boot_completed` with fragments**; therefore no adb-level runtime
  probes (dmesg_restrict behavior, %pK, lockdown sysfs, sysrq, hibernation
  sysfs). Hardening-symbol proof is limited to boot-time console observables
  (§3) plus the per-line config diff of the running kernel's merge base
  (`config-diff-stock-vs-anvil.txt`).
- **`INIT_ON_FREE_DEFAULT_ON` exclusion** applies to this boot vehicle only;
  it is a GrapheneOS-authored line (`7749342e2592`) that we carry verbatim,
  and it stays in the fragment set for arm64 targets.
- **The stock-config 6.6 control** was still mid-boot (t=173 s, no crash)
  when the campaign volume hit its floor; its log is committed as-is.
- **Disk exhaustion ended the campaign** (`ENOSPC` during image assembly,
  volume at 100% — the repo's honesty policy forbids faking past that).
- The hostshim/namespace harness is research tooling, not an integration
  path; its one validity control is §4's stock-kernel boot.

## §6 — How to resume

Configs are committed (`anvil-merged-kernel-last.conf`, and
`anvil-cf/kernel/config.anvil-last` for the exact last build); bzImages were
kept on the campaign volume (`bzImage-anvil-last`, `bzImage-stock-control`).
Next step when a volume with ≥ 60 GiB is available: rebuild (the two
`build-kernel-resume*.log` commands), then bisect base.cfg vs
arch-x86_64.cfg on the same harness (`evidence/boot-custom.sh`,
`evidence/boot-stockcfg.sh` in the campaign volume), then run
`evidence/run-probes.sh` for the full adb-level symbol pass.
