#!/bin/bash
# bisect-boot.sh <NAME> [TIMEOUT_S]
# Boot $CF/kernel/bzImage-<NAME> (+ the shared initramfs) in the identical
# rootless namespace harness, capture the FULL serial console, and detect
# boot_completed (adb getprop or the VIRTUAL_DEVICE_BOOT_COMPLETED console
# marker) or a crash. Saves console + verdict; tears the instance down.
# Exit 0 = boot_completed; 1 = crash/timeout.
# RECONSTRUCTED 2026-10-08 (identical to pre-deletion version).
set -u
. /home/potato/anvil-cf/evidence/cf-env.sh

NAME="${1:?usage: bisect-boot.sh <NAME> [timeout]}"
TMO="${2:-900}"
BZ="$CF/kernel/bzImage-$NAME"
LAUNCH_LOG="$CLOG/launch-$NAME.log"
CONSOLE="$CLOG/boot-console-$NAME.log"
VERDICT="$CLOG/verdict-$NAME.txt"

df_guard / 1500 "system volume"
[ -f "$BZ" ] || { echo "no bzImage-$NAME" >&2; exit 2; }

cd "$HK"
rm -rf cuttlefish_runtime.1 cuttlefish_runtime
BOOT_EPOCH=$(date +%s); export BOOT_EPOCH
# launch_cvd --daemon can stay alive as a supervisor under the user namespace,
# so run it in the background and poll; stop_cvd at teardown ends it.
bin/launch_cvd \
    --system_image_dir=$CF/cf/image \
    --kernel_path="$BZ" --initramfs_path="$IR" \
    --gpu_mode=guest_swiftshader --num_instances=1 \
    --vhost_user_vsock=true \
    --blank_data_image_mb=2048 \
    --extra_kernel_cmdline="console=ttyS0 earlyprintk=ttyS0,115200 ignore_loglevel" \
    --daemon >"$LAUNCH_LOG" 2>&1 &
LAUNCH_PID=$!
echo "launch_cvd pid=$LAUNCH_PID" >> "$VERDICT"

START=$(date +%s)
SER=""
RESULT="TIMEOUT"
while [ $(( $(date +%s) - START )) -lt "$TMO" ]; do
    # console-based detection (works even if adb never comes up)
    rm -f "$CONSOLE.tmp"
    if console_grab "$CONSOLE.tmp" && [ -s "$CONSOLE.tmp" ]; then
        SIG=$(scan_console "$CONSOLE.tmp")
        if [ -n "$SIG" ]; then
            cp "$CONSOLE.tmp" "$CONSOLE"
            # let the console flush a little so the log keeps the panic tail
            sleep 8; console_grab "$CONSOLE"
            RESULT="CRASH"
            break
        fi
        if grep -q 'VIRTUAL_DEVICE_BOOT_COMPLETED' "$CONSOLE.tmp"; then
            cp "$CONSOLE.tmp" "$CONSOLE"
            RESULT="BOOT_COMPLETED"
            echo "BOOT_COMPLETED (console marker) t=$(( $(date +%s) - START ))s" | tee -a "$VERDICT"
            break
        fi
    fi
    if [ -z "$SER" ]; then
        adb connect "127.0.0.1:$ADB_PORT" >/dev/null 2>&1
        SER=$(adb devices 2>/dev/null | awk '$2=="device"{print $1; exit}')
        [ -z "$SER" ] && { sleep 5; continue; }
        echo "adb device online: $SER (t=$(( $(date +%s) - START ))s)" | tee -a "$VERDICT"
    fi
    BC=$(adb -s "$SER" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    if [ "$BC" = "1" ]; then
        RESULT="BOOT_COMPLETED"
        echo "BOOT_COMPLETED t=$(( $(date +%s) - START ))s serial=$SER" | tee -a "$VERDICT"
        break
    fi
    sleep 5
done

if [ "$RESULT" = "BOOT_COMPLETED" ]; then
    sleep 5; console_grab "$CONSOLE" 2>/dev/null || true
elif [ "$RESULT" != "CRASH" ]; then
    console_grab "$CONSOLE"
fi
rm -f "$CONSOLE.tmp"
[ "$RESULT" = "BOOT_COMPLETED" ] || echo "$RESULT t=$(( $(date +%s) - START ))s" >> "$VERDICT"
cf_teardown
kill "$LAUNCH_PID" 2>/dev/null || true
adb disconnect >/dev/null 2>&1 || true
df_guard / 800 "system volume after run"
case "$RESULT" in
    BOOT_COMPLETED) exit 0 ;;
    *) exit 1 ;;
esac
