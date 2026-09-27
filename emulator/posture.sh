#!/usr/bin/env bash
# Anvil emulator harness — hardening posture dump of the running AVD.
#
# Requires a booted device. Records the observable security posture of the
# stock emulator platform (build identity, SELinux state, kernel export and
# ptrace knobs, ABI list) into results/emulator/, so claims about "what the
# emulator platform can and cannot validate" cite a dump, not a memory.
#
# This dump is the source for matrix/evidence/sdk-emulator.md.
# Exit status: 0 when the JSON was written.

set -euo pipefail

ANVIL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_ROOT="${ANVIL_SDK_ROOT:-/mnt/NewVolume/anvil-sdk}"
RESULTS_DIR="$ANVIL_ROOT/results/emulator"
STAMP="$(date -u +%Y%m%d-%H%M%S)"

log()  { printf '[posture.sh] %s\n' "$*"; }
fail() { printf '[posture.sh] ERROR: %s\n' "$*" >&2; exit 1; }

export PATH="$SDK_ROOT/platform-tools:$PATH"
ADB="$SDK_ROOT/platform-tools/adb"

[ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] \
    || fail "device not booted — run emulator/boot.sh --keep first"

mkdir -p "$RESULTS_DIR/$STAMP"
RAW="$RESULTS_DIR/$STAMP"

# shellcheck disable=SC2120  # helper reads the device each call
prop() { "$ADB" shell getprop "$1" 2>/dev/null | tr -d '\r'; }
knob() { "$ADB" shell cat "$1" 2>/dev/null | tr -d '\r'; }

python3 - "$RAW/posture-$STAMP.json" <<'PY' "$(prop ro.build.fingerprint)" "$(prop ro.build.version.sdk)" \
    "$(prop ro.build.version.release)" "$(prop ro.build.version.security_patch)" \
    "$(prop ro.product.cpu.abilist)" "$(prop ro.hardware)" \
    "$("$ADB" shell getenforce | tr -d '\r')" \
    "$(knob /proc/sys/kernel/kptr_restrict)" "$(knob /proc/sys/kernel/dmesg_restrict)" \
    "$(knob /proc/sys/kernel/perf_event_paranoid)" "$(knob /proc/sys/kernel/yama/ptrace_scope)" \
    "$(knob /proc/sys/vm/mmap_min_addr)" "$(knob /proc/sys/kernel/unprivileged_bpf_disabled)" \
    "$("$ADB" shell uname -r | tr -d '\r')" "$(knob /proc/cmdline)"
import json, sys
out = sys.argv[1]
keys = ["ro.build.fingerprint", "ro.build.version.sdk", "ro.build.version.release",
        "ro.build.version.security_patch", "ro.product.cpu.abilist", "ro.hardware",
        "selinux", "kernel.kptr_restrict", "kernel.dmesg_restrict",
        "kernel.perf_event_paranoid", "kernel.yama.ptrace_scope",
        "vm.mmap_min_addr", "kernel.unprivileged_bpf_disabled",
        "kernel.release", "cmdline"]
d = dict(zip(keys, [v.strip() for v in sys.argv[2:]]))
d["platform"] = "Google SDK emulator (goldfish), stock kernel — NOT an Anvil-validated kernel"
json.dump(d, open(out, "w"), indent=2)
print(json.dumps(d, indent=2))
PY

log "posture dump written to $RAW/posture-$STAMP.json"
