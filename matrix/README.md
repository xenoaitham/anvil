# Device security matrix

**What this is:** Anvil's honest per-device security matrix — an evidence-backed
comparison of what each Android device family can actually take, built for a
project that wants to carry GrapheneOS-style hardening beyond the Pixel line.

**Relationship to GrapheneOS's own device list:** GrapheneOS supports Pixels
only, and its FAQ is explicit about why — most other devices fail its published
hardware and firmware criteria regardless of the work put into device support.
This matrix takes those published criteria seriously instead of arguing with
them: it mirrors them as columns, scores the Pixel rows as full-marks reference
points, and then extends the same analysis to devices GrapheneOS refuses. It
does **not** pretend those devices achieve parity. A custom ROM on a non-Pixel
is not GrapheneOS, and the rows below say exactly where the ceiling is.

**How to read it, in one breath:** a cell says **yes** only with a citation;
a cell says **no** when the hardware or vendor policy forbids the feature —
that is a finding, not an insult; a cell says **unverified** when we looked
and could not confirm it from a public source, and every unverified cell
names its verification path in `matrix/evidence/`. Scores are a weighted
summary, not a ranking to buy phones by.

Legend — each column in one line:

| Column | Meaning |
|---|---|
| SoC | Chipset (both variants for dual-chip families) |
| MTE | ARM Memory Tagging Extension implemented by the SoC's cores (`no` = hardware-forbidden; `unver.` = capability unproven, enablement unevidenced) |
| BTI/PAC | Hardware coarse-grained CFI (branch target identification / pointer authentication); `part` = mixed-core SoC where only some cores implement it |
| Unlock | Vendor provides a documented, supported bootloader-unlock path |
| Relock | Bootloader can be re-locked (usually only with vendor-signed images) |
| Rollback | Bootloader refuses older, more vulnerable firmware/OS (anti-rollback) |
| Own OS locked | Your own OS with the bootloader locked and full verified boot — the GrapheneOS criterion (`part` = relock possible with vendor-signed OS only, custom OS not demonstrated) |
| HW att | Hardware-backed key attestation (mandatory on devices launching with Android 8.0+) |
| StrongBox | Dedicated secure-element keystore |
| Auditor | Device model is on GrapheneOS Auditor/AttestationServer's supported lists (Pixel-only) |
| SecUpd | Published vendor security-update period in months; `-` = no reachable primary source, so unverified |
| LOS | Officially on LineageOS's supported device list |
| GSI | Generic System Image viability — GrapheneOS's docs reject GSIs outright, so `poor` everywhere unless proven otherwise |
| Score | Weighted: MTE 3, own-OS-verified-boot-with-relock 3 (partial 1.5), rollback 2 (partial 1), hardware attestation 2, >=48-month vendor security period 1. Max 11 |

Honesty legend — the part that matters:

- **yes** — cited. The citation lives in `matrix/evidence/<device>.md`; cloned
  GrapheneOS docs are the arbiter for Pixel claims.
- **no** — forbidden, plainly. Hardware-forbidden cells (MTE on pre-ARMv8.5
  silicon, auditor support off-Pixel) say no without embarrassment; that is the
  whole point of an honest matrix.
- **unverified** — we looked, we could not confirm, we are not guessing. Every
  such cell names what would verify it. Unverified is not a soft yes.
- **Scores reward capabilities with evidence, and nothing else.** The Pixels
  score full marks because GrapheneOS's own documentation claims every criterion
  for them — they are the reference rows that define what "full support" means,
  not our sales pitch.

## The matrix (sorted by score)

| Device | SoC | MTE | BTI/PAC | Unlock | Relock | Rollback | Own OS locked | HW att | StrongBox | Auditor | SecUpd | LOS | GSI | Score |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Google Pixel 8 Pro** (reference · `pixel-8-pro`) | Google Tensor G3 | yes | yes | yes | yes | yes | yes | yes | yes | yes | 84 | yes | poor | 11.0 |
| **Google Pixel 9 Pro** (reference · `pixel-9-pro`) | Google Tensor G4 | yes | yes | yes | yes | yes | yes | yes | yes | yes | 84 | yes | poor | 11.0 |
| **Google Pixel 7** (reference · `pixel-7`) | Google Tensor G2 | no | part | yes | yes | yes | yes | yes | yes | yes | 60 | yes | poor | 8.0 |
| [Fairphone 5 (QCM6490)](devices/fairphone-5.yaml) | QCM6490 (Qualcomm, IoT/industrial grade bin of the Snapdragon 778G-class platform) | no | part | yes | unver. | unver. | part | yes | unver. | no | - | yes | poor | 3.5 |
| [Nothing Phone (2) (Snapdragon 8+ Gen 1)](devices/nothing-phone-2.yaml) | Snapdragon 8+ Gen 1 | unver. | unver. | yes | unver. | unver. | part | yes | unver. | no | - | yes | poor | 3.5 |
| [OnePlus 12 (Snapdragon 8 Gen 3)](devices/oneplus-12.yaml) | Snapdragon 8 Gen 3 | unver. | unver. | yes | unver. | unver. | part | yes | unver. | no | - | yes | poor | 3.5 |
| [Samsung Galaxy S10 (Exynos 9820 / Snapdragon 855)](devices/samsung-galaxy-s10.yaml) | Exynos 9820 (international) or Snapdragon 855 (some markets) | no | unver. | yes | unver. | unver. | part | yes | unver. | no | - | yes | poor | 3.5 |
| [Sony Xperia 5 V (Snapdragon 8 Gen 2)](devices/sony-xperia-5-v.yaml) | Snapdragon 8 Gen 2 | unver. | unver. | yes | unver. | unver. | part | yes | unver. | no | - | yes | poor | 3.5 |
| [Asus Zenfone 10 (Snapdragon 8 Gen 2)](devices/asus-zenfone-10.yaml) | Snapdragon 8 Gen 2 | unver. | unver. | unver. | unver. | unver. | unver. | yes | unver. | no | - | no | poor | 2.0 |
| [Motorola Edge 50 (Snapdragon 7 Gen 1-class)](devices/motorola-edge-50.yaml) | Snapdragon 7-series (7 Gen 1-class per public spec) | no | part | unver. | unver. | unver. | unver. | yes | unver. | no | - | no | poor | 2.0 |
| [Samsung Galaxy A55 (Exynos 1480)](devices/samsung-galaxy-a55.yaml) | Exynos 1480 | unver. | unver. | unver. | unver. | unver. | unver. | yes | unver. | no | - | no | poor | 2.0 |
| [Samsung Galaxy S24 (Snapdragon 8 Gen 3 / Exynos 2400)](devices/samsung-galaxy-s24.yaml) | Snapdragon 8 Gen 3 for Galaxy (most markets) or Exynos 2400 (some markets) | unver. | unver. | unver. | unver. | unver. | unver. | yes | unver. | no | - | no | poor | 2.0 |
| [Xiaomi 14 (Snapdragon 8 Gen 3)](devices/xiaomi-14.yaml) | Snapdragon 8 Gen 3 | unver. | unver. | unver. | unver. | unver. | unver. | yes | unver. | no | - | no | poor | 2.0 |

Per-device citations: `matrix/evidence/<device>.md`. Schema: [`matrix/schema.json`](schema.json). Lint and regenerate this file: `python3 tools/matrix/matrix_lint.py --render`.
