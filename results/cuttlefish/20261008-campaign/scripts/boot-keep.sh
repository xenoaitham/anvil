#!/bin/bash
# boot-keep.sh <NAME> [TIMEOUT_S]
# bisect-boot.sh variant that does NOT tear down on success: when
# sys.boot_completed lands, the instance is left running so the posture
# probes (run-probes.sh) can execute on the live kernel. Tear down with
# cf_teardown (from cf-env.sh) afterwards.
# 2026-10-09: created for the sys.boot_completed posture dump.
# (Mirrored from /home/potato/anvil-cf/evidence/boot-keep.sh; the working
# copy is authoritative. See bisect-boot.sh for the full VEHICLE FIX notes.)
set -u
. /home/potato/anvil-cf/evidence/cf-env.sh

NAME="${1:?usage: boot-keep.sh <NAME> [timeout]}"
TMO="${2:-1200}"
BZ="$CF/kernel/bzImage-$NAME"
LAUNCH_LOG="$CLOG/launch-$NAME.log"
CONSOLE="$CLOG/boot-console-$NAME.log"
VERDICT="$CLOG/verdict-$NAME.txt"

df_guard / 3000 "system volume"
[ -f "$BZ" ] || { echo "no bzImage-$NAME" >&2; exit 2; }

cd "$HK"
rm -rf cuttlefish_runtime.1 cuttlefish_runtime
BOOT_EPOCH=$(date +%s); export BOOT_EPOCH
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
    rm -f "$CONSOLE.tmp"
    if console_grab "$CONSOLE.tmp" && [ -s "$CONSOLE.tmp" ]; then
        SIG=$(scan_console "$CONSOLE.tmp")
        if [ -n "$SIG" ]; then
            cp "$CONSOLE.tmp" "$CONSOLE"
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
            # VEHICLE FIX 2/2: sys.use_memfd=1 (see bisect-boot.sh comment)
            adb -s "$SER" root >/dev/null 2>&1 || true
            sleep 2
            adb connect "127.0.0.1:$ADB_PORT" >/dev/null 2>&1
            adb -s "$SER" shell setprop sys.use_memfd 1 >/dev/null 2>&1 || true
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
# NO teardown: instance stays up for live-kernel probes (run-probes.sh).
df_guard / 800 "system volume after run (instance kept)"
case "$RESULT" in
    BOOT_COMPLETED) exit 0 ;;
    *) exit 1 ;;
esac
