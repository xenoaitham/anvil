#!/bin/bash
# verify-groups.sh — dry run: .config.stock + FIXED preamble + all.cfg must
# olddefconfig-resolve to exactly .config.anvil (the committed crashing build).
# RECONSTRUCTED 2026-10-08.
set -eu
. /home/potato/anvil-cf/evidence/cf-env.sh

CFG=".config.verify-all"
cd "$KC"
cp .config.stock "$CFG"
sed -n '/--- boot-vehicle/,/^# CONFIG_INIT_ON_FREE_DEFAULT_ON is not set/p' \
    /home/potato/anvil-cf/evidence/bisect-build.sh | grep -E '^CONFIG_|^# CONFIG_' >> "$CFG"
echo "# === all groups ===" >> "$CFG"
cat "$GRP/all.cfg" >> "$CFG"
make ARCH=x86_64 LLVM=1 KCONFIG_CONFIG="$CFG" olddefconfig >/dev/null 2>&1

echo "=== diffs verify vs .config.anvil (want: empty) ==="
diff <(grep -E '^CONFIG_|^# CONFIG_' "$OD/$CFG") \
     <(grep -E '^CONFIG_|^# CONFIG_' .config.anvil) || true
echo "=== diffs verify vs .config.stock (sanity: should be the delta) ==="
diff "$OD/$CFG" .config.stock | grep -c '^[<>]' || true
