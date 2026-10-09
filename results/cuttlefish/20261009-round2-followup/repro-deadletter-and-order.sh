#!/bin/bash
# A/B experiment: does dropping base.cfg's dead-letter MODVERSIONS line
# change the resolved config? Also: reversed-merge resurrection demo.
# Run from anywhere; needs the campaign tree at /home/potato/anvil-cf and
# clang-18 in /usr/lib/llvm-18/bin.
# 2026-10-09, android15-6.6 @ c905c29016dd2dbf8df45e7c0287455f67ef165b.
set -eu
export PATH=/usr/lib/llvm-18/bin:/home/potato/anvil-cf/tools/pahole/root/usr/bin:$PATH
cd /home/potato/anvil-cf/kernel/common
H=/home/potato/grafene/anvil/hardening/kernel
G=/home/potato/anvil-cf/campaign2/groups
FIX=/tmp/fixed-preamble.cfg   # bisect-build.sh FIXED preamble lines, verbatim

build() { # $1=out $2=concat-input
    cp .config.stock "$1"
    cat "$2" >> "$1"
    make ARCH=x86_64 LLVM=1 KCONFIG_CONFIG="$1" olddefconfig >/dev/null 2>&1
}

# A: fragment set as committed (base.cfg no longer carries the dead letter;
#    for the A/B we synthesize both variants from the same concatenation)
cat $FIX $H/base.cfg $H/arch-x86_64.cfg $G/ioring-n.cfg $G/ramoops-n.cfg > /tmp/fragA.cfg
sed 's/^# CONFIG_MODVERSIONS is not set$//' /tmp/fragA.cfg > /tmp/fragB.cfg
build /tmp/cfgA /tmp/fragA.cfg
build /tmp/cfgB /tmp/fragB.cfg

echo "--- A vs B (dead-letter drop) ---"
if diff -q /tmp/cfgA /tmp/cfgB >/dev/null; then echo "IDENTICAL ($(wc -l < /tmp/cfgA) lines)"; else diff /tmp/cfgA /tmp/cfgB | head; fi
grep -E '^CONFIG_MODVERSIONS=' /tmp/cfgA /tmp/cfgB

echo "--- reversed merge (fragments BEFORE origin gki_defconfig) ---"
cp $H/base.cfg /tmp/cfgR
cat $H/arch-x86_64.cfg $FIX arch/x86/configs/gki_defconfig >> /tmp/cfgR
make ARCH=x86_64 LLVM=1 KCONFIG_CONFIG=/tmp/cfgR olddefconfig >/dev/null 2>&1
for sym in HIBERNATION TIPC BINFMT_MISC; do
    echo "$sym: $(grep -E "^# CONFIG_${sym} is not set|^CONFIG_${sym}=" /tmp/cfgR)"
done
