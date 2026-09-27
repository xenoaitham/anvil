#!/usr/bin/env bash
# Anvil hardened_malloc integration build — Android (NDK / bionic) targets.
#
# Sibling of build.sh (host glibc). Same pinned upstream source, same stamp
# discipline, same provenance rules. Builds with the Android NDK's clang for
# bionic, using upstream's own Makefile and config/*.mk files unmodified —
# every deviation is an explicit make-variable override recorded in meta.json.
#
# Artifacts: build/hmalloc-android/<abi>-<config>/
#   libhardened_malloc[-light].so, build.log, meta.json
#
# Deliberate, labeled deviations from upstream's host configuration:
#   * CONFIG_CXX_ALLOCATOR=false on every Android artifact: upstream links
#     -lstdc++, which does not exist in the NDK (bionic ships libc++), and
#     C++ operator-new interposition across Android's linker namespaces is
#     not claimed by this milestone. malloc/calloc/realloc/aligned/freeze
#     surface is what LD_PRELOAD interposes on Android.
#   * CONFIG_NATIVE=false on every Android artifact: -march=native is the
#     host CPU; it is wrong for cross builds (an aarch64 artifact built with
#     it carries x86 codegen) and non-reproducible for the x86_64 ones.
#   * <async_safe/log.h> is provided by ndk-shim/ (passed via CPATH so
#     upstream's Makefile stays fully in charge of its own CPPFLAGS; the
#     AOSP build uses libasyncsafe instead).
#   * CFLAGS=-Dalignas=_Alignas: NDK r28 clang 19.0.1 in C23 mode silently
#     drops bare `alignas` on struct members (no attribute reaches the AST),
#     which collapses struct allocator_state's page-aligned regions_a/b to
#     offset 328 — the init-time mprotect of the regions table then gets
#     EINVAL on an unaligned address and the allocator aborts on its first
#     allocation (evidence: results/emulator/, probe:
#     emulator/alignas_probe2.c). _Alignas is the C23 keyword form and is
#     honored; -D replaces the spelling without touching upstream sources.
#   * the <abi>-default-proof artifact additionally builds CONFIG_STATS=true
#     (mallinfo probes are #if CONFIG_STATS upstream) and drops -z nodlopen
#     from LDFLAGS so the .so can be dlopen()ed for the direct-load proof.
#     It is a test instrument, not an integration artifact.
#
# Toolchain: upstream requires clang >= 19.1.7, so this script requires an
# NDK whose clang is >= 19 (NDK r28 or newer; r27's clang 18.0.3 fails
# -Werror on bionic paths).
#
# Exit status: 0 only if every selected artifact built successfully.

set -euo pipefail

# ---------------------------------------------------------------------------
# Same source pin as build.sh — keep these in sync (checked at runtime).
# ---------------------------------------------------------------------------
readonly HMALLOC_SHA='01df350c62441e163a8b9324fb7e156acdad2c1e'
readonly UPSTREAM_URL='https://github.com/GrapheneOS/hardened_malloc.git'

readonly ANVIL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly HERE="${ANVIL_ROOT}/integration/hardened_malloc"
readonly REF_DIR="${ANVIL_ROOT}/../ref/hardened_malloc"
readonly CACHE_DIR="${ANVIL_ROOT}/.cache"
readonly SRC_DIR="${CACHE_DIR}/upstream-hardened_malloc"
readonly OUT_BASE="${ANVIL_ROOT}/build/hmalloc-android"
readonly JOBS=8

readonly DEFAULT_NDK="${ANDROID_NDK_HOME:-/mnt/NewVolume/anvil-sdk/ndk/28.2.13676358}"
readonly SHIM_DIR="$HERE/ndk-shim"

# ABI triple -> NDK minSdkLevel 28 (getrandom(2) requires API 28; the target
# emulator image is API 36, so 28 is safe for both build and run).
declare -A TRIPLE=(
    [x86_64]=x86_64-linux-android
    [aarch64]=aarch64-linux-android
)
# minSdkLevel 29: below 29 the NDK compiles __thread/thread_local to
# __emutls_get_address, and bionic's emutls allocates through (interposed)
# malloc — with hardened_malloc serving malloc, that recurses infinitely and
# overflows the stack (tombstone evidence: results/emulator/). API 29+ uses
# native ELF TLS for shared libraries. The smoke target emulator is API 36.
readonly API=29

ABI_SEL='x86_64'          # x86_64 | aarch64 | all
CONFIG_SEL='both'         # default | light | both
PROOF=0                   # 1 = also build the labeled stats/nodlopen proof artifact
FORCE=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [--abi x86_64|aarch64|all] [--config default|light|both]
                       [--proof] [--force] [NDK_HOME=<path>]

  --abi      target ABI axis (default: x86_64 — the emulator-runnable one)
  --config   upstream VARIANT: default, light, or both (default: both)
  --proof    additionally build <abi>-default-proof (CONFIG_STATS=true, no
             -z nodlopen) used by the on-device smoke test
  --force    rebuild even if the stamp matches
  NDK_HOME   env or argument-style prefix; default: $DEFAULT_NDK
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --abi)    ABI_SEL="$2"; shift 2 ;;
        --config) CONFIG_SEL="$2"; shift 2 ;;
        --proof)  PROOF=1; shift ;;
        --force)  FORCE=1; shift ;;
        NDK_HOME=*) NDK_HOME="${1#NDK_HOME=}" ;;
        -h|--help) usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done
NDK_HOME="${NDK_HOME:-$DEFAULT_NDK}"

log()  { printf '[build-android.sh] %s\n' "$*"; }
fail() { printf '[build-android.sh] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# NDK toolchain resolution.
# ---------------------------------------------------------------------------
[[ -d "$NDK_HOME/toolchains/llvm" ]] || fail "NDK not found at $NDK_HOME (set NDK_HOME)"
NDK_CLANG_BIN="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
[[ -x "$NDK_CLANG_BIN/clang" ]] || fail "no clang in $NDK_CLANG_BIN"
NDK_VERSION="$(grep -oE '[0-9]+(\.[0-9]+)+' "$NDK_HOME/source.properties" | head -n1)"
CLANG_MAJOR="$("$NDK_CLANG_BIN/clang" -dumpversion | cut -d. -f1)"
[ "$CLANG_MAJOR" -ge 19 ] || fail "NDK clang $("$NDK_CLANG_BIN/clang" -dumpversion) < 19 (upstream minimum 19.1.7; use NDK r28+)"
log "NDK $NDK_VERSION (clang $("$NDK_CLANG_BIN/clang" -dumpversion)) at $NDK_HOME"
# adapter env (ndk-aarch64-cc) — exported before any wrapper invocation so
# version probes and builds see the same driver
export NDK_AARCH64_CLANG="$NDK_CLANG_BIN/${TRIPLE[aarch64]}${API}-clang"

cc_for() {
    # aarch64 goes through the labeled adapter (see ndk-aarch64-cc).
    if [ "$1" = "aarch64" ]; then
        printf '%s' "$HERE/ndk-aarch64-cc"
    else
        printf '%s' "$NDK_CLANG_BIN/${TRIPLE[$1]}${API}-clang"
    fi
}

# ---------------------------------------------------------------------------
# Source acquisition at the pinned commit — shares the cache with build.sh.
# ---------------------------------------------------------------------------
ensure_source() {
    mkdir -p "$CACHE_DIR"
    if [[ -d "$SRC_DIR/.git" ]]; then
        local head
        head="$(git -C "$SRC_DIR" rev-parse HEAD)"
        if [[ "$head" != "$HMALLOC_SHA" ]]; then
            log "cache HEAD $head != pin $HMALLOC_SHA; re-cloning"
            rm -rf "$SRC_DIR"
        fi
    fi
    if [[ ! -d "$SRC_DIR/.git" ]]; then
        if [[ -d "$REF_DIR/.git" ]]; then
            local ref_head
            ref_head="$(git -C "$REF_DIR" rev-parse HEAD)"
            [[ "$ref_head" == "$HMALLOC_SHA" ]] \
                || fail "local ref HEAD $ref_head != pinned $HMALLOC_SHA (ref moved; update HMALLOC_SHA)"
            log "cloning pinned source from local ref $REF_DIR"
            git clone --quiet "$REF_DIR" "$SRC_DIR"
        else
            log "cloning from upstream $UPSTREAM_URL"
            git clone --quiet "$UPSTREAM_URL" "$SRC_DIR"
        fi
    fi
    local head
    head="$(git -C "$SRC_DIR" rev-parse HEAD)"
    [[ "$head" == "$HMALLOC_SHA" ]] \
        || fail "cloned HEAD $head != pinned $HMALLOC_SHA"
    log "upstream pinned at $HMALLOC_SHA"
}

# $1=abi  $2=config(default|light)  $3=proof(0|1)
build_one() {
    local abi="$1" cfg="$2" proof="$3"
    local id="${abi}-${cfg}$([[ $proof -eq 1 ]] && printf -- '-proof')"
    local outdir="${OUT_BASE}/${id}"
    local stamp="${outdir}/.build-stamp"
    local cc; cc="$(cc_for "$abi")"
    local ccver; ccver="$("$cc" --version 2>/dev/null | head -n1)"
    local stamp_expect="${HMALLOC_SHA}|ndk-${NDK_VERSION}|api-${API}|${cfg}|proof-${proof}|alignas-fix"

    if [[ $FORCE -eq 0 && -f "$stamp" ]] && [[ "$(cat "$stamp")" == "$stamp_expect" ]]; then
        log "SKIP ${id} (stamp matches; --force to rebuild)"
        SUMMARY_ROWS+=("${id}|cached|${ccver}")
        return 0
    fi

    log "building ${id}"
    mkdir -p "$outdir"
    rm -rf "$SRC_DIR/out" "$SRC_DIR/out-light"

    local make_args=(CC="$cc" VARIANT="$cfg" CONFIG_CXX_ALLOCATOR=false \
        CONFIG_NATIVE=false)

    # LDFLAGS mirrors upstream's list exactly (a command-line LDFLAGS replaces
    # upstream's, so the content must match); the NDK driver only accepts -z
    # inside the -Wl token, and the proof variant drops nodlopen so dlopen()
    # can load it.
    local ldflags='-Wl,-O1,--as-needed,-z,defs,-z,relro,-z,now,-z,text'
    if [[ $proof -eq 1 ]]; then
        make_args+=(CONFIG_STATS=true LDFLAGS="$ldflags")
    else
        make_args+=(LDFLAGS="$ldflags,-z,nodlopen")
    fi

    local logf="${outdir}/build.log"
    if ! ( cd "$SRC_DIR" && CPATH="$SHIM_DIR" \
            CFLAGS="-Dalignas=_Alignas" \
            make -j"$JOBS" "${make_args[@]}" ) >"$logf" 2>&1; then
        tail -n 25 "$logf" >&2 || true
        printf '[build-android.sh] ERROR: build failed for %s; full log: %s\n' "$id" "$logf" >&2
        SUMMARY_ROWS+=("${id}|FAILED|${ccver}")
        return 1
    fi

    local suffix="" outdir_up="out"
    [[ "$cfg" != "default" ]] && suffix="-${cfg}" && outdir_up="out-${cfg}"
    local libpath="$SRC_DIR/${outdir_up}/libhardened_malloc${suffix}.so"
    if [[ ! -f "$libpath" ]]; then
        printf '[build-android.sh] ERROR: expected artifact %s missing for %s\n' "$libpath" "$id" >&2
        SUMMARY_ROWS+=("${id}|FAILED|${ccver}")
        return 1
    fi
    cp -f "$libpath" "$outdir/libhardened_malloc${suffix}.so"

    python3 - "$outdir/meta.json" "$HMALLOC_SHA" "$id" "$cc" "$ccver" "$cfg" "$proof" "$abi" "$API" <<'PY'
import json, sys
out, sha, ident, cc, ccver, cfg, proof, abi, api = sys.argv[1:10]
triple = {"x86_64": "x86_64-linux-android", "aarch64": "aarch64-linux-android"}[abi]
json.dump({
    "id": ident, "upstream_sha": sha, "upstream_url":
    "https://github.com/GrapheneOS/hardened_malloc", "config_variant": cfg,
    "proof_variant": proof == "1",
    "cc": cc, "cc_version": ccver,
    "ndk": True,
    "target": f"{triple}-{api} (NDK r28, bionic; native ELF TLS requires API >= 29)",
    "deviations": ["CONFIG_CXX_ALLOCATOR=false (NDK has no libstdc++; bionic interposition scope is malloc-family)",
                   "CONFIG_NATIVE=false (cross build: -march=native is host-only)",
                   "async_safe/log.h via ndk-shim/ (CPATH; AOSP builds use libasyncsafe)",
                   "-Dalignas=_Alignas (NDK clang 19 C23 silently drops bare alignas on members)"]
                   + (["aarch64: -fcf-protection=none adapter (upstream preprocess probe passes, codegen rejects on aarch64)"] if abi == "aarch64" else [])
                   + (["CONFIG_STATS=true", "-z nodlopen dropped (dlopen test instrument)"] if proof == "1" else []),
    "artifact": "libhardened_malloc" + ("" if cfg == "default" else "-" + cfg) + ".so",
}, open(out, "w"), indent=2)
PY
    printf '%s\n' "$stamp_expect" > "$stamp"
    SUMMARY_ROWS+=("${id}|built|${ccver}")
}

# ---------------------------------------------------------------------------

case "$ABI_SEL" in
    x86_64|aarch64) ABIS=("$ABI_SEL") ;;
    all)            ABIS=(x86_64 aarch64) ;;
    *) fail "bad --abi '$ABI_SEL'" ;;
esac
case "$CONFIG_SEL" in
    default|light|both) ;;
    *) fail "bad --config '$CONFIG_SEL'" ;;
esac

ensure_source

CONFIGS=()
[[ "$CONFIG_SEL" != "light"  ]] && CONFIGS+=(default)
[[ "$CONFIG_SEL" != "default" ]] && CONFIGS+=(light)

declare -a SUMMARY_ROWS=()

rc=0
for abi in "${ABIS[@]}"; do
    for cfg in "${CONFIGS[@]}"; do
        build_one "$abi" "$cfg" 0 || rc=1
    done
    if [[ $PROOF -eq 1 ]]; then
        build_one "$abi" default 1 || rc=1
    fi
done

printf '\n=== hardened_malloc build summary (Android, NDK %s, bionic) ===\n' "$NDK_VERSION"
printf '%-24s %-8s %s\n' 'ARTIFACT' 'STATUS' 'COMPILER'
for row in "${SUMMARY_ROWS[@]}"; do
    IFS='|' read -r id status ver <<<"$row"
    printf '%-24s %-8s %s\n' "$id" "$status" "$ver"
done
printf 'pin: %s\nartifacts: %s\n' "$HMALLOC_SHA" "$OUT_BASE"

exit "$rc"
