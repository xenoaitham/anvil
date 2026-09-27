# GrapheneOS portable hardening baseline

Measured inventory of the GrapheneOS org's public hardening surface, taken from their
actual repositories. Every number cites its source: a file path in the local reference
clones (`/home/potato/grafene/ref/…`), a GitHub API call, or a commit SHA. All API
accesses and clone HEADs are as of **2026-09-27** unless stated otherwise.

Reference clones used (HEAD at access time):

| Clone | HEAD | Date |
|---|---|---|
| `GrapheneOS/hardened_malloc` (shallow) | `01df350c62441e163a8b9324fb7e156acdad2c1e`, tag `2026092500` | 2026-09-25 |
| `GrapheneOS/grapheneos.org` | static pages `static/faq.html`, `static/features.html`, `static/usage.html` | fetched 2026-09-27 |
| `GrapheneOS/platform_manifest` | `0493b9e3a3ae90faf39bd7979a03df5e5dc63a0a` ("use fork of platform/frameworks/hardware/interfaces") | 2026-09-25 |
| `GrapheneOS/kernel_manifest-6.6` | `4f9f5acd7498978e03193cddbd2c2aaf34217c01` ("update branch to 17") | 2026-06-19 |

The `hardened_malloc` clone is shallow (1 commit), so repo-internal commit counts are
not measurable locally; remote facts about it come from the GitHub API where cited.

## a) hardened_malloc

### Version

- Local clone tag: `2026092500` on commit `01df350` ("fix 0 size allocations with
  >PAGE_SIZE alignment for !CONFIG_LARGE_SIZE_CLASSES", authored 2026-09-25) —
  `git tag -l` and `git log -1` in the clone, 2026-09-27.
- The GitHub *releases* feed uses numbered tags; latest release at access time was
  `14`, published 2026-02-22 (`gh api repos/GrapheneOS/hardened_malloc/releases`,
  2026-09-27). Date-based tags like `2026092500` mark rolling snapshots on `main`.

### Supported libcs and why it is portable

`README.md` (Introduction): "This project currently supports Bionic (Android), musl
and glibc." Dependency floor is Debian 13 (glibc 2.41, Linux 6.12, Clang 19.1.7 or
GCC 14.2.0); for Android, "the Linux GKI 6.1, 6.6 and 6.12 branches are supported"
and only the current AOSP maintenance branch (`android17-release`) is supported
(`README.md`, Dependencies). Portability mechanisms, all measured in the clone:

- Standard malloc API + extensions only; no libc-internal hooks required for
  preload use (`preload.sh`, `README.md` § "Traditional Linux-based operating
  systems": `/etc/ld.so.preload` works with glibc and musl).
- 64-bit only by design, 4096-byte pages only, needs a 48-bit VA on arm64 for the
  default 32 GiB per-size-class regions (`README.md` § "Compatibility", § "Core
  design"). This is the real portability constraint, and it maps 1:1 onto the
  kernel-side 48-bit VA commits (section b).
- Soong integration for Android ships in-tree: `Android.bp` builds
  `libhardened_malloc.so` with the same `CONFIG_*` cflags as the Makefile;
  `androidtest/` carries an Android instrumentation harness (`AndroidTest.xml`,
  `MemtagTest.java`, `memtag/memtag_test.cc`).

### Feature inventory (README § "Security properties" + config surface)

Default config `config/default.mk` (24 options, read from the file):

| Mitigation | Config | Default |
|---|---|---|
| Zero-on-free (small allocations) | `CONFIG_ZERO_ON_FREE` | true |
| Write-after-free detection (verify zero fill intact at alloc) | `CONFIG_WRITE_AFTER_FREE_CHECK` | true |
| Random slot selection in slabs | `CONFIG_SLOT_RANDOMIZE` | true |
| 8-byte slab canaries (zero first byte absorbs C-string overflow; checked on free) | `CONFIG_SLAB_CANARY` | true |
| Slab quarantine: randomized array + FIFO queue, scaled per size class | `CONFIG_SLAB_QUARANTINE_RANDOM_LENGTH=1`, `..._QUEUE_LENGTH=1` | on |
| Large-allocation quarantine (protect+purge, FIFO ring + random swap, 32 MiB skip threshold) | `CONFIG_REGION_QUARANTINE_RANDOM_LENGTH=256`, `..._QUEUE_LENGTH=1024`, `..._SKIP_THRESHOLD=33554432` | on |
| Free-slab quarantine (randomized reuse) | `CONFIG_FREE_SLABS_QUARANTINE_RANDOM_LENGTH=32` | on |
| Guard slab between every slab | `CONFIG_GUARD_SLABS_INTERVAL=1` | on |
| Randomly sized guard regions around large allocations | `CONFIG_GUARD_SIZE_DIVISOR=2` | on |
| Independent arenas | `CONFIG_N_ARENA=4` | 4 |
| Per-size-class isolation, random region bases, isolated metadata region | not configurable (core design) | always |
| Metadata sealing via memory protection keys (x86_64) | `CONFIG_SEAL_METADATA` | false (niche; disabled by default) |
| MTE on ARMv8.5+: random tags, reserved `0` tag on free, distinct adjacent tags | not configurable on arm64 builds (`memtag.h`, `Android.bp:76` `-DHAS_ARM_MTE`) | on with MTE hw |
| Size classes to 128 kiB / large size classes | `CONFIG_EXTENDED_SIZE_CLASSES`, `CONFIG_LARGE_SIZE_CLASSES` | true/true |
| C++ allocator replacement incl. sized-deallocation mismatch detection | `CONFIG_CXX_ALLOCATOR` | true |
| Stats/mallinfo/malloc_info | `CONFIG_STATS` | false (true in Android builds; README § "Stats") |
| `PR_SET_VMA` anonymous memory labeling | `CONFIG_LABEL_MEMORY` | false (Android-only feature) |
| UBSan build flag | `CONFIG_UBSAN` | false |

`config/light.mk` differs from default exactly by: `WRITE_AFTER_FREE_CHECK=false`,
`SLOT_RANDOMIZE=false`, both slab quarantine lengths `0`, `GUARD_SLABS_INTERVAL=8`
(read from both files).

The randomness engine is ChaCha8 keystreams, one CSPRNG per size class per arena,
regularly reseeded from `getrandom()` (`README.md` § "Randomness"; `chacha.c`,
140/177 lines in `random.c`/`chacha.c`).

### Test suite inventory

- `test/`: 62 native test programs (57 `.c`, 5 `.cc`) + `Makefile` +
  `test_util.h`. Coverage by category (file names are the inventory):
  overflow (`overflow_{small,large}_{1,8}_byte.c`), double free
  (`double_free_{small,large}{,_delayed}.c`), write-after-free
  (`write_after_free_{small,large}{,_reuse}.c`), read-after-free
  (`read_after_free_{small,large}.c`), uninitialized memory
  (`uninitialized_{free,read_large,read_small,malloc_usable_size,realloc}.c`),
  invalid free (`invalid_free_{protected,small_region,small_region_far,unprotected,aligned_sized_small}.c`),
  unaligned free (2), invalid aligned/sized C++ delete (4), sized delete (4),
  API conformance (`calloc_overflow.c`, `calloc_zeroed.c`, `aligned_alloc_einval.c`,
  `aligned_alloc_zero_size.c`, `posix_memalign_einval.c`, `pvalloc.c`,
  `reallocarray_overflow.c`, `realloc_init.c`, `mallinfo.c`, `mallinfo2.c`,
  `malloc_info.c`), object-size APIs (`malloc_object_size*.c`, 5 files),
  zero-size edge cases (3), `string_overflow.c`, `large_array_growth.c`,
  `malloc_noreuse.c`, `offset.c`.
- Driver: `make test` builds all programs and runs `python3 -m unittest discover`
  → `test/test_smc.py` with **58 `def test_` methods** asserting exact exit codes
  and fatal-error messages (`grep -c "def test_" test/test_smc.py`).
- Android: `androidtest/` — Soong instrumentation module + native `memtag_test.cc`
  with 11 `TEST()` cases (`grep -c "TEST(" androidtest/memtag/memtag_test.cc`).

### Benchmark / bench surface inventory (measured absence + what exists)

- **No benchmark suite exists in the repo.** `grep -rli "bench"` across sources,
  Makefiles and `.bp` files returns nothing (checked 2026-09-27).
- `third_party/` contains exactly one vendored file: `libdivide.h`.
- What exists instead: `preload.sh` (LD_PRELOAD harness for testing real
  applications, README § "Individual Applications"), `calculate-waste` (Python
  script computing internal-fragmentation waste of the size-class table), and the
  test suites above. `KERNEL_FEATURE_WISHLIST.md` tracks kernel features the
  allocator would benefit from.
- Implication for Anvil: the bench surface must be built, not ported; the only
  upstream-sanctioned performance comparison method is real-application preload.

## b) Kernel hardening (GrapheneOS/kernel_common-6.6, branch `17`)

Method: raw `gki_defconfig` fetched via
`gh api repos/GrapheneOS/kernel_common-6.6/contents/arch/arm64/configs/gki_defconfig?ref=17`
(805 lines, 2026-09-27), plus commit listings on
`arch/arm64/configs` (`per_page=50`) and `security` (`per_page=100`). GrapheneOS
commits are identified by author (Daniel Micay, Dmitry Muhomor/inthewaves,
flawedworld, maade93791 — Google/LTS authors are the control group).

### Hardening symbols measured in their `gki_defconfig` (line numbers into the fetched file)

| Symbol | Value | line |
|---|---|---|
| `CONFIG_HARDENED_USERCOPY` | y | 727 |
| `CONFIG_FORTIFY_SOURCE` | y | 728 |
| `CONFIG_SLAB_FREELIST_RANDOM` | y | 119 |
| `CONFIG_SLAB_FREELIST_HARDENED` | y | 120 |
| `CONFIG_RANDOM_KMALLOC_CACHES` | y | 121 |
| `# CONFIG_SLAB_MERGE_DEFAULT` | not set | 118 |
| `CONFIG_INIT_ON_ALLOC_DEFAULT_ON` | y | 736 |
| `CONFIG_INIT_ON_FREE_DEFAULT_ON` | y | 737 |
| `CONFIG_BUG_ON_DATA_CORRUPTION` | y | 738 |
| `CONFIG_RANDSTRUCT_FULL` | y | 739 |
| `CONFIG_KFENCE` | y, `KFENCE_SAMPLE_INTERVAL=500`, `KFENCE_NUM_OBJECTS=63` | 789-791 |
| `CONFIG_RANDOMIZE_BASE` (KASLR) | y | 68 |
| `CONFIG_RANDOMIZE_KSTACK_OFFSET_DEFAULT` | y | 100 |
| `CONFIG_CFI_CLANG` | y | 97 |
| `CONFIG_SHADOW_CALL_STACK` | y | 96 |
| `CONFIG_ARM64_SW_TTBR0_PAN` | y | 61 |
| `CONFIG_MODULE_SIG_FORCE` + `CONFIG_MODULE_SIG_SHA256` | y | 104-105 |
| `CONFIG_SECURITY_LOCKDOWN_LSM` + `_EARLY` | y | 733-734 |
| `CONFIG_SECURITY_SAFESETID` | y | 732 |
| `CONFIG_SECURITY_SELINUX` | y | 731 |
| `CONFIG_PANIC_ON_OOPS` + `CONFIG_PANIC_TIMEOUT=-1` | y | 792-793 |
| `CONFIG_DEBUG_SG` | y | 797 |
| `CONFIG_RESET_ATTACK_MITIGATION` | y | 329 |
| `CONFIG_EFI_DISABLE_PCI_DMA` | y | 330 |
| `CONFIG_SYN_COOKIES` | y | 153 |
| `# CONFIG_DEVMEM` | not set | 440 |
| `# CONFIG_LEGACY_PTYS` / `# CONFIG_LEGACY_TIOCSTI` | not set | 414-415 |
| `# CONFIG_LDISC_AUTOLOAD` | not set | 416 |
| `CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE` | `0x0`, `# CONFIG_MAGIC_SYSRQ_SERIAL` not set | 776-778 |
| `# CONFIG_RSEQ` / `# CONFIG_CACHESTAT_SYSCALL` | not set | 50-51 |
| `CONFIG_CMDLINE` | `"console=ttynull stack_depot_disable=on cgroup_disable=pressure kasan.stacktrace=off kvm-arm.mode=protected bootconfig ioremap_guard"` (+`CMDLINE_EXTEND`) | 70-71 |
| `CONFIG_BPF_JIT_ALWAYS_ON` / `CONFIG_BPF_LSM` | y | 9 / 11 |

### Their commits vs upstream (evidence SHAs, `gh api .../commits?path=...`)

Hardening-enable commits on `arch/arm64/configs` by GrapheneOS authors:

| SHA | Author | Date | Subject |
|---|---|---|---|
| `2dfdb1062888` | Daniel Micay | 2024-08-29 | enable CONFIG_RANDOM_KMALLOC_CACHES |
| `816d1996b2c8` | Daniel Micay | 2024-08-29 | enable CONFIG_RANDSTRUCT_FULL |
| `be937dd7da8b` | Daniel Micay | 2024-08-29 | enable CONFIG_EFI_DISABLE_PCI_DMA |
| `77d2b002c384` | Daniel Micay | 2024-02-04 | enable ARM64_BTI_KERNEL |
| `d1bdd7adcd3c` | Daniel Micay | 2024-02-04 | disable UNWIND_PATCH_PAC_INTO_SCS |
| `a2aec6633cd7` | Daniel Micay | 2024-01-19 | enable reset attack mitigation for UEFI |
| `30ba0f40cdfc` | Daniel Micay | 2024-02-01 | disable unnecessary sysrq functionality |
| `9c7603114913` | Daniel Micay | 2023-04-21 | enable RANDOMIZE_KSTACK_OFFSET_DEFAULT |
| `4a84a30c7b20` | Daniel Micay | 2022-10-31 | disable BINFMT_MISC |
| `f37a3bac746b` | Daniel Micay | 2022-10-28 | enable DEBUG_SG |
| `21096668d993` | Daniel Micay | 2022-10-25 | disable LDISC_AUTOLOAD |
| `b19b430760c4` | Daniel Micay | 2022-10-26 | enable lockdown LSM in confidentiality mode |
| `ec69683a7042` | Daniel Micay | 2024-03-22 | switch to forced module signing |
| `91aa73a28405` | Daniel Micay | 2022-10-23 | switch to sha256 for module signing |
| `615bd95d91f0` | flawedworld | 2021-12-19 | enable CONFIG_SYN_COOKIES |
| `e985b6d73030` / `efaafdbd8fa7` | flawedworld | 2021-12-13 | arm64: enable 48-bit address space / raise default mmap bits |
| `7749342e2592` | flawedworld | 2021-12-13 | enable CONFIG_INIT_ON_FREE_DEFAULT_ON |
| `202da0eeca54` | flawedworld | 2021-12-13 | use max mmap entropy by default to cover init |
| `07dd867518bf` | Daniel Micay | 2024-10-26 | disable CONFIG_HIBERNATION (removes `CONFIG_HIBERNATION=y` from both arm64 and x86 `gki_defconfig`; verified via commit diff) |
| `d86d224813b3` | Daniel Micay | 2025-09-10 | disable memory hotplug support |
| `cfa719a29313` / `7e33a10a03f5` / `51d1fa9fb9ea` | Daniel Micay | 2024-11/10 | disable unused TIPC / cachestat syscall / LEGACY_TIOCSTI |

Attack-surface code divergence under `security/` (their commits on top of the
Android common kernel):

| SHA | Author | Date | Subject |
|---|---|---|---|
| `ddad061e8f45` | Dmitry Muhomor | 2023-08-31 | selinux: support restricting dynamic code execution via tsec_flags |
| `aba3211149c5` | Dmitry Muhomor | 2023-09-28 | selinux: support blocking ptrace access via tsec_flags |
| `f398c882c7a3` | Dmitry Muhomor | 2023-09-03 | selinux: cache zygote context types when loading policy (fixup `f97a55ff191d`, 2026-08-27) |
| `0ed87e270e9a` | Dmitry Muhomor | 2026-07-19 | add DISABLE_HARDENED_MALLOC process attribute flag |
| `e5a87cada711` | Daniel Micay | 2017-05-04 | mm: add support for verifying page sanitization (still carried) |

The pattern: a config layer (all of the symbols above — device-independent), a
small SELinux/task-flags code layer, and per-device kernel trees pinned in
`kernel_manifest-6.6` (`device_google_*-kernels_6.1`/`6.6` per-Pixel prebuilt
kernel repos, read from `default.xml`).

## c) Platform hardening surface (platform_manifest)

`platform_manifest/default.xml` @ `0493b9e` pins 1057 projects; **129 projects are
synced from GrapheneOS remotes** (GitHub `GrapheneOS/` and one gitlab mirror), of
which **109 are `platform_*` AOSP forks** (counted with
`grep '<project' | grep 'remote="grapheneos' | grep -oP '(?<![A-Za-z-])name="platform[^"]*"' | sort -u`,
2026-09-27). The remainder is first-party tooling and apps (`branding`, `adevtool`,
`script`, `hardened_malloc`, per-Pixel `device_google_*-kernels_*` repos).

Divergence measurement — method stated honestly: full commit listing since
2024-09-27 via `gh api repos/GrapheneOS/<repo>/commits?since=2024-09-27T00:00:00Z`
(paginated, includes AOSP-merge traffic; **API log sampling, not a full diff**):

| Fork | commits since 2024-09-27 | by GrapheneOS team | team share |
|---|---|---|---|
| `platform_bionic` | 2361 | 51 (Daniel Micay, Dmitry Muhomor, inthewaves, quh4gko8) | ~2.2% |
| `platform_art` | 3832 | 18 | ~0.5% |
| `platform_system_core` | 2932 | 20 | ~0.7% |

Representative GrapheneOS-authored commits (SHAs from the same API runs):

- bionic: `20160b81611d` (2018-12-05, "add hardened_malloc library" — the
  integration commit `hardened_malloc/README.md` § "Android-based operating
  systems" links to), `b777629641e8` (2026-09-22, "add guard page(s) between
  static_tls and stack"), `72978e7937d0` (2026-07-19, "extend hardened_malloc
  opt-out support to static binaries"), `3783533d6a6a` (2026-07-19, "always use
  scudo on arm64 debuggable builds with 39-bit VA space"), `ce151b8c8977`
  (2026-06-20, "disable MTE for Widevine Rikers service").
- art: in the 2-year window the divergence is dominated by the GmsCompat
  sandbox (`6a459adafb78`, `00f0ae3c9857`, 2025-2026); classic hardening
  commits sit earlier, e.g. `abe3c27eb46b` (2023-11-28, "sigchainlib: add option
  to force default handling of MTE SEGV signals"), `97b9f0b7e09c` (2023-10-06,
  "disable JIT profile saving").
- system_core: `923c7d86ceb8` (2026-06-11, "init: add disable_hardened_malloc
  service option"), `c11700447a53` (2026-01-05, "enable an extra layer of USB
  port protection on 10th gen Pixels at boot"), `84ebea5e2111` (2026-07-15,
  "use lazy preloading for compat zygote"), `62f6dd081794` (2025-01-24,
  "enable appcompat sysprop overrides").

Also carried as forks and relevant to portability: `platform_system_sepolicy`,
`platform_system_vold`, `platform_system_update_engine`, `platform_external_vanadium`
(hardened WebView/browser), `platform_packages_modules_Connectivity`,
`platform_frameworks_base` (feature toggles), `platform_packages_providers_MediaProvider`
(Storage Scopes) — names read from `default.xml`.

## d) Device support posture (grapheneos.org docs, quoted from the clone)

- **Official support list** (`static/faq.html` § "Which devices are supported?"):
  "GrapheneOS has official production support for the following devices:" — Pixel
  6 through Pixel 10a generation (21 devices listed, codenames `oriole`…`stallion`),
  plus "extended support releases as a stopgap" for older ones. Beyond that:
  "Many other devices are supported by GrapheneOS at a source level, and it can be
  built for them without modifications to the existing GrapheneOS source tree…
  In most cases, substantial work beyond that will be needed to bring those devices
  up to the same security standards." (same section)
- **Recommendation rationale** (§ "Which devices are recommended?"): "8th generation
  and later Pixels provide a minimum guarantee of 7 years of support… also have
  support for the incredibly powerful hardware memory tagging security feature as
  part of moving to new ARMv9 CPU cores."
- **Why they refuse broad device support** (§ "Which devices will be supported in
  the future?"): "Hardware, firmware and software specific to devices like drivers
  play a huge role in the overall security of a device. The goal of the project is
  not to slightly improve some aspects of insecure devices…" The same section lists
  their non-exhaustive device requirements, which is the cleanest public statement
  of what a device must provide: verified boot with rollback protection for
  firmware *and* OS, monthly firmware/driver/HAL patch delivery, "Hardware memory
  tagging (ARM MTE or equivalent)", "Hardware-based coarse grained Control Flow
  Integrity (BTI/PAC, CET IBT or equivalent)", PXN/SMEP, PAN/SMAP, isolated radios,
  A/B updates with rollback, StrongBox keystore + hardware key attestation +
  attest-key pinning, Weaver throttling, insider-attack-resistant SE updates,
  wrapped-key inline encryption, 64-bit-only device support code, USB data
  disablement at the controller, reset attack mitigation.
- **Update ceiling on non-Pixel devices** (§ "How long can GrapheneOS support my
  device?"): "GrapheneOS can only fully provide security updates to a device
  provided that the OEM is releasing them. When an OEM is no longer providing
  security updates, GrapheneOS may provide temporary extended support releases for
  harm reduction. Extended support releases cannot provide full security patches…"
  And § "Why are older devices no longer supported?": "firmware would present a
  major issue, and the community has never been active or interested enough in
  device support to make that a reality."
- **GSI explicitly rejected** (§ "Which devices are supported?"): "GrapheneOS does
  not support being used as a Generic System Image… since we require kernel changes
  and the userspace part of the OS cannot run on top of a kernel without the
  required functionality."
- **hardened_malloc portability acknowledged** (same section): "The hardened_malloc
  project supports nearly any Linux-based environment due to official support for
  musl, glibc and Bionic along with easily added support for other environments."

## e) "Portable patch set" — what transfers, what cannot

Portable (device-independent; the taxonomy in `taxonomy/portable-taxonomy.yaml`
scores every item):

1. **The allocator**: entire hardened_malloc surface (section a) — builds for any
   64-bit Linux kernel with 4k pages; Android integration glue is a bionic commit
   plus `init.rc` `vm.max_map_count` bump (`README.md` § "OS integration").
2. **Kernel config symbols**: the defconfig layer of section b — Kconfig symbols
   from `CONFIG_HARDENED_USERCOPY` to `CONFIG_RANDSTRUCT_FULL` port as fragments to
   any GKI 6.1/6.6/6.12 device, including the *disable* half (hibernation, sysrq,
   TIOCSTI, DEVMEM, LDISC_AUTOLOAD, BINFMT_MISC). Constraint: hardened_malloc wants
   the 48-bit VA arm64 setting (`e985b6d73030`) and `ARCH_MMAP_RND_BITS` maxed
   (`202da0eeca54`).
3. **Generic platform patches**: bionic hardened_malloc integration + per-process
   opt-out plumbing, selinux task-flag hardening (ptrace/execve-scoping) that only
   needs the common-kernel SELinux hooks, sepolicy additions, `vm.max_map_count`
   init wiring.

Impossible without vendor cooperation (measured, not assumed — each item traces to
section d requirements or b/c evidence):

1. **Verified boot with rollback protection they can ship**: requires signing the
   device's own boot chain — OEM fusion/AVB keys, firmware rollback indexes
   (`static/faq.html` future-device requirements). AOSP's `platform_system_update_engine`
   fork cannot create this on a device whose firmware trusts only the OEM.
2. **Firmware/driver/HAL security updates**: the monthly ASB patch stream for
   device support code is upstream vendor output ("GrapheneOS can only fully
   provide security updates… provided that the OEM is releasing them").
3. **Hardware attestation provisioning**: StrongBox/hardware attest-key pairs are
   factory-provisioned; GrapheneOS's Auditor model depends on Google's
   provisioned root for Pixels (attestation requirement list, section d).
4. **MTE by default**: needs ARMv9 cores + vendor kernels enabling it; on Pixels
   even GrapheneOS maintains per-process MTE disable lists for broken vendor
   processes (`ce151b8c8977`, `14d79ed3e1e3`, `60f1df32c873` in bionic) — on
   non-MTE hardware the taxonomy records `pixel-only`/`partial`, never `portable`.
5. **OS/firmware security-update control**: full A/B firmware updates with
   rollback indexes and insider-attack-resistant SE updates are vendor firmware
   features, not patches (section d requirement list).

## Sources

- Local clones under `/home/potato/grafene/ref/` (HEADs listed above), accessed 2026-09-27.
- `gh api repos/GrapheneOS/kernel_common-6.6/...` (contents + commits), 2026-09-27.
- `gh api repos/GrapheneOS/platform_{bionic,art,system_core}/commits?since=2024-09-27T00:00:00Z`, 2026-09-27.
- `gh api repos/GrapheneOS/hardened_malloc/releases`, 2026-09-27.
