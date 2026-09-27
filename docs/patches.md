# Anvil platform patches — provenance, verification, integration

The `patches/platform/` series ports the portable, mechanical half of
GrapheneOS's platform-side hardened_malloc integration to AOSP trees that do
not carry their manifest. Three patches, all taxonomy `category=platform`,
`portability=portable`:

| # | patch | taxonomy id | relationship |
|---|---|---|---|
| 0001 | `0001-libc-use-hardened_malloc-as-the-native-64-bit-alloca.patch` | `platform_hmalloc_bionic_integration` | **equivalent** (rewritten for the scudo-era libc) |
| 0002 | `0002-init-add-disable_hardened_malloc-service-option.patch` | `platform_hmalloc_per_process_optout` (init half) | **port** (one deliberate delta) |
| 0003 | `0003-rootdir-raise-vm.max_map_count-for-hardened_malloc-g.patch` | `platform_init_vm_limits` | **port** (as-is) |

Series design: 0001 makes hardened_malloc the 64-bit native allocator and
keeps scudo linked as the opt-out target; 0002 is the init-side knob that
selects that opt-out per service; 0003 is the mandatory `vm.max_map_count`
companion without which the allocator cannot map its guard slabs at runtime.

Pinned upstream for every patch: **`android-16.0.0_r3`** release tags on
`aosp-mirror/platform_bionic` and `aosp-mirror/platform_system_core`
(immutable tags; chosen because GrapheneOS's `platform_bionic` branch `17`
tracks the corresponding AOSP release stream, so their fork state is the
closest evidence base for what still applies).

---

## 0001 — hardened_malloc as the native 64-bit allocator

- **Motivation** (`platform_hmalloc_bionic_integration`): out-of-line
  allocator metadata in a protected region, per-size-class isolation with
  randomized region bases, guard slabs/regions, slab canaries and
  quarantines, zero-on-free with write-after-free detection, deterministic
  invalid-free detection — for every 64-bit process, from libc.
- **Provenance**: studied GrapheneOS `platform_bionic` commit `20160b81611d`
  ("add hardened_malloc library", 2018-12-05) and the current integration on
  their branch `17` (`libc_native_allocator_defaults` multilib wiring in
  `libc/Android.bp`, `USE_H_MALLOC` branch in `libc/bionic/malloc_common.h`).
  Relationship: **portable equivalent**. Their 2018 diff targets the
  jemalloc-era `libc_ndk`/`libc_malloc` modules that no longer exist; their
  2026 tree additionally routes opt-outs through per-program ids and a
  kernel-backed `grapheneos_flags` process attribute (kernel commit
  `0ed87e270e9a`) plus a static-binary opt-out extension — all of which need
  GrapheneOS kernel support and are intentionally not carried. The portable
  equivalent uses the upstream `libc_native_allocator_defaults` seam, links
  hardened_malloc + scudo on 64-bit, selects hardened via `USE_H_MALLOC`
  cflags, and implements the opt-out as a `DISABLE_HARDENED_MALLOC`
  environment check in `MallocInitImpl` that re-points the dispatch tables
  at the retained scudo dispatch.
- **Mechanism**: compile-time allocator swap via the existing defaults seam
  (`multilib.lib64.cflags: -DH_MALLOC_PREFIX -DUSE_H_MALLOC`,
  `multilib.lib64.whole_static_libs: libhardened_malloc`), plus a 10-line
  runtime fallback guard. 32-bit is untouched. The `malloc_low_memory`
  product variable keeps controlling 32-bit; on 64-bit the hardened default
  stays, matching GrapheneOS's own current structure.
- **Verification**: `aosp-mirror/platform_bionic @ android-16.0.0_r3`;
  blob SHAs `07a4c6a0f4eeccabadcbe4cac88b952aa301ffd0`
  (`libc/Android.bp`), `4afcc4a8d5f3ceb1df0e0126de0a976c6cbb8f53`
  (`libc/bionic/malloc_common.h`),
  `e2c6eb125a90d4d4cb91683eef17e22f5a604b9b`
  (`libc/bionic/malloc_common_dynamic.cpp`); log
  `patches/platform/verify/0001-….log`.

## 0002 — init `disable_hardened_malloc` service option

- **Motivation** (`platform_hmalloc_per_process_optout`, init half): an
  escape hatch so a ROM can keep the hardened allocator system-wide while
  excusing individual vendor services known to misbehave under it:
  `service vendorfoo /vendor/bin/hw/vendorfoo` + `disable_hardened_malloc`.
- **Provenance**: **port** of GrapheneOS `platform_system_core` commit
  `923c7d86ceb8` ("init: add disable_hardened_malloc service option",
  2026-06-11). Delta vs. upstream: their version also re-execs through
  `execveat(FLAG_COMPAT_VA_39_BIT)` on arm64 so opted-out services run in a
  39-bit VA space; that flag is consumed by the GrapheneOS kernel process
  attribute (their kernel commit `0ed87e270e9a`) and is a no-op elsewhere,
  so the portable port drops it and keeps only the `setenv`. The env var
  name matches 0001's bionic-side check.
- **Verification**: `aosp-mirror/platform_system_core @ android-16.0.0_r3`;
  blob SHAs `f22e53f379472abecd922c286c7d4b083cc016dc` (`init/service.cpp`),
  `0095c827062a32260cf7c285973594c9a9b6f33f` (`init/service.h`),
  `8049762b0b9464bbe2463c2fe60e93939fded0b1` (`init/service_parser.cpp`),
  `e42b62b5cc6e07888e6a5e7b464128395e8bd351` (`init/service_parser.h`); log
  `patches/platform/verify/0002-….log`.

## 0003 — raise `vm.max_map_count` for guard slabs

- **Motivation** (`platform_init_vm_limits`): hardened_malloc places a guard
  slab between every slab and keeps metadata in separate mappings; the
  kernel default of 65530 mappings is not enough for populated processes and
  the allocator fails to map at runtime. 1048576 is the value the
  hardened_malloc "OS integration" documentation requires integrators to
  set. Mandatory companion to 0001.
- **Provenance**: **port** of GrapheneOS `platform_system_core` commit
  `e015be54b45c` ("increase max_map_count for hardened malloc",
  2018-12-13), applied as-is; only the surrounding `on boot` context moved
  upstream. The identical setting is still carried on their branch `17`
  (`rootdir/init.rc` line 1152 at access time).
- **Verification**: `aosp-mirror/platform_system_core @ android-16.0.0_r3`;
  blob SHA `2b1e68ae838be3552f3563d52c1957ea94bb89d3` (`rootdir/init.rc`);
  log `patches/platform/verify/0003-….log`.

---

## Verification recipe

Every ref and blob SHA above was resolved through the GitHub API before
being written down. To re-check any claim:

```bash
# 1. the studied GrapheneOS commits exist and are what docs/patches.md says
gh api repos/GrapheneOS/platform_bionic/commits/20160b81611d --jq '{m:.commit.message,f:[.files[].filename]}'
gh api repos/GrapheneOS/platform_system_core/commits/923c7d86ceb8 --jq '{m:.commit.message,f:[.files[].filename]}'
gh api repos/GrapheneOS/platform_system_core/commits/e015be54b45c  --jq '{m:.commit.message,f:[.files[].filename]}'

# 2. their current fork still carries the integration surface (branch 17)
gh api "repos/GrapheneOS/platform_bionic/contents/libc/Android.bp?ref=17"       --jq .sha
gh api "repos/GrapheneOS/platform_system_core/contents/rootdir/init.rc?ref=17"  --jq .content | base64 -d | grep max_map_count

# 3. the pinned upstream blobs the patches were generated against
gh api "repos/aosp-mirror/platform_bionic/contents/libc/Android.bp?ref=android-16.0.0_r3" --jq .sha
#   (…same call for each path in patches/platform/manifest.yaml)

# 4. full mechanical re-verification (fetch + sha pin + git apply --check)
tools/patches/apply_check.sh            # network; also: --offline for cache-only
```

`tools/patches/apply_check.sh` reads `patches/platform/manifest.yaml`,
re-fetches every pinned file, refuses to proceed if any blob SHA drifted,
reconstructs a scratch git tree at the pinned state, and runs
`git apply --check` (probing `--3way` and reporting it in the log when plain
`--check` fails). Logs land in `patches/platform/verify/<patch>.log`; the
command exits nonzero on any failure. The harness itself is negative-tested:
tampered `blob_sha` → content failure; `../` path components in the manifest
→ validation abort; drifted hunk context → apply failure.

## Integration instructions (AOSP / LineageOS maintainer)

Prerequisite: `external/hardened_malloc` in the tree, providing the
`libhardened_malloc` module (the project's shipped `Android.bp`, which builds
with `-DH_MALLOC_PREFIX` and `-DCONFIG_STATS=true` so `mallinfo`/`malloc_info`
satisfy the dispatch table; GrapheneOS syncs it via their manifest project
`platform_external_hardened_malloc`). Anvil keeps an integration copy under
`integration/hardened_malloc/`.

**Option A — repo manifests** (recommended for a full ROM build): add to
your `local_manifests` (e.g. `.repo/local_manifests/anvil.xml`):

```xml
<manifest>
  <remote name="anvil" fetch="https://github.com/ANVIL-ORG" />
  <!-- keep hardened_malloc from upstream GrapheneOS or your fork -->
  <project path="external/hardened_malloc" name="hardened_malloc"
           remote="anvil" revision="main" />
</manifest>
```

then apply the series to the two platform repos (working from each repo's
checkout after `repo sync`):

```bash
cd system/core
git am /path/to/anvil/patches/platform/0002-init-add-disable_hardened_malloc-service-option.patch
git am /path/to/anvil/patches/platform/0003-rootdir-raise-vm.max_map_count-for-hardened_malloc-g.patch
cd ../bionic
git am /path/to/anvil/patches/platform/0001-libc-use-hardened_malloc-as-the-native-64-bit-alloca.patch
```

(`repo forall` equivalent:

```bash
repo forall -c 'true'    # sync first
git -C system/core am …  # as above
git -C bionic am …
```

)

No build-system configuration is needed beyond the module: the patches wire
`libhardened_malloc` into libc's allocator defaults, so a normal `mka`/`m`
picks it up. Post-boot sanity checks:

```bash
# opted-out services announce the fallback (tag "libc", info level):
adb logcat -s libc | grep "using scudo instead of hardened_malloc"

# native heap composition of a running process (hardened_malloc reports
# its arena layout through mallinfo when CONFIG_STATS=true):
adb shell am dumpheap -n <pid> /data/local/tmp/heap.txt
```

**Option B — patch-train workflow**: keep the series in a fork of
`platform_bionic` / `platform_system_core` (as GrapheneOS does) and track
upstream merges; the patches touch the seams upstream touches least:
`libc_native_allocator_defaults` + malloc dispatch selection in bionic, the
service parser in init, one line in `rootdir/init.rc`.

**Expected upstream-merge conflict surface**

- 0001: `libc/Android.bp` around `libc_native_allocator_defaults` (upstream
  occasionally reshapes the malloc-low-memory product variables), and
  `libc/bionic/malloc_common_dynamic.cpp` around `MallocInitImpl` (upstream
  changes to GWP-ASan/heapprofd init ordering). `malloc_common.h` hunk is
  stable (allocator-prefix macro table).
- 0002: `init/service_parser.cpp` `GetParserMap` table (high upstream churn —
  new service options land regularly; re-insert one line) and
  `init/service.cpp` `ExpandArgsAndExecv` (occasional new pre-exec blocks).
- 0003: `rootdir/init.rc` `on boot` block (low churn; context is the
  `/dev/sys` symlink block + F2FS tuning comment).

**Behavioral notes for release engineers**

- Opt-out audit trail: opted-out services log `using scudo instead of
  hardened_malloc` (info, tag `libc`).
- GWP-ASan, heapprofd, MTE heap tagging and `libc.debug.malloc` hooks keep
  working: they layer on the dispatch table, which now initially wraps the
  hardened dispatch.
- Memory cost: 64-bit libc now embeds two allocators (scudo retained as the
  opt-out target — same structure GrapheneOS ships). If binary size matters,
  that is the knob to revisit, not the dispatch logic.
