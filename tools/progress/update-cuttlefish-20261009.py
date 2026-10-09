#!/usr/bin/env python3
"""One-shot: update the cuttlefish-kernel piece in progress/progress.json with
the 2026-10-09 follow-up session results, then regenerate index.html."""
import json, pathlib

ROOT = pathlib.Path("/home/potato/grafene/anvil")
PROGRESS = ROOT / "progress" / "progress.json"
d = json.loads(PROGRESS.read_text())
piece = next(p for p in d["pieces"] if p["id"] == "cuttlefish-kernel")

piece["rounds"][1]["verdict"] = "ours"
piece["rounds"][1]["gap"] = (
    "secondary notes acted on 2026-10-09: BPF_UNPRIV_DEFAULT_OFF flip considered and REJECTED "
    "(GOS parity is the fragment contract; override documented in base.cfg); dead-letter "
    "# CONFIG_MODVERSIONS line DROPPED from base.cfg (olddefconfig with/without the line: "
    "byte-identical 7575-line config, repro committed); merge-order requirement (fragments AFTER "
    "origin, else HIBERNATION/TIPC/BINFMT_MISC resurrect — demonstrated) documented in "
    "hardening/kernel/README.md with a post-merge assertion grep. Follow-up policy decision: "
    "INIT_ON_FREE stays excluded from x86_64 vehicles (retention rationale in "
    "CUTTLEFISH_EVIDENCE §4). Upstream draft filed-in-repo: patches/kernel-gki/ "
    "(DMABUF_HEAPS_SYSTEM=y one-liner, git apply --check clean). Vehicle fix 2/2 made "
    "deterministic (sys.use_memfd baked into an AVB-re-signed init_boot copy; attempt 010 "
    "initramfs-only variant FAILS as negative control, attempt 011 BOOT_COMPLETED t=96s, "
    "prop from boot defaults, 0 ashmem deaths, no adb)."
)

new_evidence = [
    "results/cuttlefish/20261009-memfd-bake/FINDINGS.md — deterministic sys.use_memfd (attempts 010/011)",
    "results/cuttlefish/20261009-memfd-bake/probe-postboot.txt + getprop-full.txt — prop=1 from boot defaults, boot_completed=1, 0 ashmem deaths, lockdown [confidentiality]",
    "results/cuttlefish/20261009-round2-followup/DECISIONS.md — BPF/MODVERSIONS/ordering decisions + repro script + experiment output",
    "patches/kernel-gki/ — AOSP gki_defconfig upstream draft (patch + ISSUE.md, applies clean to c905c29016dd)",
    "results/cuttlefish/20261009-release/RELEASE.md — canonical bzImage sha256 table + archive decision",
]
evidence = piece.get("evidence", [])
piece["evidence"] = evidence + [e for e in new_evidence if e not in evidence]

PROGRESS.write_text(json.dumps(d, indent=1, ensure_ascii=False) + "\n")
print("progress.json updated")
