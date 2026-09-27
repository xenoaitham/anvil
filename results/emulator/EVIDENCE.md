# Emulator validation campaign — raw run log

First green run: `20260927-234546` (smoke) + `20260927-234618` (posture).
Everything below is quoted from captured outputs; the raw files live in the
timestamped directories next to this document.

## §1 — emutls recursion at API < 29 (build floor finding)

Symptom: `android_smoke --interposed` under `LD_PRELOAD` segfaulted before
any output. Tombstone (copied verbatim from `/data/tombstones/` on the AVD):

```
signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x00007ffdf418dff8 (write)
Cause: stack pointer is close to top of stack; likely stack overflow.
backtrace:
      #00 pc 00000000000062d6  /data/local/tmp/libhardened_malloc.so (__emutls_get_address+6)
      #01 pc 00000000000072ea  /data/local/tmp/libhardened_malloc.so (malloc+26)
      #02 pc 00000000000063c8  /data/local/tmp/libhardened_malloc.so (__emutls_get_address+248)
      #03 pc 00000000000072ea  /data/local/tmp/libhardened_malloc.so (malloc+26)
      ... (mutual recursion to stack exhaustion)
```

Diagnosis: at `minSdkLevel < 29` the NDK compiles `__thread`/`thread_local`
to `__emutls_get_address`; bionic's emutls allocates through (interposed)
malloc; hardened_malloc's allocator state is itself thread-local → infinite
recursion. Fix: build with `API=29` (native ELF TLS for shared libraries).
Verification: rebuilt artifacts contain **zero** `__emutls*` dynamic symbols
(`llvm-nm -D`).

## §2 — mprotect EINVAL from dropped `alignas` (toolchain finding)

After the API fix, first allocation aborted:

```
MPLOG FAIL addr=0x72762a20ed98 len=3072 prot=3 errno=22
hardened_malloc: fatal allocator error: non-ENOMEM mprotect failure
```

(3072 = 128 × 24 = `INITIAL_REGION_TABLE_SIZE × sizeof(struct region_metadata)`;
errno 22 = EINVAL — address not page-aligned: `addr & 4095 == 3480`.)

Instrumented build (temporary edit of the cached clone, reverted before the
final clean rebuild) showed the preceding init call:

```
MPROT ptr=0x72a6f2138000 size=328  prot=3 ret=0 errno=0 align=0
MPROT ptr=0x72762a20ed98 size=3072 prot=3 ret=1 errno=22 align=3480
```

`offsetof(struct allocator_state, regions_a)` came out **328** — upstream's
`alignas(PAGE_SIZE)` member alignment never applied. Root cause pinned by
compile-time probes (`emulator/alignas_probe.c`, `emulator/alignas_probe2.c`):

- `alignas(4096)` on a struct member produces a FieldDecl with **no
  alignment attribute** under NDK r28 clang 19.0.1, in every `-std` mode
  (the AST was inspected: no AlignedAttr reaches the field);
- `_Alignas(4096)` in the identical position works under every `-std` mode.

Fix: `-Dalignas=_Alignas` (labeled deviation, recorded in each artifact's
`meta.json`). Upstream sources unmodified.

## §3 — first green run (20260927-234546)

```
[smoke.sh] interposed mode: ok=1 narenas=5
[smoke.sh] dlopen mode: ok=1 narenas=0
[smoke.sh] SELinux at entry: Enforcing
[smoke.sh] retrying wrap demo with temporary permissive mode (userdebug image, restored after)
[smoke.sh] wrap demo: pass — pid 7434 alive with libhardened_malloc mapped (3 regions)
[smoke.sh] ALL PASS — results in results/emulator/20260927-234546
```

- `interposed.out`: `ANVIL_SMOKE_RESULT mode=interposed ok=1 narenas=5`
  (stats-gated probe answered through the interposed allocator; stock scudo
  cannot provide it).
- `dlopen.out`: refused with `TLS symbol ... using IE access model` — the
  upstream-faithful `tls_model("initial-exec")` signature (h_malloc.c:65).
  Preload-at-exec is the only load path.
- `wrap.out`: `selinux_entry=Enforcing status=pass note=pid 7434 alive with
  libhardened_malloc mapped (3 regions)`; `selinux_final.txt`: `Enforcing`.

## Known-honest limits of this campaign

- Kernel: stock `6.12.38-android16-5-gbb9513914902` goldfish; **no Anvil
  kernel fragment was executed** — fragments remain compile-validated only.
- aarch64 artifacts: compile-checked, never executed (x86_64 emulator).
- No C++ operator-new interposition claimed (linker namespaces).
- The wrap demo's temporary permissive SELinux is a test-harness detail;
  entry/exit states are recorded in every run's artifacts.
