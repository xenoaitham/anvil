# Image/kernel pairing decision - evidence

- Campaign plan prefers an Android 15-era branch (aosp-android15-release).
- android15-release / android15-qpr2-release / aosp-android15-gsi:
  0 public builds on ci.android.com (branch-query-*.json, captured 2026-09-28).
- aosp-main newest public build is 13281750 (2025-03-27, Android 15, sdk 35)
  but its large artifacts (img zip, host package) are PURGED from storage:
  signed URLs return NoSuchKey/404 while BUILD_INFO remains (captured probes).
- Chosen: aosp-android-latest-release build 16373615,
  target aosp_cf_x86_64_only_phone-userdebug, artifacts 2026-09-17 (live):
    aosp_cf_x86_64_only_phone-img-16373615.zip  (1,163,638,742 B)
    cvd-host_package.tar.gz                     (898,832,913 B)
  BUILD_INFO: ro.build.version.release=17 sdk=37, id CP2A.260605.016,
  fingerprint in BUILD_INFO-16373615.json.
- Rationale: GKI backward compatibility (Android userspace must run on older
  GKI kernels; 6.6 is a supported GKI kernel for Android 15-era), and this is
  the newest public build with live artifacts. Deviation documented in
  CUTTLEFISH_EVIDENCE.md.
