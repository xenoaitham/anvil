# 2026-10-09 — sys.use_memfd made deterministic (vehicle fix 2/2 v2)

## Goal

The Android 17 image's libcutils `__use_memfd()` needs `sys.use_memfd=1`
when the kernel lacks the `memfd_class` policycap (6.7+; 6.6 SELinux
predates it); without it system_server dies in the ashmem
"Permission denied" crash loop. Until today the prop was set by an **adb
race won by boot timing** (bisect-boot.sh setprop at adb-up). Objective:
bake it so the fix does not depend on adb coming up before
system_server.

## Attempt 010 — anvil-final-memfd (initramfs overlay only): FAILED, root-caused

Design: cuttlefish merges `--initramfs_path` content into the guest
ramdisk; a cpio carrying `system/etc/ramdisk/build.prop` (original
bootimage build.prop + appended `sys.use_memfd=1`) should override the
original by cpio last-write-wins.

Result: TIMEOUT t=902 s. system_server ashmem crash-loop (66 deaths in
the crash buffer; deaths stopped exactly when a manual test setprop
landed — the prop was absent all boot).

Root cause (all steps verified on the artifacts):
1. assemble_cvd merges the `--initramfs_path` cpio into the **vendor**
   ramdisk piece (`vendor_boot_repacked`, `ramdisk_repacked.cpio` =
   decoded piece B: our modules dir + our build.prop — the staged tree
   `ramdisk_staged/system/etc/ramdisk/build.prop` shows our file won the
   host-side merge).
2. The **init_boot generic ramdisk passes through verbatim** and the
   guest initrd = generic (~3 MB) + vendor piece A (17.2 MB, CF's
   composed ramdisk: `init`, fstabs, contexts, legacy `default.prop`,
   `prop.default`) + piece B (41.4 MB, ours) — size accounting matches
   the kernel's "Freeing initrd memory: 60168K" line exactly.
3. The generic ramdisk extracts **after** the vendor pieces → its
   ORIGINAL `system/etc/ramdisk/build.prop` overwrites ours (kernel
   initramfs extractor: later entry wins). First-stage init copied that
   original ("Copied ramdisk prop", t=0.82 s) → prop never set. Piece A
   itself carries no build.prop entry — the winning original lives in
   the ~3 MB generic segment (the file the overlay union was built from
   was extracted from `init_boot.img` directly).
4. Second-stage init loads the copied file via
   `/second_stage_resources` (tmpfs survives SwitchRoot by MS_MOVE);
   `PropertySetNoSocket` applies boot defaults without MAC checks — the
   load pipeline is sound; only the wrong file version defeats it.

## Attempt 011 — anvil-final-memfd2 (+ patched init_boot): BOOT_COMPLETED t=96 s

Fix: `patch-initramfs-prop.sh` rebuilds a COPY of `init_boot.img`
(`init_boot-anvil.img`; the pristine original is untouched) with the
union build.prop in its generic ramdisk, then re-signs with cuttlefish's
bundled AVB test key (`SHA256_RSA4096`, same salt and partition size as
the original — public-key sha1 `2597c218…` asserted against the bundled
key before signing). First rebuild without AVB was rejected by uboot
("init_boot_a: Error verifying vbmeta image: invalid vbmeta header",
attempt `anvil-final-memfd2` pre-sign run, console kept). The signed
image passes: descriptor digest re-verified independently
(`sha256(salt||raw)` = descriptor digest), uboot accepts, boots.

Launch: `--initramfs_path` (overlay kept as belt-and-suspenders) +
`--init_boot_image=…/init_boot-anvil.img` + `bzImage-anvil-final` (same
kernel bytes, symlink `bzImage-anvil-final-memfd2`), **MEMFD_VIA_ADB
unset — no adb setprop issued** (the harness gate now defaults off).

Result (`verdict-anvil-final-memfd2.txt`): **`sys.boot_completed` at
t=96 s** (anvil-final itself: t=92 s — same speed class). Live probe
(`probe-postboot.txt`, full dump `getprop-full.txt`):

- `sys.use_memfd=1` — set by boot-default load, before any service
- `sys.boot_completed=1`, Android 17
- kernel 6.6.142-gc905c29016dd, lockdown `none integrity
  [confidentiality]`, SELinux enforcing=1 — hardening posture unchanged
- ashmem deaths in crash buffer: **0** (`ashmem-deaths.txt`)

## Vehicle-deviation ledger update (supersedes "set at adb-up")

Vehicle fix 2/2 is now: `sys.use_memfd=1` baked into the generic ramdisk
build.prop of an AVB-re-signed `init_boot` copy (`init_boot-anvil.img`,
hash in `init_boot-anvil.img.sha256`), applied via `--init_boot_image`,
plus the same line in the campaign initramfs overlay. The adb setprop
path remains only as `MEMFD_VIA_ADB=1` for old artifacts. Class: boot
vehicle (no fragment change), like the GPU/heap preamble.

## Honest limits

- Verified on ONE boot (plus the failed first mechanism). The determinism
  claim rests on the mechanism (boot-default load precedes all services —
  AOSP init source, property_service.cpp `PropertyLoadBootDefaults`) plus
  this run's zero-death/t=96 s outcome, not on a multi-boot soak.
- `init_boot-anvil.img` is a build product, not a source: reproducible
  from the committed script + pristine `init_boot.img` +
  `ramdisk-overlay/system/etc/ramdisk/build.prop` (the overlay file is
  committed here as `ramdisk-overlay-build.prop`; the built image is
  hash-anchored in `init_boot-anvil.img.sha256` = `c5001ff4…`).
- The adb-race fix (005–009) remains valid for boots without the patched
  image; both mechanisms coexist.
