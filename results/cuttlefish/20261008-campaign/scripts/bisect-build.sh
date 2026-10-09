#!/bin/bash
# bisect-build.sh <NAME> [GROUP...]
# Build kernel variant <NAME>: .config.stock (booting control base) + fixed
# boot-vehicle deviations + the delta groups named on the command line
# (files under $GRP, each containing raw kconfig lines), resolved by kbuild's
# own olddefconfig — in-tree, identical to the 2026-09 campaign environment.
# Output: $CF/kernel/bzImage-<NAME>  (+ saved config.$NAME)
# RECONSTRUCTED 2026-10-08 (identical to pre-deletion version).
set -eu
. /home/potato/anvil-cf/evidence/cf-env.sh

NAME="$1"; shift
DELTA_GROUPS=("$@")
CFG=".config.$NAME"
BLOG="$CLOG/build-$NAME.log"

df_guard / 8000 "system volume (pre-build)"

cd "$KC"
cp .config.stock "$CFG"

# Fixed deviations (documented in module-deviation.md + CUTTLEFISH_EVIDENCE.md §2,
# plus the 2026-10 GPU finding): every bisect variant carries the boot-vehicle
# fixes, so group tests isolate fragment content only.
cat >> "$CFG" <<'FIXED'
# --- boot-vehicle deviations (NOT fragment content) ---
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_HW_RANDOM_VIRTIO=y
CONFIG_VIRTIO_VSOCKETS=y
CONFIG_VIRTIO_INPUT=y
CONFIG_VIRTIO_VSOCKETS_COMMON=y
CONFIG_FAILOVER=y
CONFIG_NET_FAILOVER=y
CONFIG_CFG80211=m
CONFIG_MAC80211=m
CONFIG_MAC80211_HWSIM=m
# GPU built-in: 6.6 control TIMEOUTs at 600s without it — vendor early-init
# waits for /dev/dri/card0, nothing loads virtio-gpu on a 6.6 kernel, and
# MODULE_SIG_FORCE would block the module anyway (campaign2/groups/gpu-y.cfg)
CONFIG_DRM=y
CONFIG_DRM_VIRTIO_GPU=y
CONFIG_DRM_VIRTIO_GPU_KMS=y
# DMA-BUF system heap: the image's minigbm allocator HAL requires
# /dev/dma_heap/system; without it the allocator service exits 1, the
# composer's unchecked DrmSwapchain::create()==nullptr then SIGSEGVs
# (tombstone: ComposerClient::init -> onDisplayCreate -> getNextImage),
# and boot never completes. Origin x86_64 gki_defconfig omits this line
# (attempts 004 vs 005 differ in exactly this one resolved config line).
# CORRECTED 2026-10-09: the 6.12 image kernel has it OFF as well
# (stock-kernel.config) and boots via another path; only the 6.6 pairing
# requires it (patches/kernel-gki/ISSUE.md).
CONFIG_DMABUF_HEAPS_SYSTEM=y
# INIT_ON_FREE excluded on this boot vehicle (swap-corruption oops, §4 #3)
# CONFIG_INIT_ON_FREE_DEFAULT_ON is not set
FIXED

for g in "${DELTA_GROUPS[@]}"; do
    echo "# === group: $g ===" >> "$CFG"
    cat "$GRP/$g.cfg" >> "$CFG"
done

make ARCH=x86_64 LLVM=1 KCONFIG_CONFIG="$CFG" olddefconfig >"$BLOG" 2>&1
make ARCH=x86_64 LLVM=1 KCONFIG_CONFIG="$CFG" -j"$(nproc)" >>"$BLOG" 2>&1

cp arch/x86/boot/bzImage "$CF/kernel/bzImage-$NAME"
sha256sum "$CF/kernel/bzImage-$NAME" | tee -a "$CLOG/bzimage-sha256.txt"
cp "$CFG" "$CF/kernel/config.$NAME"
df_guard / 4000 "system volume (post-build)"
echo "BUILD_OK $NAME $(grep -c . "$BLOG") log lines"
