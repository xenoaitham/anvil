# Anvil kernel hardening fragments

Layered Linux kernel hardening config fragments for non-Pixel Android
devices, ported from GrapheneOS's actual kernel tree. Every non-comment line
in every fragment is traced to that tree — either to a specific
GrapheneOS-authored commit or to the carried AOSP GKI baseline state of their
`gki_defconfig` — and validated against the real Kconfig definitions of the
pinned branch by `tools/kernelconfig/check.py`. Nothing here is from memory.

## Source of truth

- **Tree:** `GrapheneOS/kernel_common-6.6`, branch `17` (their default),
  head `f97a55ff191d` (2026-09-14). This is the tree their own devices build
  from; the branch is a fork of AOSP `android15-6.6`.
- **Files:** `arch/arm64/configs/gki_defconfig` and
  `arch/x86/configs/gki_defconfig` — GrapheneOS keeps a single defconfig per
  arch for all SoC families; they do not use a fragment system themselves.
- **Provenance classes** (also recorded per symbol in `MANIFEST.yaml`):
  - `GOS <sha>` — commit authored by GrapheneOS (Daniel Micay, flawedworld)
    touching their gki_defconfig. This is their deliberate hardening delta
    over AOSP: forced module signing (`ec69683a7042`), lockdown LSM in
    confidentiality mode (`b19b430760c4`), `RANDSTRUCT_FULL`
    (`816d1996b2c8`), `RANDOM_KMALLOC_CACHES` (`2dfdb1062888`),
    `INIT_ON_FREE_DEFAULT_ON` (`7749342e2592`), max mmap entropy
    (`efaafdbd8fa7`, `202da0eeca54`), `RANDOMIZE_KSTACK_OFFSET_DEFAULT`
    (`9c7603114913`), disabling hibernation (`07dd867518bf`), memory hotplug
    (`d86d224813b3`), TIPC/BINFMT_MISC/LEGACY_TIOCSTI/cachestat
    (`cfa719a29313`, `4a84a30c7b20`, `51d1fa9fb9ea`, `7e33a10a03f5`),
    sysrq neutering (`30ba0f40cdfc`), UEFI reset attack mitigation
    (`a2aec6633cd7`), `EFI_DISABLE_PCI_DMA` (`be937dd7da8b`), kernel BTI
    (`77d2b002c384`), refusing Android's PAC-into-SCS hybrid
    (`d1bdd7adcd3c`), x86 `DEFAULT_MMAP_MIN_ADDR=65536` (`2ceae5736aee`),
    `SYN_COOKIES` (`615bd95d91f0`), sha256 module sigs (`91aa73a28405`).
  - `GKI baseline` — AOSP `android15-6.6` state carried unchanged in their
    tree (`HARDENED_USERCOPY`, `FORTIFY_SOURCE`, slab freelist hardening,
    `INIT_ON_ALLOC_DEFAULT_ON`, `CFI_CLANG`, `SHADOW_CALL_STACK`,
    `KASAN_HW_TAGS`, `PANIC_ON_OOPS`, KFENCE, UBSan traps, ...). Their value
    add here is *keeping* these while adding on top; we carry them so a
    fragment set is self-contained.
  - `Anvil pin` — symbols GrapheneOS leaves at the branch's Kconfig default
    (e.g. `ARM64_BTI_KERNEL`, `ARM64_MTE`, `PAGE_TABLE_ISOLATION`,
    `CPU_SRSO`); we restate the default explicitly so baseline drift cannot
    silently remove the property. Each pin's default was verified against the
    branch's Kconfig definitions via `check.py --explain`.

## Layering model

```
base.cfg                arch-independent hardening (59 symbols)
  + arch-arm64.cfg      arm64 hardening (21 symbols)   -> one per build
  + arch-x86_64.cfg     x86_64 hardening (17 symbols)
  + soc/<family>.cfg    SoC deltas (0-2 symbols each)  -> one per device SoC
  + device fragment     ROM builder's own device config (not part of Anvil)
```

| Layer | File | Symbols | Contents |
|---|---|---|---|
| base | `base.cfg` | 59 | heap/allocator hardening, CFI + RANDSTRUCT + UBSan, forced module signing, lockdown LSM (confidentiality), SELinux + SafeSetID, static usermodehelper (empty path = helper execution dead), init-on-alloc/free, data-corruption-is-fatal, sysrq neutering, UEFI trims, legacy syscall/tty attack surface |
| arch | `arch-arm64.cfg` | 21 | PAN/EPAN + SW_TTBR0_PAN, BTI (user+kernel), PTR_AUTH (user+kernel), shadow call stacks, 48-bit VA with maximum mmap entropy (33 bits), MTE + KASAN HW tags, SCS-over-PAC stance |
| arch | `arch-x86_64.cfg` | 17 | 32-bit mmap entropy, 64 MiB low-memory guard, KASLR (text + memory regions), PTI, retpoline/rethunk/UNRET/IBRS/SRSO/call-depth mitigation pins, frame-pointer unwinder |
| soc | `soc/qualcomm.cfg` | 2 | QCOM surface trims carried from their defconfig + MTE gating guidance |
| soc | `soc/{mediatek,exynos,tensor}.cfg` | 0 | honest deltas: none exist in their tree; documented MTE gating per family |

SoC families covered (minimum set): Qualcomm SM8550+ (`qualcomm.cfg`),
MediaTek Dimensity 9000+ (`mediatek.cfg`), Exynos 2200+/S5E (`exynos.cfg`),
Tensor G2/G3 (`tensor.cfg`, **reference-only** — GrapheneOS ships Tensor
themselves; a ROM builder should not merge that file).

**MTE gating.** `ARM64_MTE`/`KASAN_HW_TAGS` are carried exactly as
GrapheneOS carries them (their production defconfig builds MTE-backed
KASAN). The kernel self-disables HW-tag mode at boot on hardware without
MTE, so the lines are safe to ship family-wide; whether a given SoC actually
gets tagged memory is a firmware/DRAM-integration question per family —
each `soc/*.cfg` documents the current state (operative: Tensor G3; core-
capable but unverified platform: SM8550+, Dimensity 9000+, Exynos 2200+;
absent: Tensor G2).

## device-integration.md

### Merging the fragments

One supported route, taking merge order base -> arch -> soc -> device
(later files win, exactly like Kconfig precedence):

1. **`merge_config.sh`** (kbuild's own merger, warns on unmatched lines):
   ```sh
   ARCH=arm64 scripts/kconfig/merge_config.sh -m arch/arm64/configs/gki_defconfig \
       "$ANVIL/hardening/kernel/base.cfg" \
       "$ANVIL/hardening/kernel/arch-arm64.cfg" \
       "$ANVIL/hardening/kernel/soc/qualcomm.cfg" \
       "$DEVICE.config"
   make ARCH=arm64 olddefconfig
   ```
   Run `merge_config.sh` without `-m` only if you want its `alldefconfig`
   starting point; ROM builders merging onto a GKI defconfig want `-m`.
   (`scripts/config` cannot do this merge — its `--file` flag selects the
   single config file to edit and repeated flags overwrite each other; an
   earlier revision of this README showed a no-op `scripts/config` recipe,
   caught by blind review of the cuttlefish campaign.) `olddefconfig`
   resolves dependencies; symbols whose dependencies are not met are
   silently dropped — which is exactly what `check.py`'s `unsatisfied-dep`
   warnings predict before you waste a build. Note that Kconfig `select`
   overrides fragment lines: on this branch `RANDSTRUCT_FULL` selects
   `MODVERSIONS`, so the carried `# CONFIG_MODVERSIONS is not set` line
   resolves back to `=y` (`check.py --explain MODVERSIONS` shows why).

Validation before building:

```sh
python3 tools/kernelconfig/check.py \
    hardening/kernel/base.cfg hardening/kernel/arch-arm64.cfg \
    hardening/kernel/soc/qualcomm.cfg \
    --manifest hardening/kernel/MANIFEST.yaml --offline
```

Exit code 0 = no errors. Remaining warnings are documented below
(GKI-baseline dependencies). Add your device fragment to the invocation and
any new line you add must also get a `MANIFEST.yaml` row (the manifest mode
rejects uncovered fragment lines *and* orphan manifest rows).

### Kernel command line

GrapheneOS hardens the cmdline, not just Kconfig
(`arch/arm64/configs/gki_defconfig` @ `f97a55ff191d`):
`console=ttynull stack_depot_disable=on kasan.stacktrace=off
kvm-arm.mode=protected ioremap_guard`. Anvil deliberately does **not** carry
`CONFIG_CMDLINE` in a fragment (a fragment must not hijack a device's
console); ROM builders should adopt these arguments in their own boot-image
cmdline — `kvm-arm.mode=protected` (pKVM) in particular is the single
strongest arm64 item in their setup.

### What GrapheneOS does that Anvil deliberately does NOT port

- **Pixel device integration.** Their strongest guarantees (verified boot
  interplay, weaver/keystore secrets, per-device module signing keys) live in
  their Pixel device repositories and signed release process, not in this
  kernel tree. Out of scope by definition.
- **KVM guest hardening beyond hardware.** They ship pKVM
  (`kvm-arm.mode=protected`) on hardware that supports it (Pixel 6+). On
  SoCs without protected-VM firmware support the argument is inert; Anvil
  documents it instead of pretending it ports.
- **Tensor reference only.** `soc/tensor.cfg` documents; it must not be
  merged (GrapheneOS owns that ground and their defconfig is already the
  source of everything else here).
- **Their userspace-side gating.** io_uring stays *enabled* in their kernel
  (default `y` @ `f97a55ff191d`) and is neutralized by their userspace
  syscall policy; unprivileged BPF is likewise a userspace/SELinux decision
  (`# CONFIG_BPF_UNPRIV_DEFAULT_OFF is not set` is carried verbatim). Anvil
  ports the kernel state; the ROM must bring the userspace policy.
- **`CONFIG_CMDLINE` hijacking** (see above) and Android's
  `GKI_TASK_STRUCT_VENDOR_SIZE_MAX`/vendor-hook ABI machinery, which only
  make sense inside the GKI KMI contract.

### Known gaps (honest)

- `INIT_STACK_ALL_ZERO` is **not** in their 6.6 gki_defconfig (it is set in
  some of their older/Pixel trees and in AOSP's `android-base.config`
  fragment); we port their defconfig state and do not invent the line.
- `CONFIG_COMPAT_VDSO`, `X86_KERNEL_IBT` stay off exactly as in their tree;
  IBT on x86 would be an *invention* relative to GrapheneOS.
- Warnings `INET`, `DEBUG_KERNEL` (SELinux/DEBUG_SG dependency chains) are
  satisfied by AOSP's `kernel/configs/android-base.cfg` layer that every GKI
  build applies on top of the defconfig — they are outside the defconfig
  text we port, so the validator rightly flags them as "not satisfied by
  fragments alone".

## Validator

`tools/kernelconfig/check.py` (stdlib + optional PyYAML) validates fragments
against the *real* Kconfig definitions of the pinned tree, without cloning:

- lists Kconfig files once via the git-trees API, caches under
  `.cache/kconfig/` (gitignored); cache filenames are `sha256(remote_path)`
  — remote data never shapes a filesystem path;
- walks `source` directives from the root Kconfig +
  `arch/{arm64,x86}/Kconfig` (priority subtrees first, `--max-fetch` cap,
  resumable cache);
- per symbol: existence, prompt presence (promptless pins are checked
  against their computed default), `depends on` evaluation against
  fragments + select-forced symbols + Kconfig defaults, `select` conflict
  detection, `# CONFIG_X is not set` type-consistency;
- cross-layer conflicts: errors for layers that merge together (base/arch/
  soc), informational for mutually exclusive layers (arm64 vs x86_64
  files);
- `--manifest` mode: every fragment line covered by `MANIFEST.yaml`, no
  orphan rows, values match (per-arch mappings supported);
- `--offline` (cache only, nonzero exit if missing), `--summary` (JSON to
  stdout), `--explain SYM` (definition site, prompt, deps, selects,
  defaults), `--arch arm64|x86|both`.

`python3 tools/kernelconfig/test_check.py` runs the unit suite fully offline
against a fixture cache.
