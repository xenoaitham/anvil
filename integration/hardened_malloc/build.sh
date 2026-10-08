#!/usr/bin/env bash
# Anvil hardened_malloc integration build.
#
# Clones upstream GrapheneOS/hardened_malloc at a PINNED commit (never a fork,
# never a moving ref) and builds NATIVE glibc artifacts (host arch detected
# via `uname -m`: x86_64 locally/CI, aarch64 on arm64 runners) for the
# {clang, gcc} x {default, light} configuration matrix, using upstream's own
# Makefile and config/*.mk files unmodified.
#
# Artifacts: build/hmalloc/<compiler>-<config>/
#   libhardened_malloc[-light].so, build.log, meta.json
#
# Idempotent: a variant is rebuilt only when its .build-stamp (pinned SHA +
# resolved compiler version + config) changes. Use --force to rebuild anyway.
#
# Exit status: 0 only if every selected variant built successfully.

set -euo pipefail

# ---------------------------------------------------------------------------
# Pin: exact HEAD of /home/potato/grafene/ref/hardened_malloc at integration
# time (GrapheneOS/hardened_malloc, 2026-09-25, "fix 0 size allocations with
# >PAGE_SIZE alignment for !CONFIG_LARGE_SIZE_CLASSES").
# ---------------------------------------------------------------------------
readonly HMALLOC_SHA='01df350c62441e163a8b9324fb7e156acdad2c1e'
readonly UPSTREAM_URL='https://github.com/GrapheneOS/hardened_malloc.git'

readonly ANVIL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly HERE="${ANVIL_ROOT}/integration/hardened_malloc"
readonly REF_DIR="${ANVIL_ROOT}/../ref/hardened_malloc"
readonly CACHE_DIR="${ANVIL_ROOT}/.cache"
readonly SRC_DIR="${CACHE_DIR}/upstream-hardened_malloc"
readonly OUT_BASE="${ANVIL_ROOT}/build/hmalloc"
readonly JOBS=8   # -j8 keeps LTO comfortable on 4-12 core hosts
readonly HOST_ARCH="$(uname -m)"   # honest provenance: x86_64 | aarch64 | ...

VARIANT_SEL='all'   # clang | gcc | all  (compiler axis)
CONFIG_SEL='both'   # default | light | both
FORCE=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [--variant clang|gcc|all] [--config default|light|both] [--force]

  --variant   compiler axis: clang, gcc, or all (default: all)
  --config    upstream VARIANT: default, light, or both (default: both)
  --force     rebuild even if the stamp matches
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --variant) VARIANT_SEL="$2"; shift 2 ;;
        --config)  CONFIG_SEL="$2";  shift 2 ;;
        --force)   FORCE=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

log()  { printf '[build.sh] %s\n' "$*"; }
fail() { printf '[build.sh] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Toolchain resolution. Upstream requires clang >= 19.1.7 or gcc >= 14.2.0 and
# builds with -std=c23; this machine has clang 18.1.3 / gcc 13.3 (default) /
# gcc 14.2 (installed as gcc-14). clang 18 accepts -std=c23 and builds the
# tree cleanly; gcc 13 does not, so the gcc slot probes for a -std=c23-capable
# gcc and prefers the newest. gcc 14.2.0 == upstream's stated minimum.
# ---------------------------------------------------------------------------
pick_clang() {
    local c
    for c in clang clang-18 clang-17 clang-16; do
        if command -v "$c" >/dev/null 2>&1; then
            printf '%s' "$c"; return 0
        fi
    done
    return 1
}

# echo "<newest c23-capable gcc>"; empty on failure
pick_gcc() {
    local c v
    for v in 15 14 13 12; do
        for c in "gcc-$v" gcc; do
            command -v "$c" >/dev/null 2>&1 || continue
            # probe: reject gcc that cannot even accept -std=c23
            if echo 'int main(void){return 0;}' | "$c" -std=c23 -E -x c - >/dev/null 2>&1; then
                printf '%s' "$c"; return 0
            fi
        done
        # if plain `gcc` was c23-capable we already returned; otherwise do not
        # fall through to older explicit versions after the newest failed
    done
    return 1
}

# map CC to the matching C++ driver (upstream forces CXX := CC for LTO, but
# we still pass an explicit matching CXX for clarity)
cxx_for() {
    case "$1" in
        clang)    echo clang++ ;;
        clang-*)  echo "${1/clang/clang++}" ;;
        gcc)      echo g++ ;;
        gcc-*)    echo "${1/gcc/g++}" ;;
        *)        echo "" ;;
    esac
}

ver_of() { "$1" --version 2>/dev/null | head -n1; }

# ---------------------------------------------------------------------------
# Source acquisition at the pinned commit.
# ---------------------------------------------------------------------------
ensure_source() {
    mkdir -p "$CACHE_DIR"
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
    # Upstream's default branch moves; the clone must be switched to the PIN
    # (fetch-by-SHA), not merely verified to accidentally start there.
    local head
    head="$(git -C "$SRC_DIR" rev-parse HEAD)"
    if [[ "$head" != "$HMALLOC_SHA" ]]; then
        log "tree HEAD $head != pin $HMALLOC_SHA; checking out the pinned commit"
        git -C "$SRC_DIR" fetch --quiet origin "$HMALLOC_SHA" \
            || fail "could not fetch pinned $HMALLOC_SHA from $UPSTREAM_URL (SHA unreachable upstream?)"
        git -C "$SRC_DIR" checkout --quiet --detach FETCH_HEAD
    fi
    head="$(git -C "$SRC_DIR" rev-parse HEAD)"
    [[ "$head" == "$HMALLOC_SHA" ]] \
        || fail "checked-out HEAD $head != pinned $HMALLOC_SHA"
    log "upstream pinned at $HMALLOC_SHA"
}

# ---------------------------------------------------------------------------
# One build = one (compiler, config) pair, executed in the shared clone with a
# scrubbed tree (upstream's out/ path depends on VARIANT, but switching CC
# without cleaning would silently reuse foreign objects).
# ---------------------------------------------------------------------------
build_one() { # $1=cc  $2=config(default|light)
    local cc="$1" cfg="$2"
    local cxx; cxx="$(cxx_for "$cc")"
    local id="${cc}-${cfg}"
    local outdir="${OUT_BASE}/${id}"
    local stamp="${outdir}/.build-stamp"

    local ccver; ccver="$(ver_of "$cc")"
    local stamp_expect="${HMALLOC_SHA}|${ccver}"

    if [[ $FORCE -eq 0 && -f "$stamp" ]] && [[ "$(cat "$stamp")" == "$stamp_expect" ]]; then
        log "SKIP ${id} (stamp matches; --force to rebuild)"
        SUMMARY_ROWS+=("${id}|cached|${ccver}")
        return 0
    fi

    log "building ${id} (make -j${JOBS}$( [[ $cfg != default ]] && printf ' VARIANT=%s' "$cfg" ))"
    mkdir -p "$outdir"
    rm -rf "$SRC_DIR/out" "$SRC_DIR/out-light"

    local make_args=(CC="$cc" CXX="$cxx")
    [[ "$cfg" != "default" ]] && make_args+=("VARIANT=$cfg")

    local logf="${outdir}/build.log"
    if ! ( cd "$SRC_DIR" && make -j"$JOBS" "${make_args[@]}" ) >"$logf" 2>&1; then
        tail -n 25 "$logf" >&2 || true
        printf '[build.sh] ERROR: build failed for %s; full log: %s\n' "$id" "$logf" >&2
        SUMMARY_ROWS+=("${id}|FAILED|${ccver}")
        return 1
    fi

    local lib="libhardened_malloc.so"
    local outdir_up="out"   # upstream: OUT := out$(SUFFIX), SUFFIX := -<VARIANT>
    if [[ "$cfg" != "default" ]]; then
        lib="libhardened_malloc-${cfg}.so"
        outdir_up="out-${cfg}"
    fi
    local libpath="$SRC_DIR/${outdir_up}/$lib"
    if [[ ! -f "$libpath" ]]; then
        printf '[build.sh] ERROR: expected artifact %s missing for %s\n' "$libpath" "$id" >&2
        SUMMARY_ROWS+=("${id}|FAILED|${ccver}")
        return 1
    fi
    cp -f "$libpath" "$outdir/$lib"

    # machine-readable provenance for every artifact
    python3 - "$outdir/meta.json" "$HMALLOC_SHA" "$id" "$cc" "$cxx" "$ccver" "$cfg" "$HOST_ARCH" <<'PY'
import json, sys
out, sha, ident, cc, cxx, ccver, cfg, arch = sys.argv[1:9]
json.dump({
    "id": ident, "upstream_sha": sha, "upstream_url":
    "https://github.com/GrapheneOS/hardened_malloc", "config_variant": cfg,
    "cc": cc, "cxx": cxx, "cc_version": ccver,
    "target": arch + "-pc-linux-gnu (native, glibc)",
    "artifact": "libhardened_malloc" + ("" if cfg == "default" else "-" + cfg) + ".so",
}, open(out, "w"), indent=2)
PY
    printf '%s\n' "$stamp_expect" > "$stamp"
    SUMMARY_ROWS+=("${id}|built|${ccver}")
}

# ---------------------------------------------------------------------------

[[ -d "$REF_DIR/.git" ]] || log "NOTE: local ref $REF_DIR absent; will clone from GitHub"

CLANG_CC="$(pick_clang || true)"
GCC_CC="$(pick_gcc || true)"

declare -a SUMMARY_ROWS=()
declare -a TARGETS=()

case "$VARIANT_SEL" in
    clang) [[ -n "$CLANG_CC" ]] || fail "no usable clang on PATH"; TARGETS+=("$CLANG_CC") ;;
    gcc)   [[ -n "$GCC_CC"   ]] || fail "no c23-capable gcc (need gcc >= 14: try gcc-14)"; TARGETS+=("$GCC_CC") ;;
    all)   [[ -n "$CLANG_CC" ]] || fail "no usable clang on PATH"
           [[ -n "$GCC_CC"   ]] || fail "no c23-capable gcc (need gcc >= 14: try gcc-14)"
           TARGETS+=("$CLANG_CC" "$GCC_CC") ;;
    *) fail "bad --variant '$VARIANT_SEL'" ;;
esac

case "$CONFIG_SEL" in
    default|light|both) ;;
    *) fail "bad --config '$CONFIG_SEL'" ;;
esac

ensure_source

CONFIGS=()
[[ "$CONFIG_SEL" != "light"  ]] && CONFIGS+=(default)
[[ "$CONFIG_SEL" != "default" ]] && CONFIGS+=(light)

rc=0
for cc in "${TARGETS[@]}"; do
    for cfg in "${CONFIGS[@]}"; do
        build_one "$cc" "$cfg" || rc=1
    done
done

# summary table
printf '\n=== hardened_malloc build summary (%s native, glibc) ===\n' "$HOST_ARCH"
printf '%-18s %-8s %s\n' 'VARIANT' 'STATUS' 'COMPILER'
for row in "${SUMMARY_ROWS[@]}"; do
    IFS='|' read -r id status ver <<<"$row"
    printf '%-18s %-8s %s\n' "$id" "$status" "$ver"
done
printf 'pin: %s\nartifacts: %s\n' "$HMALLOC_SHA" "$OUT_BASE"

exit "$rc"
