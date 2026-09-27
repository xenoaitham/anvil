#!/usr/bin/env bash
# Anvil emulator harness — boot the AVD headless and wait for full boot.
#
# Boots cold (no snapshots — deterministic), software GPU, no window.
# Prints the boot wall time, leaves the emulator running for smoke.sh /
# posture.sh, and kills it on Ctrl-C.
#
# Usage: boot.sh [--keep]   (--keep: do not kill the emulator on exit)
# Exit status: 0 only when sys.boot_completed=1 was observed.

set -euo pipefail

ANVIL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_ROOT="${ANVIL_SDK_ROOT:-/mnt/NewVolume/anvil-sdk}"
AVD_NAME='anvil_smoke'
BOOT_TIMEOUT=600
KEEP=0
SOFTWARE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --keep)    KEEP=1 ;;
        --software) SOFTWARE=1 ;;   # no KVM (CI runners): software acceleration
        *) echo "usage: boot.sh [--keep] [--software]" >&2; exit 2 ;;
    esac
    shift
done

log()  { printf '[boot.sh] %s\n' "$*"; }
fail() { printf '[boot.sh] ERROR: %s\n' "$*" >&2; exit 1; }

EMU="$SDK_ROOT/emulator/emulator"
ADB="$SDK_ROOT/platform-tools/adb"
[ -x "$EMU" ] || fail "emulator not found at $EMU (run emulator/setup-host.sh first)"
if [ "$SOFTWARE" -eq 1 ]; then
    ACCEL="-no-accel"
    BOOT_TIMEOUT="${ANVIL_BOOT_TIMEOUT:-1800}"
    log "no KVM: software acceleration, boot timeout ${BOOT_TIMEOUT}s"
else
    ACCEL=""
    [ -w /dev/kvm ] || fail "/dev/kvm not writable"
fi

export ANDROID_SDK_ROOT="$SDK_ROOT"
export ANDROID_HOME="$SDK_ROOT"
export PATH="$SDK_ROOT/platform-tools:$PATH"

# ---------------------------------------------------------------- boot
mkdir -p "$ANVIL_ROOT/build/emulator"
START="$(date +%s)"
log "booting $AVD_NAME headless (KVM, swiftshader_indirect, cold)"
"$EMU" -avd "$AVD_NAME" \
    -no-window -gpu swiftshader_indirect -no-audio -no-boot-anim \
    -no-snapshot -memory 3072 -cores 4 $ACCEL \
    >"$ANVIL_ROOT/build/emulator/emulator.log" 2>&1 &
EMU_PID=$!

cleanup() {
    if [ "$KEEP" -ne 1 ]; then
        log "shutting down emulator"
        "$ADB" -s emulator-5554 emu kill >/dev/null 2>&1 || kill "$EMU_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

"$ADB" start-server >/dev/null 2>&1 || true
"$ADB" wait-for-device || fail "adb never saw the device"

# ---------------------------------------------------------------- boot-complete poll
ELAPSED=0
while [ "$ELAPSED" -lt "$BOOT_TIMEOUT" ]; do
    if [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
        BOOTED=$(( $(date +%s) - START ))
        log "boot complete in ${BOOTED}s"
        if [ "$KEEP" -eq 1 ]; then
            trap - EXIT INT TERM
            log "emulator left running (pid $EMU_PID) — run emulator/smoke.sh"
        fi
        exit 0
    fi
    sleep 5
    ELAPSED=$(( ELAPSED + 5 ))
done

tail -n 30 "$ANVIL_ROOT/build/emulator/emulator.log" >&2 || true
fail "no sys.boot_completed within ${BOOT_TIMEOUT}s"
