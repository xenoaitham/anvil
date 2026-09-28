#!/usr/bin/env bash
# Anvil emulator harness — host setup (idempotent).
#
# Installs the Android SDK components Anvil's emulator validation needs,
# pinned by exact package version, into SDK_ROOT (default: a volume with
# real free space — NOT the repo, NOT the root filesystem).
#
# Installs: platform-tools, emulator, google_apis x86_64 system image,
# NDK (for hardened_malloc bionic builds). Creates the anvil_smoke AVD.
#
# Exit status: 0 only when every required package is installed and the AVD
# exists.

set -euo pipefail

SDK_ROOT="${ANVIL_SDK_ROOT:-${ANDROID_HOME:-/mnt/NewVolume/anvil-sdk}}"
CMDLINE_TOOLS_ZIP='https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip'
PLATFORM_TOOLS='platform-tools'
EMULATOR_PKG='emulator'
IMAGE='system-images;android-36.1;google_apis;x86_64'   # userdebug: adb root works
# r28 (clang >= 19): the minimum upstream hardened_malloc builds with, and the
# version smoke.sh / build-android.sh resolve by default.
NDK_PKG='ndk;28.2.13676358'
AVD_NAME='anvil_smoke'

log()  { printf '[setup-host.sh] %s\n' "$*"; }
fail() { printf '[setup-host.sh] ERROR: %s\n' "$*" >&2; exit 1; }

command -v java >/dev/null 2>&1 || fail "java not on PATH (need JDK 17+)"
if [ ! -w /dev/kvm ]; then
    log "NOTE: /dev/kvm not writable — boot will need --software (slow; CI runners)"
fi

mkdir -p "$SDK_ROOT"

# ---- cmdline-tools bootstrap ------------------------------------------------
CT="$SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"
if [ ! -x "$CT" ]; then
    log "bootstrapping cmdline-tools"
    mkdir -p "$SDK_ROOT/dl"
    curl -sSLo "$SDK_ROOT/dl/cmdtools.zip" "$CMDLINE_TOOLS_ZIP"
    unzip -qo "$SDK_ROOT/dl/cmdtools.zip" -d "$SDK_ROOT/dl"
    mkdir -p "$SDK_ROOT/cmdline-tools/latest"
    mv -t "$SDK_ROOT/cmdline-tools/latest" \
        "$SDK_ROOT/dl/cmdline-tools/bin" \
        "$SDK_ROOT/dl/cmdline-tools/lib" \
        "$SDK_ROOT/dl/cmdline-tools/NOTICE.txt" \
        "$SDK_ROOT/dl/cmdline-tools/source.properties"
    rm -f "$SDK_ROOT/dl/cmdtools.zip"
fi

SM="$CT"
"$SM" --sdk_root="$SDK_ROOT" --licenses >/dev/null <<< "$(printf 'y\ny\ny\ny\ny\ny\ny\ny\n')" || true

# ---- packages (idempotent: sdkmanager skips installed ones) -----------------
log "installing: $PLATFORM_TOOLS $EMULATOR_PKG $IMAGE $NDK_PKG"
"$SM" --sdk_root="$SDK_ROOT" "$PLATFORM_TOOLS" "$EMULATOR_PKG" "$IMAGE" "$NDK_PKG"

# ---- AVD --------------------------------------------------------------------
# Hand-rolled AVD config: avdmanager in some cmdline-tools builds cannot
# resolve a non-default SDK root ("Package path is not valid"), and the ini
# format is stable. Deterministic, no tool dependency.
AVDCFG="$HOME/.android/avd/${AVD_NAME}.avd/config.ini"
if [ ! -f "$AVDCFG" ]; then
    log "creating AVD $AVD_NAME ($IMAGE)"
    mkdir -p "$HOME/.android/avd/${AVD_NAME}.avd"
    cat > "$HOME/.android/avd/${AVD_NAME}.ini" <<EOF
avd.ini.encoding=UTF-8
path=$HOME/.android/avd/${AVD_NAME}.avd
path.rel=avd/${AVD_NAME}.avd
target=android-36.1
EOF
    cat > "$AVDCFG" <<EOF
avd.ini.encoding=UTF-8
avd.ini.displayname=Anvil Smoke
image.sysdir.1=system-images/android-36.1/google_apis/x86_64/
image.androidVersion.api=36
tag.id=google_apis
tag.display=Google APIs
abi.type=x86_64
hw.cpu.arch=x86_64
hw.device.name=pixel_6
hw.ramSize=3072
hw.cpu.ncore=4
vm.heapSize=256
disk.dataPartition.size=4G
hw.lcd.width=1080
hw.lcd.height=2340
hw.lcd.density=420
hw.gpu.enabled=yes
hw.gpu.mode=swiftshader_indirect
hw.audioInput=no
hw.audioOutput=no
hw.camera.front=none
hw.camera.back=none
hw.keyboard=yes
fastboot.forceColdBoot=yes
EOF
else
    log "AVD $AVD_NAME already exists"
fi

# ---- verify -----------------------------------------------------------------
for p in "$SDK_ROOT/platform-tools/adb" "$SDK_ROOT/emulator/emulator" \
         "$SDK_ROOT/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"; do
    [ -e "$p" ] || fail "expected $p missing after install"
done
log "OK: SDK at $SDK_ROOT, AVD $AVD_NAME ready"
