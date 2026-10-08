#!/bin/bash
# make-configs.sh — rebuild .config.stock and .config.anvil after the
# 2026-10-08 reconstruction (was: interactive commands, now scripted).
set -eu
. /home/potato/anvil-cf/evidence/cf-env.sh
cd "$KC"

# 1) stock control: gki_defconfig + §2 virtio built-ins (module-deviation.md §2)
make ARCH=x86_64 LLVM=1 gki_defconfig 2>&1 | tail -1
./scripts/config --file .config \
    --set-val VIRTIO_PCI y --set-val VIRTIO_BLK y --set-val VIRTIO_NET y \
    --set-val VIRTIO_CONSOLE y --set-val HW_RANDOM_VIRTIO y \
    --set-val VIRTIO_VSOCKETS y --set-val VIRTIO_INPUT y \
    --set-val FAILOVER y --set-val NET_FAILOVER y
make ARCH=x86_64 LLVM=1 olddefconfig 2>&1 | tail -1
cp .config .config.stock
echo "stock config lines: $(grep -c '=' .config.stock)"

# 2) anvil reference: the committed final merged config (INIT_ON_FREE=n)
cp /home/potato/grafene/anvil/results/cuttlefish/20260928-022435/anvil-merged-kernel-last.conf .config.anvil
make ARCH=x86_64 LLVM=1 KCONFIG_CONFIG=.config.anvil olddefconfig 2>&1 | tail -1
echo "anvil config lines: $(grep -c '=' .config.anvil)"

# 3) regenerate + verify delta groups
python3 /home/potato/anvil-cf/evidence/gen-groups.py
bash /home/potato/anvil-cf/evidence/verify-groups.sh
