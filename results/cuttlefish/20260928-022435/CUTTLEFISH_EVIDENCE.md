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
