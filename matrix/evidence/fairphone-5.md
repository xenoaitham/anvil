# Evidence — fairphone-5

Citation list for `matrix/devices/fairphone-5.yaml`. Every evidence id
referenced there is defined below; format is `- \`id\`: claim — source.`
Access date for all web citations: 2026-09-27.

## Cloned GrapheneOS sources (arbiter — local refs)

- `grapheneos-attest-guide`: GrapheneOS Attestation compatibility guide: hardware attestation has been mandatory for devices since Android 8 (detectable via `ro.product.first_api_level` > 25); remote verifiers should enforce `verifiedBootState` Verified or SelfSigned, matching published GrapheneOS verified-boot key fingerprints (https://grapheneos.org/attestation.json) — a list that only includes devices "receiving proper security updates for the kernel, drivers and firmware". Cloned source: `ref/grapheneos.org/static/articles/attestation-compatibility-guide.html`.
- `grapheneos-faq-gsi`: GrapheneOS FAQ: GrapheneOS "does not support being used as a Generic System Image" — the required kernel changes cannot run under a GSI, and GSIs do not ship/patch the device-support code. Cloned source: `ref/grapheneos.org/static/faq.html`.
- `grapheneos-faq-criteria`: GrapheneOS FAQ, non-exhaustive requirements for supported devices: verified boot with rollback protection for firmware AND OS, hardware memory tagging (MTE or equivalent), BTI/PAC coarse-grained CFI, StrongBox keystore + hardware key attestation + attest key, Weaver, isolated radios, A/B updates, hardware USB-data disable, reset-attack mitigation, and more. Cloned source: `ref/grapheneos.org/static/faq.html`.

## Web sources (all accessed 2026-09-27)

- `kernel-mte-doc`: Linux kernel arm64 documentation, https://docs.kernel.org/arch/arm64/memory-tagging-extension.html (accessed 2026-09-27): MTE is an ARMv8.5 feature (built on ARMv8.0 TBI); requires `CONFIG_ARM64_MTE` plus hardware support, advertised to userspace via `HWCAP2_MTE`; enabled per-process (`PROT_MTE` mappings, `PR_SET_TAGGED_ADDR_CTRL`). This is the citation for every architectural MTE claim in this matrix, including 'no' cells for pre-ARMv8.5 SoCs.
- `lineageos-install-fp5`: LineageOS install guide, Fairphone 5 (FP5), https://wiki.lineageos.org/devices/FP5/install (accessed 2026-09-27): unlocking defers to "the instructions at Fairphone Support to unlock your bootloader" (vendor-documented unlock path); relocking deferred to the LineageOS FAQ.
- `aosp-verified-boot`: AOSP Verified Boot documentation, https://source.android.com/docs/security/features/verifiedboot/verified-boot (accessed 2026-09-27): the boot chain is cryptographically verified against the root of trust; rollback protection is implemented with tamper-evident storage recording the newest permitted version, tracked per partition. Android's standard anti-rollback mechanism, referenced by every `rollback_protection` row.
- `auditor-about`: Auditor/AttestationServer overview, https://attestation.app/about (accessed 2026-09-27): any Android 13+ device can run Auditor as the VERIFIER; only devices launched with Android 8.0+ have the hardware support to be verified; each device model must be explicitly integrated; the per-model supported lists (basic, StrongBox, attest key, GrapheneOS verification) are Pixel-only (Pixel 6 through 10a); alternative OSes can only be verified if their verified boot key ships in Auditor, and "most alternative operating systems lack support for full verified boot and most devices don't support using verified boot with a custom key".
- `lineageos-device-list`: LineageOS officially supported devices, https://wiki.lineageos.org/devices/ (accessed 2026-09-27): lists panther (Pixel 7), husky (Pixel 8 Pro), caiman (Pixel 9 Pro), waffle (OnePlus 12), FP5 (Fairphone 5), pong (Nothing Phone 2), pdx237 (Xperia 5 V), beyond1lte (Galaxy S10). Does NOT list: Galaxy S24, Galaxy A55, Xiaomi 14, Motorola Edge 50, Zenfone 10.

## Verification paths for unverified cells (what would move them)

- `verification-path-fairphone-relock`: VERIFICATION PATH (2026-09-27): the Fairphone Support bootloader article (unlock + relock instructions) that the LineageOS FP5 guide links to. Not fetched at review.
- `verification-path-fairphone-updates`: VERIFICATION PATH (2026-09-27): Fairphone's own announcement/support pages fixing the security-support end date for FP5. Not reachable at review.
