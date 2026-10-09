#!/bin/bash
# patch-initramfs-prop.sh — bake sys.use_memfd=1 into a COPY of init_boot.img
# (the generic ramdisk), re-signed with cuttlefish's own AVB test key.
# 2026-10-09.
#
# WHY: assemble_cvd merges --initramfs_path content into the VENDOR ramdisk,
# while the init_boot generic ramdisk passes through and extracts AFTER the
# vendor pieces in the guest initrd — last-write-wins on
# /system/etc/ramdisk/build.prop goes to the generic copy. Attempt
# anvil-final-memfd carried the prop only via --initramfs_path: the ORIGINAL
# generic file won, the prop was absent at boot, system_server ashmem
# crash-looped, TIMEOUT t=902s (initrd contents verified correct — order is
# the problem). Patching the generic ramdisk puts the prop on the
# last-extracting carrier.
#
# The first rebuild attempt (header+ramdisk only, no AVB) was rejected by
# uboot: "init_boot_a: Error verifying vbmeta image: invalid vbmeta header"
# (boot console, anvil-final-memfd2). Hence the avbtool re-sign below with
# the ORIGINAL parameters: SHA256_RSA4096, the bundled test key, same
# partition size, same prop. The original image file is NOT modified.
set -eu
CF=/home/potato/anvil-cf
SRC=$CF/cf/image/init_boot.img
DST=$CF/cf/image/init_boot-anvil.img
OV=$CF/kernel/ramdisk-overlay/system/etc/ramdisk/build.prop
AVBTOOL=$CF/cf/hostpkg/bin/avbtool
KEY=$CF/cf/hostpkg/etc/cvd_avb_testkey_rsa4096.pem
SALT=209d156d8b7216d8224676a424f22672683de224424387e0f24080f0230d2ea9
PART_SIZE=8388608
export PATH=$CF/tools/lz4root/usr/bin:$PATH

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# trust-anchor check: the bundled key must be the one the original image
# was signed with (public key sha1 2597c218... from avbtool info_image)
$AVBTOOL extract_public_key --key "$KEY" --output "$WORK/pub.avbpubkey"
PUB=$(sha1sum "$WORK/pub.avbpubkey" | cut -d' ' -f1)
[ "$PUB" = "2597c218aae470a130f61162feaae70afd97f011" ] || {
    echo "bundled test key does not match the original signing key ($PUB)" >&2; exit 1; }

python3 - "$SRC" "$WORK" <<'EOF'
import struct, sys
src, work = sys.argv[1], sys.argv[2]
f = open(src, 'rb')
hdr = bytearray(f.read(4096))
assert hdr[:8] == b'ANDROID!'
kernel_size  = struct.unpack_from('<I', hdr, 8)[0]   # 0 for init_boot
ramdisk_size = struct.unpack_from('<I', hdr, 12)[0]
hdr_ver      = struct.unpack_from('<I', hdr, 40)[0]
assert hdr_ver == 4 and kernel_size == 0, (kernel_size, hdr_ver)
f.seek(4096)
open(work + '/ramdisk.lz4', 'wb').write(f.read(ramdisk_size))
open(work + '/hdr.bin', 'wb').write(bytes(hdr))
print(f"init_boot: ramdisk={ramdisk_size}B ver={hdr_ver}")
EOF
lz4 -d -f "$WORK/ramdisk.lz4" "$WORK/ramdisk.cpio"
rm -rf "$WORK/rd" && mkdir -p "$WORK/rd"
(cd "$WORK/rd" && cpio -idm --quiet < "$WORK/ramdisk.cpio" 2>/dev/null || true)
cp "$OV" "$WORK/rd/system/etc/ramdisk/build.prop"
grep -q '^sys.use_memfd=1$' "$WORK/rd/system/etc/ramdisk/build.prop"
(cd "$WORK/rd" && find . | cpio -o -H newc --owner=0:0 2>/dev/null | lz4 -l -1) > "$WORK/new-ramdisk.lz4"
python3 - "$WORK" <<'EOF'
import struct, sys
work = sys.argv[1]
hdr = bytearray(open(work + '/hdr.bin', 'rb').read())
ramdisk = open(work + '/new-ramdisk.lz4', 'rb').read()
struct.pack_into('<I', hdr, 12, len(ramdisk))
raw = open(work + '/raw.img', 'wb')
raw.write(bytes(hdr))
raw.write(ramdisk)
pad = (-len(ramdisk)) % 4096
raw.write(b'\0' * pad)
print(f"raw image: ramdisk={len(ramdisk)}B")
EOF
"$AVBTOOL" add_hash_footer \
    --image "$WORK/raw.img" \
    --partition_name init_boot \
    --partition_size "$PART_SIZE" \
    --algorithm SHA256_RSA4096 \
    --key "$KEY" \
    --salt "$SALT"
# (original also carried prop com.android.build.init_boot.os_version=17;
# this avbtool rejects the --prop syntax — it is optional metadata, and the
# boot run is the arbiter of everything that matters here)
mv "$WORK/raw.img" "$DST"
"$AVBTOOL" verify_image --image "$DST" --key "$KEY" \
    | sed 's/^/verify: /'
ls -la "$DST"
