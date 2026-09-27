#!/usr/bin/env bash
# Anvil hardened_malloc benchmark driver.
#
# INVENTORY HONESTY (read this first): upstream GrapheneOS/hardened_malloc
# ships NO benchmark harness. Verified against the pinned tree:
#   * third_party/ contains only libdivide.h (build-time dependency).
#   * `calculate-waste` is a static size-class fragmentation table
#     generator (python, no allocation happens).
#   * The README ("Introduction") explicitly optimizes for "long-term
#     performance and memory usage rather than allocator micro-benchmarks".
# Therefore nothing upstream can be "run natively" as a benchmark. What
# upstream DOES provide and sanction is LD_PRELOAD replacement
# (preload.sh, README "Traditional Linux-based operating systems"). That is
# allocator-agnostic by construction, so Anvil runs ONE fixed workload
# binary (bench/malloc_bench.c, identical allocation sequences via
# fixed-seed PRNGs) against:
#   * glibc malloc         (native, no preload)         <- baseline
#   * hardened_malloc default  (LD_PRELOAD)
#   * hardened_malloc light    (LD_PRELOAD)
# The binary is compiled once with gcc -O2 and never recompiled per
# allocator. No numbers are invented; every mean/stdev comes from the
# repeats recorded in the JSON.
#
# Output: results/hmalloc/bench-<UTCdate>-x86_64.json (+ raw logs under
# results/hmalloc/logs/). Exit 0 only if every run completed.

set -euo pipefail

readonly ANVIL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
readonly HERE="${ANVIL_ROOT}/integration/hardened_malloc"
readonly BENCH="${HERE}/bench"
readonly SRC_DIR="${ANVIL_ROOT}/.cache/upstream-hardened_malloc"
readonly RESULTS="${ANVIL_ROOT}/results/hmalloc"
readonly LOGS="${RESULTS}/logs"
readonly DATE="$(date -u +%Y%m%d)"
readonly OUT_BASE="${ANVIL_ROOT}/build/hmalloc"

REPEATS=5
OPS=2000000
WARMUP=1

usage() {
    cat <<EOF
Usage: $(basename "$0") [--repeats N] [--ops N]

  --repeats  timed repetitions per allocator (default 5; 1 untimed warmup)
  --ops      base operations per phase (default 2000000)
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repeats) REPEATS="$2"; shift 2 ;;
        --ops)     OPS="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

log()  { printf '[run_bench.sh] %s\n' "$*"; }
fail() { printf '[run_bench.sh] ERROR: %s\n' "$*" >&2; exit 1; }

mkdir -p "$LOGS" "$BENCH/bin"

# --- build the workload binary once (allocator-agnostic) --------------------
CC_BIN=gcc
command -v "$CC_BIN" >/dev/null || fail "gcc not found for bench binary"
log "compiling bench binary with $CC_BIN -O2 (allocator-agnostic, built once)"
"$CC_BIN" -O2 -std=c11 -Wall -Wextra -o "$BENCH/bin/malloc_bench" \
    "$BENCH/malloc_bench.c" -lpthread 2>"$LOGS/bench-build.log" \
    || { cat "$LOGS/bench-build.log" >&2; fail "bench binary build failed"; }

# --- locate allocator artifacts (must come from build.sh) -------------------
declare -a LABELS SO_PRELOADS
LABELS=("glibc"); SO_PRELOADS=("")

for cfg in default light; do
    so="libhardened_malloc.so"
    [[ "$cfg" != "default" ]] && so="libhardened_malloc-${cfg}.so"
    dir=""
    for cc in clang gcc-14 gcc; do
        [[ -f "$OUT_BASE/$cc-$cfg/$so" ]] && { dir="$OUT_BASE/$cc-$cfg"; break; }
    done
    [[ -n "$dir" ]] || fail "no $cfg .so under build/hmalloc; run ../../build.sh first"
    LABELS+=("hmalloc-$cfg"); SO_PRELOADS+=("$dir/$so")
done

HM_SHA="$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"

# --- run --------------------------------------------------------------------
rawbase="$LOGS/bench-${DATE}-x86_64"
for i in "${!LABELS[@]}"; do
    label="${LABELS[$i]}"
    preload="${SO_PRELOADS[$i]}"
    log "benchmarking allocator: $label (warmup $WARMUP + $REPEATS timed)"
    if [[ -n "$preload" ]]; then
        run_env=("LD_PRELOAD=$preload")
    else
        run_env=()
    fi
    # warmup (untimed, discarded)
    env "${run_env[@]+"${run_env[@]}"}" "$BENCH/bin/malloc_bench" "$OPS" \
        >/dev/null 2>&1 || true
    for r in $(seq 1 "$REPEATS"); do
        env "${run_env[@]+"${run_env[@]}"}" "$BENCH/bin/malloc_bench" "$OPS" \
            > "${rawbase}-${label}.run${r}.txt" 2>&1 \
            || fail "$label run $r failed; see ${rawbase}-${label}.run${r}.txt"
    done
done

# --- aggregate into JSON -----------------------------------------------------
jsonf="${RESULTS}/bench-${DATE}-x86_64.json"
python3 - "$jsonf" "$rawbase" "$REPEATS" "$OPS" "$HM_SHA" "$DATE" <<'PY'
import glob, json, os, platform, re, statistics, subprocess, sys, datetime

jsonf, rawbase, repeats, ops, sha, date = sys.argv[1:8]
repeats = int(repeats); ops = int(ops)

def sh(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True,
                                       stderr=subprocess.DEVNULL).strip()
    except Exception:
        return None

PHASES = ["small_churn", "medium_churn", "large_churn",
          "realloc_pattern", "calloc_zero", "thread_churn"]

allocators = {}
for path in sorted(glob.glob(rawbase + "-*.run*.txt")):
    m = re.match(re.escape(rawbase) + r"-(.+)\.run(\d+)\.txt$", path)
    if not m:
        continue
    label = m.group(1)
    run = {}
    for line in open(path):
        mm = re.match(r"phase (\S+) ops (\d+) seconds ([\d.]+) ops_per_sec ([\d.]+)", line)
        if mm:
            run[mm.group(1)] = {"ops": int(mm.group(2)),
                                "seconds": float(mm.group(3)),
                                "ops_per_sec": float(mm.group(4))}
    allocators.setdefault(label, []).append(run)

out = {
    "schema": "anvil.hmalloc.bench/1",
    "date_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "workload": {
        "source": "integration/hardened_malloc/bench/malloc_bench.c",
        "binary_built_with": "gcc -O2 -std=c11 (built once, allocator-agnostic)",
        "allocator_selection": "LD_PRELOAD (upstream's documented preload.sh mode); glibc baseline = same binary unpreloaded",
        "determinism": "fixed-seed xorshift64* PRNGs; identical allocation sequences across allocators",
        "phases": PHASES,
        "ops_base": ops,
        "repeats_timed": repeats,
        "warmup_runs_discarded": 1,
    },
    "upstream": {
        "url": "https://github.com/GrapheneOS/hardened_malloc",
        "sha": sha,
        "note": "upstream ships no benchmark harness; see run_bench.sh header for inventory",
    },
    "machine": {
        "arch": platform.machine(),
        "kernel": platform.release(),
        "cpu": sh("lscpu | grep 'Model name' | sed 's/.*: *//'"),
        "cpus": sh("nproc"),
        "mem_gib": sh("free -g | awk 'NR==2{print $2}'"),
        "os": sh("lsb_release -ds") or platform.platform(),
        "governor_note": "portable desktop, no run-to-run thermal isolation; expect single-digit-% variance",
    },
    "results": {},
}

for label, runs in allocators.items():
    per_phase = {}
    for phase in PHASES:
        vals = [r[phase]["ops_per_sec"] for r in runs if phase in r]
        secs = [r[phase]["seconds"] for r in runs if phase in r]
        if not vals:
            continue
        mean = statistics.fmean(vals)
        st = statistics.stdev(vals) if len(vals) > 1 else 0.0
        per_phase[phase] = {
            "n": len(vals),
            "ops": runs[0][phase]["ops"],
            "ops_per_sec_mean": round(mean, 1),
            "ops_per_sec_stdev": round(st, 1),
            "ops_per_sec_min": round(min(vals), 1),
            "ops_per_sec_max": round(max(vals), 1),
            "cv_pct": round(100.0 * st / mean, 2) if mean else None,
            "seconds_mean": round(statistics.fmean(secs), 6),
        }
    out["results"][label] = {"runs_recorded": len(runs), "phases": per_phase}

# relative view vs glibc for quick reading
if "glibc" in out["results"]:
    base = out["results"]["glibc"]["phases"]
    for label in out["results"]:
        if label == "glibc":
            continue
        rel = {}
        for phase, s in out["results"][label]["phases"].items():
            b = base.get(phase)
            if b and b["ops_per_sec_mean"]:
                rel[phase] = round(s["ops_per_sec_mean"] / b["ops_per_sec_mean"], 3)
        out["results"][label]["ratio_vs_glibc"] = rel

json.dump(out, open(jsonf, "w"), indent=2)
print(f"wrote {jsonf}")
for label in out["results"]:
    r = out["results"][label]
    sm = r["phases"].get("small_churn", {}).get("ops_per_sec_mean")
    print(f"  {label:16s} small_churn mean {sm:,.0f} ops/s over {r['runs_recorded']} runs")
PY

log "done: $jsonf"
