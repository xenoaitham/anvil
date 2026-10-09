#!/bin/bash
# bisect-boot.sh <NAME> [TIMEOUT_S]
# Boot $CF/kernel/bzImage-<NAME> (+ the shared initramfs) in the identical
# rootless namespace harness, capture the FULL serial console, and detect
# boot_completed (adb getprop or the VIRTUAL_DEVICE_BOOT_COMPLETED console
# marker) or a crash. Saves console + verdict; tears the instance down.
# Exit 0 = boot_completed; 1 = crash/timeout.
# RECONSTRUCTED 2026-10-08; 2026-10-09: --enable_tap_devices=false added;
# --initramfs_path re-confirmed REQUIRED (first-stage init must find the
# versioned /lib/modules/<release>/ dir with this build's signed modules or
# it falls back to the stock 6.12 flat dir and dies on module sig rejection).
# 2026-10-09 (2nd): adb sys.use_memfd setprop race made opt-in
# (MEMFD_VIA_ADB=1) — the initramfs now bakes the prop (see make-initramfs.sh);
# a default-path boot completing with sys.use_memfd=1 is the bake proof.
set -u
. /home/potato/anvil-cf/evidence/cf-env.sh

NAME="${1:?usage: bisect-boot.sh <NAME> [timeout]}"
TMO="${2:-900}"
BZ="$CF/kernel/bzImage-$NAME"
LAUNCH_LOG="$CLOG/launch-$NAME.log"
CONSOLE="$CLOG/boot-console-$NAME.log"
VERDICT="$CLOG/verdict-$NAME.txt"

df_guard / 3000 "system volume"
[ -f "$BZ" ] || { echo "no bzImage-$NAME" >&2; exit 2; }

cd "$HK"
rm -rf cuttlefish_runtime.1 cuttlefish_runtime
BOOT_EPOCH=$(date +%s); export BOOT_EPOCH
# launch_cvd --daemon can stay alive as a supervisor under the user namespace,
# so run it in the background and poll; stop_cvd at teardown ends it.
# --initramfs_path is REQUIRED: first-stage init must find the versioned
# /lib/modules/<release>/ dir (signed modules from this build) or it falls
# back to the stock 6.12 flat dir, fails "Loading of unsigned module is
# rejected" on failover.ko, and panics "Attempted to kill init!". The
# initramfs is rebuilt alongside each kernel (make-initramfs.sh <config>).
bin/launch_cvd \
    --system_image_dir=$CF/cf/image \
    --kernel_path="$BZ" \
    --initramfs_path="$CF/kernel/initramfs-lz4.img" \
    --gpu_mode=guest_swiftshader --num_instances=1 \
    --vhost_user_vsock=true \
    --enable_tap_devices=false \
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
        if [ -n "$SER" ]; then
            echo "adb device online: $SER (t=$(( $(date +%s) - START ))s)" | tee -a "$VERDICT"
            # VEHICLE FIX 2/2 (legacy adb path, now OFF by default): since
            # 2026-10-09 the initramfs bakes sys.use_memfd=1 into the
            # ramdisk build.prop (make-initramfs.sh + ramdisk-overlay/), so
            # the prop exists before any service starts. This adb setprop
            # race is kept only for booting OLD initramfs images: run with
            # MEMFD_VIA_ADB=1. A default-path boot that completes with
            # sys.use_memfd=1 in getprop is the proof the bake works.
            if [ "${MEMFD_VIA_ADB:-0}" = "1" ]; then
                adb -s "$SER" root >/dev/null 2>&1 || true
                sleep 2
                adb connect "127.0.0.1:$ADB_PORT" >/dev/null 2>&1
                adb -s "$SER" shell setprop sys.use_memfd 1 >/dev/null 2>&1 || true
            fi
        fi
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
