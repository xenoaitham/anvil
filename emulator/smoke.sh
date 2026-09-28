#!/usr/bin/env bash
# Anvil emulator harness — on-device hardened_malloc smoke test.
#
# Requires a booted device (run emulator/boot.sh --keep first).
#
# What it proves (each step recorded in the results JSON):
#   1. Anvil's NDK/bionic build of upstream hardened_malloc is loadable by a
#      real Android system (interposed via LD_PRELOAD and via direct dlopen).
#   2. It serves verified malloc-family traffic inside that system.
#   3. A zygote-launched app (Settings) can be started under the allocator
#      via the sanctioned `wrap.<package>` property and stays alive with the
#      .so mapped in its /proc/<pid>/maps.
#      NOTE: untrusted_app SELinux policy denies reading shell_data_file
#      (/data/local/tmp); on this userdebug emulator image the harness
#      temporarily runs `setenforce 0` for step 3 only, then restores
#      enforcing. This is a test-harness detail, not an integration claim —
#      real integration ships the .so inside the system image (platform
#      patches milestone).
#
# Exit status: 0 only if all three steps pass.

set -euo pipefail

ANVIL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_ROOT="${ANVIL_SDK_ROOT:-${ANDROID_HOME:-/mnt/NewVolume/anvil-sdk}}"
NDK_HOME="${NDK_HOME:-$SDK_ROOT/ndk/28.2.13676358}"
HM_DIR="$ANVIL_ROOT/integration/hardened_malloc"
BUILD_DIR="$ANVIL_ROOT/build/emulator"
RESULTS_DIR="$ANVIL_ROOT/results/emulator"
STAMP="$(date -u +%Y%m%d-%H%M%S)"

log()  { printf '[smoke.sh] %s\n' "$*"; }
fail() { printf '[smoke.sh] ERROR: %s\n' "$*" >&2; exit 1; }

export PATH="$SDK_ROOT/platform-tools:$PATH"
ADB="$SDK_ROOT/platform-tools/adb"
CLANG="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android29-clang"

mkdir -p "$BUILD_DIR" "$RESULTS_DIR/$STAMP"
RAW="$RESULTS_DIR/$STAMP"

# ---------------------------------------------------------------- preflight
[ -x "$CLANG" ] || fail "NDK clang missing at $CLANG (run emulator/setup-host.sh)"
[ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] \
    || fail "device not booted — run emulator/boot.sh --keep first"

# ---------------------------------------------------------------- artifacts
PROOF_SO="$ANVIL_ROOT/build/hmalloc-android/x86_64-default-proof/libhardened_malloc.so"
if [ ! -f "$PROOF_SO" ]; then
    log "proof .so missing — building Android artifacts (build-android.sh --proof)"
    ( cd "$HM_DIR" && ./build-android.sh --abi x86_64 --proof )
fi
[ -f "$PROOF_SO" ] || fail "proof .so still missing after build"

SMOKE_BIN="$BUILD_DIR/android_smoke"
log "compiling on-device smoke binary"
"$CLANG" -O2 -Wall -Wextra -o "$SMOKE_BIN" "$HM_DIR/android_smoke.c" -ldl \
    >"$RAW/smoke-compile.log" 2>&1 || { tail -20 "$RAW/smoke-compile.log" >&2; fail "smoke compile failed"; }

# ---------------------------------------------------------------- push
"$ADB" root >/dev/null && sleep 2
"$ADB" push "$PROOF_SO" /data/local/tmp/libhardened_malloc.so >/dev/null
"$ADB" push "$SMOKE_BIN" /data/local/tmp/android_smoke >/dev/null
"$ADB" shell chmod 755 /data/local/tmp/android_smoke

INTERPOSED_OUT="$("$ADB" shell "LD_PRELOAD=/data/local/tmp/libhardened_malloc.so /data/local/tmp/android_smoke --interposed" 2>&1 | tr -d '\r')"
printf '%s\n' "$INTERPOSED_OUT" > "$RAW/interposed.out"
INTERPOSED_OK=$(printf '%s' "$INTERPOSED_OUT" | grep -oE 'ok=1 narenas=[0-9]+' || true)
log "interposed mode: ${INTERPOSED_OK:-FAILED}"
[ -n "$INTERPOSED_OK" ] || fail "interposed smoke failed: $INTERPOSED_OUT"

DLOPEN_OUT="$("$ADB" shell "/data/local/tmp/android_smoke --dlopen /data/local/tmp/libhardened_malloc.so" 2>&1 | tr -d '\r')"
printf '%s\n' "$DLOPEN_OUT" > "$RAW/dlopen.out"
DLOPEN_OK=$(printf '%s' "$DLOPEN_OUT" | grep -oE 'ok=1 narenas=[0-9]+' || true)
log "dlopen mode: ${DLOPEN_OK:-FAILED}"
[ -n "$DLOPEN_OK" ] || fail "dlopen smoke failed: $DLOPEN_OUT"

# ---------------------------------------------------------------- wrap demo
setenforce() { "$ADB" shell setenforce "$1" >/dev/null; }
SELINUX_ORIG="$("$ADB" shell getenforce | tr -d '\r')"
log "SELinux at entry: $SELINUX_ORIG"

WRAP_STATUS="not-run"; WRAP_NOTE=""
# force-stop first: `am start` alone would just foreground a stale Settings
# process started before the wrap property existed, and its maps would
# honestly (but misleadingly) show no preload
"$ADB" shell am force-stop com.android.settings >/dev/null 2>&1 || true
"$ADB" shell 'setprop wrap.com.android.settings "LD_PRELOAD=/data/local/tmp/libhardened_malloc.so"'
"$ADB" shell am start -S -a android.settings.SETTINGS >/dev/null 2>&1 || true
sleep 6
PID="$("$ADB" shell pidof com.android.settings 2>/dev/null | tr -d '\r' | awk '{print $1}' || true)"
if [ -z "$PID" ]; then
    WRAP_NOTE="app not running; likely SELinux denial on shell_data_file read"
    if [ "$SELINUX_ORIG" = "Enforcing" ]; then
        log "retrying wrap demo with temporary permissive mode (userdebug image, restored after)"
        setenforce 0
        "$ADB" shell am start -S -a android.settings.SETTINGS >/dev/null 2>&1 || true
        sleep 6
        PID="$("$ADB" shell pidof com.android.settings 2>/dev/null | tr -d '\r' | awk '{print $1}' || true)"
        setenforce 1
    fi
fi
if [ -n "$PID" ]; then
    MAPS="$("$ADB" shell "grep -c libhardened_malloc /proc/$PID/maps" | tr -d '\r')" || MAPS=0
    if [ "${MAPS:-0}" -gt 0 ]; then
        WRAP_STATUS="pass"; WRAP_NOTE="pid $PID alive with libhardened_malloc mapped ($MAPS regions)"
    else
        WRAP_STATUS="fail"; WRAP_NOTE="pid $PID alive but lib not mapped"
    fi
else
    WRAP_STATUS="fail"; WRAP_NOTE="${WRAP_NOTE:-app failed to start under preload}"
fi
"$ADB" shell 'setprop wrap.com.android.settings ""'
printf '%s\n' "selinux_entry=$SELINUX_ORIG status=$WRAP_STATUS note=$WRAP_NOTE" > "$RAW/wrap.out"
log "wrap demo: $WRAP_STATUS — $WRAP_NOTE"

"$ADB" shell getenforce | tr -d '\r' > "$RAW/selinux_final.txt"

# ---------------------------------------------------------------- results JSON
python3 - "$RAW/smoke-$STAMP.json" \
    "$INTERPOSED_OUT" "$DLOPEN_OUT" "$WRAP_STATUS" "$WRAP_NOTE" "$SELINUX_ORIG" <<'PY'
import json, re, sys
out_path, inter, dlop, wrap_status, wrap_note, sel = sys.argv[1:7]
def parse(block):
    m = re.search(r'ok=(\d) narenas=(\d+)', block)
    return {"pass": bool(m), "narenas": int(m.group(2)) if m else None}
json.dump({
    "mode": "emulator smoke",
    "image": "system-images;android-36.1;google_apis;x86_64",
    "allocator": "GrapheneOS/hardened_malloc @ 01df350c (proof variant: CONFIG_STATS=true, -z nodlopen dropped)",
    "interposed": parse(inter),
    "dlopen": parse(dlop),
    "wrap_demo": {"status": wrap_status, "note": wrap_note, "selinux_at_entry": sel,
                  "selinux_temporarily_relaxed": sel == "Enforcing"},
}, open(out_path, "w"), indent=2)
PY

[ "$WRAP_STATUS" = "pass" ] || fail "wrap demo did not pass (see $RAW)"
log "ALL PASS — results in $RESULTS_DIR/$STAMP"
