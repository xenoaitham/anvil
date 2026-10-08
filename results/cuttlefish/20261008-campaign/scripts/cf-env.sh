#!/bin/bash
# cf-env.sh — shared environment for the 2026-10 cuttlefish bisect campaign.
# Source this; do not execute.
# RECONSTRUCTED 2026-10-08 after an external disk-cleanup deleted the original
# anvil-cf tree; contents are identical to the pre-deletion versions (kept in
# session context) and everything is mirrored into the anvil git repo.
# Campaign evidence dir: /home/potato/anvil-cf/campaign2 (recreated).

export CF=/home/potato/anvil-cf
export KC=$CF/kernel/common
export OD=$CF/kernel/common   # builds are in-tree (matches the 2026-09 campaign)
export CAMP=$CF/campaign2
export CLOG=$CAMP/logs
export GRP=$CAMP/groups
export IR=$CF/kernel/initramfs-lz4.img
export HK=$CF/cf/hostpkg
mkdir -p "$CLOG" "$GRP"
# NB: /mnt/NewVolume is mounted ro (fuseblk) — SDK there is read-only reusable;
# build outputs must live here. An external cleaner deleted this tree once
# already (2026-10-08 ~22:20); the repo (grafene/anvil) is the protected mirror.

# Build toolchain: system clang-18 + in-tree extracted pahole (same as 2026-09 campaign)
export PATH=/usr/lib/llvm-18/bin:$CF/tools/pahole/root/usr/bin:$PATH
# objtool needs libelf headers/libs; system libelf-dev is absent (no sudo), so
# use the campaign-extracted libelf deb plus extracted libzstd deb; the private
# libelf.pc closes the static-link deps (-lzstd -lz).
export C_INCLUDE_PATH=$CF/tools/libelf/root/usr/include
export LIBRARY_PATH=$CF/tools/libelf/root/usr/lib/x86_64-linux-gnu:$CF/tools/libzstd/root/usr/lib/x86_64-linux-gnu
export PKG_CONFIG_PATH=$CF/tools/pkgconfig

# Boot harness env (rootless: LD_PRELOAD shims inside unshare -Urn)
export HOME="$HK"
export LD_PRELOAD=$CF/cf/hostshim.so
export PATH="$HK/bin:$PATH"
export ADB_LOCALHOST_ONLY=1
ADB_PORT=6520

df_guard() { # df_guard <mount> <min_mb> <label>
    local avail; avail=$(df -Pm "$1" | awk 'NR==2{print $4}')
    if [ "$avail" -lt "$2" ]; then
        echo "DISK_GUARD: $3 has only ${avail}MB free (< $2) — aborting" >&2
        exit 42
    fi
}

cf_teardown() { # stop instance, best effort
    ( cd "$HK" && export HOME="$HK" LD_PRELOAD=$CF/cf/hostshim.so PATH="$HK/bin:$PATH"
      timeout 60 bin/stop_cvd >/dev/null 2>&1 ) || true
    sleep 2
    pkill -f 'crosvm run' 2>/dev/null || true
    sleep 1
    true
}

console_grab() { # console_grab <dest> — crosvm writes the guest serial to
# instances/cvd-1/kernel.log (cuttlefish_runtime is a mirror symlink dir).
# Only accepts files newer than BOOT_EPOCH (set by callers before launch) so
# a stale kernel.log from a previous run can never be mistaken for this boot.
    local dest="$1" src
    if [ -n "${BOOT_EPOCH:-}" ]; then
        src=$(find -L "$HK"/cuttlefish/instances/ "$HK"/ -maxdepth 3 -name kernel.log -newermt "@$BOOT_EPOCH" 2>/dev/null | head -1)
    else
        src=$(ls -t "$HK"/cuttlefish/instances/*/kernel.log "$HK"/cuttlefish_runtime*/kernel.log 2>/dev/null | head -1)
    fi
    if [ -n "$src" ]; then cp "$src" "$dest"; return 0; else return 1; fi
}

scan_console() { # scan_console <logfile> — echo first crash signature found (empty if none)
    grep -m1 -E 'Kernel panic - not syncing|#DF stack guard page|TASK stack guard page|Bad swap file entry|Kernel Offset: from' \
        "$1" 2>/dev/null | sed 's/^[[:space:]]*//' | cut -c1-160
}
