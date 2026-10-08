#!/bin/bash
# make-initramfs.sh — stage modules + assemble an initramfs cpio with
# lib/modules/<release>/ (identical to the 2026-09 campaign version).
# RECONSTRUCTED 2026-10-08 from the committed evidence copy.
set -e
KC=/home/potato/anvil-cf/kernel/common
STG=/home/potato/anvil-cf/kernel/staging
OUT=/home/potato/anvil-cf/kernel/initramfs.img
export PATH=/usr/lib/llvm-18/bin:/home/potato/anvil-cf/tools/pahole/root/usr/bin:$PATH
cd $KC
make ARCH=x86_64 LLVM=1 KCONFIG_CONFIG=.config.anvil INSTALL_MOD_PATH=$STG modules_install > /home/potato/anvil-cf/evidence/modules-install.log 2>&1
REL=$(ls $STG/lib/modules | head -1)
echo "release: $REL"
rm -rf /tmp/initramfs-build && mkdir -p /tmp/initramfs-build/lib/modules
cp -a $STG/lib/modules/$REL /tmp/initramfs-build/lib/modules/
# drop build/source symlinks (host paths, useless in guest)
rm -f /tmp/initramfs-build/lib/modules/$REL/build /tmp/initramfs-build/lib/modules/$REL/source
# modules.load: load list for boot-critical modules present in our build.
cat > /tmp/initramfs-build/lib/modules/$REL/modules.load <<LIST
virtio_pci
virtio_blk
virtio_net
virtio_console
virtio-rng
virtio_input
virtio-gpu
vmw_vsock_virtio_transport
failover
net_failover
LIST
cp /tmp/initramfs-build/lib/modules/$REL/modules.load \
   /tmp/initramfs-build/lib/modules/$REL/modules.load.first_stage
cp /tmp/initramfs-build/lib/modules/$REL/modules.load \
   /tmp/initramfs-build/lib/modules/$REL/modules.load.recovery
(cd /tmp/initramfs-build && find . | cpio -o -H newc --owner=0:0 | gzip -1) > $OUT
ls -la $OUT
