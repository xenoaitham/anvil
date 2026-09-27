#!/usr/bin/env bash
# Anvil hardened_malloc test runner.
#
# Runs upstream's own test suite for real, per compiler:
#   1. builds the default-config libhardened_malloc.so with the chosen CC
#      (via ../build.sh --variant <cc> --config default)
#   2. `make -C test/` builds the per-API test binaries (upstream's test
#      Makefile links them against ../out/libhardened_malloc.so with -R)
#   3. `python3 -m unittest discover -v test/` drives every binary and checks
#      exit codes / stderr messages (this is upstream's `make test` backend)
#
# NOTE: upstream's test/Makefile hard-rejects non-default variants
# ("testing non-default variants not yet supported"), so tests only run
# against the default config. Documented, not worked around.
#
# Outputs:
#   results/hmalloc/tests-<UTCdate>-x86_64-<compiler>.json   (per-test results)
#   results/hmalloc/logs/tests-<UTCdate>-x86_64-<compiler>.log
#
# Exit status: 0 only if every selected compiler's suite fully passed.

set -euo pipefail

readonly ANVIL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly HERE="${ANVIL_ROOT}/integration/hardened_malloc"
readonly SRC_DIR="${ANVIL_ROOT}/.cache/upstream-hardened_malloc"
readonly RESULTS="${ANVIL_ROOT}/results/hmalloc"
readonly LOGS="${RESULTS}/logs"
readonly DATE="$(date -u +%Y%m%d)"

COMPILER_SEL='all'
REPEAT=1

usage() {
    cat <<EOF
Usage: $(basename "$0") [--compiler clang|gcc|all] [--repeat N]

  --compiler  run the suite for clang, gcc, or all (default: all)
  --repeat    run the unittest suite N times per compiler and require every
              run to pass (flakiness check; default: 1)
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --compiler) COMPILER_SEL="$2"; shift 2 ;;
        --repeat)   REPEAT="$2"; shift 2 ;;
        -h|--help)  usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

log()  { printf '[run_tests.sh] %s\n' "$*"; }
fail() { printf '[run_tests.sh] ERROR: %s\n' "$*" >&2; exit 1; }

cxx_for() {
    case "$1" in
        clang)   echo clang++ ;;
        clang-*) echo "${1/clang/clang++}" ;;
        gcc)     echo g++ ;;
        gcc-*)   echo "${1/gcc/g++}" ;;
    esac
}

mkdir -p "$LOGS"
[[ -d "$SRC_DIR/.git" ]] || fail "upstream clone missing; run build.sh first"

# resolve the gcc slot the same way build.sh does: newest c23-capable gcc
pick_gcc() {
    local c v
    for v in 15 14 13 12; do
        for c in "gcc-$v" gcc; do
            command -v "$c" >/dev/null 2>&1 || continue
            if echo 'int main(void){return 0;}' | "$c" -std=c23 -E -x c - >/dev/null 2>&1; then
                printf '%s' "$c"; return 0
            fi
        done
    done
    return 1
}

CLANG_CC=clang
GCC_CC="$(pick_gcc || true)"

COMPILERS=()
case "$COMPILER_SEL" in
    clang) [[ -n "$CLANG_CC" ]] && COMPILERS+=("$CLANG_CC") ;;
    gcc)   [[ -n "$GCC_CC" ]] && COMPILERS+=("$GCC_CC") || fail "no c23-capable gcc (need gcc >= 14; upstream minimum 14.2.0)" ;;
    all)   COMPILERS+=("$CLANG_CC" "$GCC_CC") ;;
    *) fail "bad --compiler '$COMPILER_SEL'" ;;
esac

overall_rc=0
for cc in "${COMPILERS[@]}"; do
    cxx="$(cxx_for "$cc")"
    tag="${cc}"
    jsonf="${RESULTS}/tests-${DATE}-x86_64-${tag}.json"
    logf="${LOGS}/tests-${DATE}-x86_64-${tag}.log"
    : >"$logf"

    log "=== $cc: building default lib + test binaries ==="
    if ! "$HERE/build.sh" --variant "$( [[ $cc == clang* ]] && echo clang || echo gcc )" --config default >>"$logf" 2>&1; then
        printf 'ERROR: build.sh failed for %s\n' "$cc" | tee -a "$logf"
        overall_rc=1; continue
    fi
    # guarantee the lib in the clone was produced by THIS compiler (build.sh
    # may have skipped via stamp; force a clean in-clone rebuild so test
    # binaries link a fresh, matching .so)
    ( cd "$SRC_DIR" && make clean >/dev/null 2>&1; rm -rf out out-light )
    if ! ( cd "$SRC_DIR" && make -j8 CC="$cc" CXX="$cxx" ) >>"$logf" 2>&1 \
       || ! ( cd "$SRC_DIR" && make -C test/ -j8 CC="$cc" CXX="$cxx" ) >>"$logf" 2>&1; then
        printf 'ERROR: make/make -C test failed for %s\n' "$cc" | tee -a "$logf"
        overall_rc=1; continue
    fi

    suite_fail=0
    runs_json=()
    for i in $(seq 1 "$REPEAT"); do
        log "=== $cc: unittest run $i/$REPEAT ==="
        runlog="${LOGS}/tests-${DATE}-x86_64-${tag}.run${i}.log"
        start_ts="$(date -u +%FT%TZ)"
        if ! ( cd "$SRC_DIR" && python3 -m unittest discover -v --start-directory test/ ) \
                >"$runlog" 2>&1; then
            suite_fail=1
        fi
        end_ts="$(date -u +%FT%TZ)"
        cat "$runlog" >>"$logf"
        # parse: "Ran N tests in Xs", counts from the summary line, per-test lines
        python3 - "$runlog" "$i" "$start_ts" "$end_ts" "$suite_fail" "$jsonf" <<'PY'
import json, re, sys

runlog, i, start_ts, end_ts, failed, jsonf = sys.argv[1:8]
text = open(runlog, encoding="utf-8", errors="replace").read()

m = re.search(r"Ran (\d+) tests? in ([\d.]+)s", text)
total = int(m.group(1)) if m else 0
wall = float(m.group(2)) if m else 0.0

ok_n   = len(re.findall(r"\.\.\. ok\b", text))
fail_n = len(re.findall(r"\.\.\. FAIL\b", text))
err_n  = len(re.findall(r"\.\.\. ERROR\b", text))
skip_n = len(re.findall(r"\.\.\. skipped\b", text))

per_test = []
for line in text.splitlines():
    mm = re.match(r"(\S+) \((\S+)\) \.\.\. (ok|FAIL|ERROR|skipped)", line)
    if mm:
        per_test.append({"test": mm.group(1), "case": mm.group(2), "status": mm.group(3)})

entry = {
    "run": int(i),
    "started_utc": start_ts, "ended_utc": end_ts,
    "total": total, "passed": ok_n, "failed": fail_n,
    "errors": err_n, "skipped": skip_n,
    "suite_ok": failed == "0" and fail_n == 0 and err_n == 0 and total > 0,
    "per_test": per_test,
}

data = {}
try:
    data = json.load(open(jsonf))
except Exception:
    pass
data.setdefault("runs", [])
# replace same-run entry on re-run, else append
data["runs"] = [r for r in data["runs"] if r.get("run") != entry["run"]] + [entry]

json.dump(data, open(jsonf, "w"), indent=2)
print(f"  run {i}: total={total} passed={ok_n} failed={fail_n} errors={err_n} "
      f"({wall:.1f}s) -> {'OK' if entry['suite_ok'] else 'FAILED'}")
PY
    done

    # finalize machine-readable header (machine facts + provenance)
    HM_SHA="$(git -C "$SRC_DIR" rev-parse HEAD)"
    CCVER="$("$cc" --version | head -n1)"
    python3 - "$jsonf" "$HM_SHA" "$cc" "$CCVER" "$DATE" <<'PY'
import json, platform, subprocess, sys, datetime

jsonf, sha, cc, ccver, date = sys.argv[1:6]

def sh(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return None

data = json.load(open(jsonf))
data["schema"] = "anvil.hmalloc.tests/1"
data["date_utc"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
data["upstream"] = {
    "url": "https://github.com/GrapheneOS/hardened_malloc", "sha": sha,
    "suite": "test/test_smc.py via python3 -m unittest discover (upstream `make test` backend)",
}
data["compiler"] = {"cc": cc, "version": ccver, "cxx_mode": "matching g++/clang++ (upstream forces CXX:=CC)"}
data["config"] = "default (upstream test/Makefile rejects non-default variants)"
data["machine"] = {
    "arch": platform.machine(),
    "kernel": platform.release(),
    "cpu": sh("lscpu | grep 'Model name' | sed 's/.*: *//'"),
    "cpus": sh("nproc"),
    "mem_gib": sh("free -g | awk 'NR==2{print $2}'"),
    "os": sh("lsb_release -ds") or platform.platform(),
}
data["all_runs_passed"] = all(r["suite_ok"] for r in data["runs"]) and len(data["runs"]) > 0
json.dump(data, open(jsonf, "w"), indent=2)

print(f"  -> {jsonf}  all_runs_passed={data['all_runs_passed']}")
PY
    if ! python3 -c "import json,sys; d=json.load(open('$jsonf')); sys.exit(0 if d['all_runs_passed'] else 1)"; then
        overall_rc=1
        log "!!! $cc suite reported failures — committing results honestly; see $logf"
    fi
done

exit "$overall_rc"
