# Anvil emulator harness

The emulator milestone of the honesty policy: **boot a real Android system
and prove Anvil's userland hardening stack runs inside it** — the first
artifact in this repo that executes on Android rather than being linted,
benchmarked, or apply-checked.

## What it proves (each step recorded in `results/emulator/`)

1. **Anvil's NDK/bionic build of upstream hardened_malloc is a real Android
   library.** `integration/hardened_malloc/build-android.sh` builds
   GrapheneOS/hardened_malloc at the same pinned SHA as the host build, with
   the NDK, against bionic, for x86_64 and aarch64, default and light
   variants. Every deviation from upstream's host configuration is enumerated
   in each artifact's `meta.json` — no silent patches.
2. **It serves verified allocation traffic on-device.**
   `integration/hardened_malloc/android_smoke.c` runs inside the booted
   system in two conclusive modes:
   - `--interposed`: with the .so under `LD_PRELOAD`, the process's own
     malloc-family calls are served by hardened_malloc (proved via the
     stats-gated `h_mallinfo_narenas`, which stock bionic scudo cannot
     answer), after a full-span write/verify malloc/calloc/realloc/aligned
     exercise.
   - `--dlopen`: **expected to be refused, and the refusal is the proof.**
     Upstream deliberately compiles its thread-local state with
     `__attribute__((tls_model("initial-exec")))`; bionic refuses IE TLS in
     `dlopen`'ed libraries, so a refusal carrying that signature confirms
     the build is upstream-faithful and that preload-at-exec (the
     sanctioned `wrap.<package>` path) is the only load mode. Standard
     artifacts additionally fail via upstream's `-z nodlopen`.
3. **A zygote-launched app runs under the allocator.** The sanctioned
   `wrap.<package>` property (the same mechanism as Google's own
   `libc_malloc_debug`) launches Settings with the .so preloaded; the smoke
   requires the process alive with `libhardened_malloc` mapped in
   `/proc/<pid>/maps`.

## What it does NOT claim

- **No kernel hardening is validated here.** The emulator runs the stock
  goldfish kernel (`kernel-ranchu` in the system image). Anvil's kernel
  fragments need a bootable custom kernel — that is Cuttlefish + an
  android-common build, a follow-up, and it is not claimed anywhere.
- **aarch64 artifacts are compile-checked, not executed.** The emulator
  image is x86_64; the aarch64 .so files prove the cross-build, nothing
  about runtime behavior.
- **Provenance of the API-29 floor:** at `minSdkLevel < 29` the NDK compiles
  thread-local storage to `__emutls_get_address`; bionic's emutls allocates
  through (interposed) malloc, which recurses into hardened_malloc's own TLS
  access and overflows the stack. The tombstone for that crash is preserved
  in `results/emulator/`. API 29+ gives shared libraries native ELF TLS.
- **No C++ allocator interposition.** Android's linker namespaces make
  `operator new` interposition from a preloaded library a different
  project; the claimed surface is the malloc family.
- **The wrap demo relaxes SELinux momentarily** on the userdebug emulator
  image (untrusted_app cannot read `/data/local/tmp` shell_data_file). The
  enforcing state is captured before and after in the results JSON. Real
  integration ships the allocator inside the system image — that is the
  platform-patches milestone, not this harness.

## Quickstart

```sh
emulator/setup-host.sh          # SDK + NDK + AVD (honours ANDROID_HOME; big volume by default)
emulator/boot.sh --keep         # headless boot, KVM; leaves it running
emulator/smoke.sh               # builds (if needed), pushes, proves 1-3
emulator/posture.sh             # dump the platform's observable security posture
```

CI runs the same steps with `boot.sh --software` (no KVM on GitHub-hosted
runners; software boot is slow). See `.github/workflows/emulator.yml` —
dispatch-only until its first green run, per the honesty policy.

## Provenance

- System image: `system-images;android-36.1;google_apis;x86_64` (userdebug —
  `adb root` must work for the harness)
- NDK: `28.2.13676358` (upstream hardened_malloc requires clang ≥ 19.1.7;
  r27's clang 18 fails `-Werror` on bionic paths)
- Upstream pin: the same `HMALLOC_SHA` as `integration/hardened_malloc/build.sh`
