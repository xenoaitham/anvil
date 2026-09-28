# Deviations: virtual-device module set, and boot-critical virtio built in

## 1. Virtual-device module set built in-tree

The stock CF kernel (6.12.74-android16) loads its cuttlefish "virtual device"
modules (virtio-gpu, virtio-rng, virtio_net, mac80211_hwsim, ...) from the
vendor_boot ramdisk; those modules are built OUT of tree against the GKI
kernel, so the stock GKI kernel config (the merge base) has no lines for them.
Our custom 6.6 kernel cannot load the 6.12-built blobs (vermagic), so the
equivalent drivers are enabled in-tree as modules. Added lines (via
scripts/config, then olddefconfig):

  HW_RANDOM_VIRTIO=m DRM_VIRTIO_GPU=m VIRTIO_INPUT=m VIRTIO_NET=m
  FAILOVER=m NET_FAILOVER=m CFG80211=m MAC80211=m MAC80211_HWSIM=m
  CRYPTO_LIB_ARC4=m

(VIRTIO_PCI=m VIRTIO_BLK=m VIRTIO_CONSOLE=m VIRTIO_VSOCKETS=m RFKILL=m were
already carried by the stock config.) These lines are outside the Anvil
fragments and are reported separately so fragment provenance stays clean.

## 2. Boot-critical virtio stack flipped =y (final builds)

First-stage init found the 6.6 module dir but inserted none of the
boot-critical modules (no "Loaded N modules" line; no kernel-side insmod
rejection either — cause not identified; the INIT_ON_FREE crash masked the
investigation, see CUTTLEFISH_EVIDENCE.md §5), so the partitions first-stage
mount depends on never appeared. Final builds flip the boot-critical set to
built-in (=y) so the boot needs no module loading at all:

  VIRTIO_PCI=y VIRTIO_BLK=y VIRTIO_NET=y VIRTIO_CONSOLE=y
  HW_RANDOM_VIRTIO=y VIRTIO_VSOCKETS=y VIRTIO_INPUT=y FAILOVER=y
  NET_FAILOVER=y

(DRM_VIRTIO_GPU, CFG80211, MAC80211, MAC80211_HWSIM stay =m; they are not on
the first-stage-mount path.) With this, the fragment kernel reaches Android
second-stage userspace (servicemanager, HALs) — CUTTLEFISH_EVIDENCE.md §3.
Same provenance rule as above: outside the Anvil fragments, reported
separately.

