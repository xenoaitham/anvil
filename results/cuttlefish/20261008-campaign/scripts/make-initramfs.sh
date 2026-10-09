#!/bin/bash
# make-initramfs.sh — stage modules + assemble an initramfs cpio with
# lib/modules/<release>/ (identical to the 2026-09 campaign version).
# RECONSTRUCTED 2026-10-08; compression fixed to LZ4 — cuttlefish's
# RepackKernelRamdisk runs the lz4 tool on the provided initramfs and a gzip
# cpio fails with "Unrecognized header" (assemble_cvd Error 44).
# 2026-10-09: adds the ramdisk-overlay (system/etc/ramdisk/build.prop with
# sys.use_memfd=1 baked — vehicle fix 2/2 made deterministic; the cpio is
# appended to the image ramdisk by RepackKernelRamdisk and the later cpio
# entry overrides the original file). SKIP_MODULES_INSTALL=1 reuses the
# existing staging dir (no kernel rebuild; modules unchanged since the
# build-tree cleanup).
set -e
KC=/home/potato/anvil-cf/kernel/common
STG=/home/potato/anvil-cf/kernel/staging
OV=/home/potato/anvil-cf/kernel/ramdisk-overlay
OUT=/home/potato/anvil-cf/kernel/initramfs-lz4.img
export PATH=/usr/lib/llvm-18/bin:/home/potato/anvil-cf/tools/pahole/root/usr/bin:/home/potato/anvil-cf/tools/lz4root/usr/bin:$PATH
cd $KC
if [ "${SKIP_MODULES_INSTALL:-0}" != "1" ]; then
  make ARCH=x86_64 LLVM=1 KCONFIG_CONFIG="${1:-.config.all-gpu}" INSTALL_MOD_PATH=$STG modules_install > /home/potato/anvil-cf/evidence/modules-install.log 2>&1
fi
REL=$(ls $STG/lib/modules | head -1)
echo "release: $REL"
rm -rf /tmp/initramfs-build && mkdir -p /tmp/initramfs-build/lib/modules
cp -a $STG/lib/modules/$REL /tmp/initramfs-build/lib/modules/
# ramdisk prop overlay (vehicle fix 2/2, deterministic sys.use_memfd=1)
cp -a $OV/system /tmp/initramfs-build/system
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
# keep only modules that actually exist in this build (built-ins have no .ko;
# cuttlefish's superimg repacker aborts (exit 70) on load-list entries whose
# module files are missing)
for lst in modules.load modules.load.first_stage modules.load.recovery; do
  if [ -f /tmp/initramfs-build/lib/modules/$REL/$lst ]; then
    while read -r m; do
      if ls /tmp/initramfs-build/lib/modules/$REL/ | grep -q "^${m}.ko"; then
        echo "$m"
      fi
    done < /tmp/initramfs-build/lib/modules/$REL/$lst > /tmp/initramfs-build/lib/modules/$REL/$lst.tmp
    mv /tmp/initramfs-build/lib/modules/$REL/$lst.tmp /tmp/initramfs-build/lib/modules/$REL/$lst
  fi
done
cp /tmp/initramfs-build/lib/modules/$REL/modules.load \
   /tmp/initramfs-build/lib/modules/$REL/modules.load.first_stage
cp /tmp/initramfs-build/lib/modules/$REL/modules.load \
   /tmp/initramfs-build/lib/modules/$REL/modules.load.recovery
(cd /tmp/initramfs-build && find . | cpio -o -H newc --owner=0:0 | lz4 -l -1) > $OUT
ls -la $OUT
