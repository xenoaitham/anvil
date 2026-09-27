# Anvil build tracker

Wave 1 (parallel builders, in flight):
- [ ] baseline — GrapheneOS reference baseline + portable taxonomy
- [ ] kernel-config — layered kernel hardening fragments + validator
- [ ] matrix — per-device security matrix, evidence-cited
- [ ] hmalloc — hardened_malloc integration, real tests + benches

Wave 2 (after wave 1 + critic rounds):
- [ ] platform-patches — upstream-quality AOSP patches, apply-checked
- [ ] ci — GitHub Actions real gates + Pages progress deploy

Wave 3:
- [ ] readme — final README, methodology, limitations

Per piece: builder -> anonymize -> blind critic -> loop until critic picks
ours (cap 3 rounds, then honest failure). Ledger in progress/progress.json.
