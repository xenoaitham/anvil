#!/usr/bin/env python3
"""matrix_lint.py — validate, score and render the Anvil per-device security matrix.

Checks (every one is an honesty gate, not style):
  1. Every matrix/devices/*.yaml parses and validates against matrix/schema.json
     (jsonschema if installed, otherwise a built-in validator for the schema
     subset this project actually uses).
  2. `id` equals the file stem.
  3. Declared portable_hardening_score equals the recomputed score.
     Weights: MTE 3, relockable own-OS verified boot 3 (partial 1.5),
     rollback protection 2 (partial 1), hardware attestation 2,
     vendor security period >= 48 months 1. Maximum 11.
  4. Every evidence id referenced by a device is DEFINED in that device's
     matrix/evidence/<id>.md; every id defined there is REFERENCED by the
     device (no orphan citations, no uncited claims).
  5. Claim-evidence rule: every capability cell whose value is not "no"/false/
     null — including "unverified" — carries an evidence entry, either at its
     exact field path (e.g. soc.mte) or at its group (e.g. soc).
  6. Every non-Pixel family has at least one limitation.
  7. --render regenerates matrix/README.md: fixed intro + honesty legend +
     one-line column legend + score-sorted table + coverage footer.

Exit code 0 = all gates pass.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DEFAULT_MATRIX = REPO / "matrix"

# --------------------------------------------------------------------------
# Optional dependencies with real fallbacks
# --------------------------------------------------------------------------

try:
    import yaml  # type: ignore
except ImportError:  # pragma: no cover
    yaml = None

try:
    import jsonschema  # type: ignore
except ImportError:  # pragma: no cover
    jsonschema = None


def load_yaml(path: Path):
    if yaml is not None:
        with path.open(encoding="utf-8") as fh:
            return yaml.safe_load(fh)
    # Minimal stdlib fallback: this project's YAML is strict subset
    # (2-space nested maps, quoted scalars, simple block lists).
    return _parse_yaml_subset(path.read_text(encoding="utf-8"))


def _parse_scalar(tok: str):
    tok = tok.strip()
    if tok.startswith('"') and tok.endswith('"') and len(tok) >= 2:
        return tok[1:-1].replace('\\"', '"')
    if tok in ("null", "~", ""):
        return None
    if tok == "true":
        return True
    if tok == "false":
        return False
    try:
        return int(tok)
    except ValueError:
        pass
    try:
        return float(tok)
    except ValueError:
        pass
    return tok


def _parse_yaml_subset(text: str):
    """Parse exactly the YAML subset this project emits: 2-space-indented
    nested mappings, block lists of quoted scalars, comments, no anchors,
    no flow collections, no multi-line scalars."""
    items = []
    for raw in text.splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        items.append((len(raw) - len(raw.lstrip()), stripped))
    if not items:
        return {}
    pos = 0

    def parse_block(indent: int):
        nonlocal pos
        if items[pos][1].startswith("- "):
            out = []
            while (
                pos < len(items)
                and items[pos][0] == indent
                and items[pos][1].startswith("- ")
            ):
                out.append(_parse_scalar(items[pos][1][2:]))
                pos += 1
            return out
        out = {}
        while pos < len(items) and items[pos][0] == indent:
            line = items[pos][1]
            if line.startswith("- "):
                break
            key, _, rest = line.partition(":")
            key = key.strip().strip('"')
            rest = rest.strip()
            pos += 1
            if rest:
                out[key] = _parse_scalar(rest)
            elif pos < len(items) and items[pos][0] > indent:
                out[key] = parse_block(items[pos][0])
            else:
                out[key] = None
        return out

    return parse_block(items[0][0])


# --------------------------------------------------------------------------
# Schema validation (jsonschema if available, else the needed subset)
# --------------------------------------------------------------------------

def validate(instance, schema):
    """Return list of human-readable error strings."""
    if jsonschema is not None:
        validator_cls = jsonschema.validators.validator_for(schema)
        validator_cls.check_schema(schema)
        validator = validator_cls(schema)
        return [
            f"{'/'.join(str(p) for p in e.absolute_path) or '<root>'}: {e.message}"
            for e in sorted(validator.iter_errors(instance), key=lambda e: list(e.absolute_path))
        ]
    return _validate_subset(instance, schema, "$")


def _type_ok(instance, expected) -> bool:
    if isinstance(expected, str):
        return {
            "object": isinstance(instance, dict),
            "array": isinstance(instance, list),
            "string": isinstance(instance, str),
            "boolean": isinstance(instance, bool),
            "integer": isinstance(instance, int) and not isinstance(instance, bool),
            "number": isinstance(instance, (int, float)) and not isinstance(instance, bool),
            "null": instance is None,
        }[expected]
    return any(_type_ok(instance, t) for t in expected)


def _validate_subset(instance, schema, path):
    errs = []
    if "anyOf" in schema:
        if not any(not _validate_subset(instance, sub, path) for sub in schema["anyOf"]):
            errs.append(f"{path}: does not match any allowed variant")
        return errs
    if "enum" in schema and instance not in schema["enum"]:
        errs.append(f"{path}: {instance!r} is not one of {schema['enum']}")
    if "const" in schema and instance != schema["const"]:
        errs.append(f"{path}: expected {schema['const']!r}")
    if "type" in schema and not _type_ok(instance, schema["type"]):
        errs.append(f"{path}: wrong type, expected {schema['type']}")
        return errs
    if isinstance(instance, dict):
        for req in schema.get("required", []):
            if req not in instance:
                errs.append(f"{path}: missing required property '{req}'")
        props = schema.get("properties", {})
        for key, value in instance.items():
            if key in props:
                errs.extend(_validate_subset(value, props[key], f"{path}/{key}"))
            elif schema.get("additionalProperties") is False:
                errs.append(f"{path}: unexpected property '{key}'")
            elif isinstance(schema.get("additionalProperties"), dict):
                errs.extend(
                    _validate_subset(value, schema["additionalProperties"], f"{path}/{key}")
                )
    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            errs.append(f"{path}: needs at least {schema['minItems']} items")
        item_schema = schema.get("items")
        if item_schema:
            for i, item in enumerate(instance):
                errs.extend(_validate_subset(item, item_schema, f"{path}/{i}"))
    if isinstance(instance, str):
        if "pattern" in schema and not re.search(schema["pattern"], instance):
            errs.append(f"{path}: {instance!r} does not match {schema['pattern']}")
        if "minLength" in schema and len(instance) < schema["minLength"]:
            errs.append(f"{path}: shorter than {schema['minLength']} chars")
        if schema.get("format") == "date" and not re.match(r"^\d{4}-\d{2}-\d{2}$", instance):
            errs.append(f"{path}: not a YYYY-MM-DD date")
    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            errs.append(f"{path}: below minimum {schema['minimum']}")
        if "maximum" in schema and instance > schema["maximum"]:
            errs.append(f"{path}: above maximum {schema['maximum']}")
    return errs


# --------------------------------------------------------------------------
# Scoring
# --------------------------------------------------------------------------

def _truthy_claim(value) -> bool:
    """A claim that must carry evidence: anything not 'no'/false/null.
    'unverified' counts — it must cite the verification-path entry."""
    if value is None or value is False or value == "no":
        return False
    return True


def compute_score(dev: dict) -> float:
    score = 0.0
    if dev["soc"]["mte"] == "yes":
        score += 3.0
    own_os = dev["verified_boot"]["own_os_with_locked_bl"]
    relock = dev["bootloader"]["relockable"]
    if own_os == "yes" and relock is True:
        score += 3.0
    elif own_os in ("partial", "yes"):
        score += 1.5
    rb = dev["bootloader"]["rollback_protection"]
    if rb == "yes":
        score += 2.0
    elif rb == "partial":
        score += 1.0
    if dev["attestation"]["hardware"] == "yes":
        score += 2.0
    months = dev["updates"]["vendor_security_period_months"]
    if isinstance(months, int) and months >= 48:
        score += 1.0
    return round(score, 1)


CLAIM_FIELDS = [
    ("soc", "mte"),
    ("soc", "bti_pac"),
    ("bootloader", "officially_unlockable"),
    ("bootloader", "relockable"),
    ("bootloader", "rollback_protection"),
    ("verified_boot", "own_os_with_locked_bl"),
    ("attestation", "hardware"),
    ("attestation", "strongbox"),
    ("attestation", "remote_supported_by_grapheneos_auditor"),
    ("custom_os", "gsi_feasibility"),
    ("custom_os", "lineage_official"),
    ("updates", "vendor_security_period_months"),
]

EVIDENCE_ID_RE = re.compile(r"^- `([a-z0-9]+(-[a-z0-9]+)*)`:", re.MULTILINE)


# --------------------------------------------------------------------------
# Lint
# --------------------------------------------------------------------------

def lint(matrix_dir: Path) -> tuple[list[str], list[dict]]:
    errors: list[str] = []
    devices: list[dict] = []

    schema_path = matrix_dir / "schema.json"
    if not schema_path.exists():
        return [f"missing {schema_path}"], devices
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
        errors.append("schema.json is not draft 2020-12")

    dev_files = sorted((matrix_dir / "devices").glob("*.yaml"))
    if not dev_files:
        errors.append(f"no device files under {matrix_dir}/devices")

    for dev_file in dev_files:
        tag = dev_file.stem
        try:
            dev = load_yaml(dev_file)
        except Exception as exc:  # noqa: BLE001
            errors.append(f"{tag}: YAML parse failure: {exc}")
            continue
        if not isinstance(dev, dict):
            errors.append(f"{tag}: top level must be a mapping")
            continue

        for err in validate(dev, schema):
            errors.append(f"{tag}: schema: {err}")

        if dev.get("id") != tag:
            errors.append(f"{tag}: id field is {dev.get('id')!r}, must equal file stem")

        # --- evidence file cross-checks ---
        ev_file = matrix_dir / "evidence" / f"{tag}.md"
        evidence = dev.get("evidence") or {}
        referenced = set(evidence.values())
        local_defined = {
            m.group(1)
            for m in EVIDENCE_ID_RE.finditer(ev_file.read_text(encoding="utf-8"))
        } if ev_file.exists() else set()
        if not ev_file.exists():
            errors.append(f"{tag}: missing evidence file {ev_file.name}")
        for eid in sorted(referenced - local_defined):
            errors.append(
                f"{tag}: evidence id '{eid}' referenced but not defined in {ev_file.name}"
            )
        for eid in sorted(local_defined - referenced):
            errors.append(
                f"{tag}: evidence id '{eid}' defined in {ev_file.name} but never referenced"
            )
        # NOTE: the same shared citation id (e.g. kernel-mte-doc) intentionally
        # appears in many devices' evidence files — each device carries its
        # full citation list per the matrix design. Scope is per-device-file.

        # --- claim-evidence rule ---
        for group, field in CLAIM_FIELDS:
            value = (dev.get(group) or {}).get(field)
            if not _truthy_claim(value):
                continue
            path = f"{group}.{field}"
            if path not in evidence and group not in evidence:
                errors.append(
                    f"{tag}: claim {path}={value!r} has no evidence entry "
                    f"(exact path or group '{group}' required)"
                )

        # --- honesty floors ---
        limitations = dev.get("limitations") or []
        if not limitations:
            errors.append(f"{tag}: limitations must be non-empty")
        if not tag.startswith("pixel-") and not limitations:
            errors.append(f"{tag}: non-Pixel rows require at least one limitation")

        # --- score consistency ---
        if all(k in dev for k in ("soc", "verified_boot", "bootloader", "attestation", "updates")):
            recomputed = compute_score(dev)
            declared = dev.get("portable_hardening_score")
            if declared is None or abs(declared - recomputed) > 1e-9:
                errors.append(
                    f"{tag}: portable_hardening_score {declared} != recomputed {recomputed}"
                )
            dev["_score"] = recomputed
        devices.append(dev)

    return errors, devices


# --------------------------------------------------------------------------
# Coverage report + README rendering
# --------------------------------------------------------------------------

def _cell(value, yes="yes", part="part", no="no"):
    if value is True:
        return yes
    if value is False or value is None or value == "no":
        return no
    if value == "unverified":
        return "unver."
    if value == "partial":
        return part
    return str(value)


def coverage_report(devices: list[dict]) -> str:
    lines = ["", "Coverage report", "---------------"]
    n_unverified = 0
    n_claims = 0
    for dev in devices:
        cells = []
        for group, field in CLAIM_FIELDS:
            value = (dev.get(group) or {}).get(field)
            cells.append(value)
            n_claims += 1
            if value == "unverified":
                n_unverified += 1
        verdicts = {
            "yes": sum(1 for c in cells if c == "yes" or c is True),
            "unverified": sum(1 for c in cells if c == "unverified"),
            "no": sum(1 for c in cells if c == "no" or c is False or c is None),
            "other": sum(1 for c in cells if c == "partial"),
        }
        name = dev.get("name", dev.get("id", "?"))
        lines.append(
            f"  {name:<48} yes={verdicts['yes']}  partial={verdicts['other']}  "
            f"unverified={verdicts['unverified']}  no={verdicts['no']}  "
            f"score={dev.get('_score', '?')}"
        )
    lines.append("")
    lines.append(
        f"  Matrix total: {len(devices)} device families, {n_claims} capability cells, "
        f"{n_unverified} marked unverified ({100 * n_unverified / max(n_claims, 1):.0f}%)"
    )
    lines.append(
        "  Unverified is not a soft yes: each one names a verification path in "
        "matrix/evidence/."
    )
    return "\n".join(lines)


INTRO = """# Device security matrix

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
"""


def render_readme(matrix_dir: Path, devices: list[dict]) -> str:
    rows = sorted(devices, key=lambda d: (-(d.get("_score") or 0), d.get("name", "")))
    header = (
        "| Device | SoC | MTE | BTI/PAC | Unlock | Relock | Rollback | Own OS locked "
        "| HW att | StrongBox | Auditor | SecUpd | LOS | GSI | Score |\n"
        "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"
    )
    table = [header]
    for dev in rows:
        upd = dev["updates"]["vendor_security_period_months"]
        upd_s = "-" if upd is None else str(upd)
        name = dev.get("name", dev.get("id"))
        if dev.get("reference"):
            name = f"**{name}** (reference · `{dev['id']}`)"
        else:
            name = f"[{name}](devices/{dev['id']}.yaml)"
        table.append(
            f"| {name} | {_cell(dev['soc']['model'], yes=dev['soc']['model'])} "
            f"| {_cell(dev['soc']['mte'])} | {_cell(dev['soc']['bti_pac'])} "
            f"| {_cell(dev['bootloader']['officially_unlockable'])} "
            f"| {_cell(dev['bootloader']['relockable'])} "
            f"| {_cell(dev['bootloader']['rollback_protection'])} "
            f"| {_cell(dev['verified_boot']['own_os_with_locked_bl'])} "
            f"| {_cell(dev['attestation']['hardware'])} "
            f"| {_cell(dev['attestation']['strongbox'])} "
            f"| {_cell(dev['attestation']['remote_supported_by_grapheneos_auditor'])} "
            f"| {upd_s} | {_cell(dev['custom_os']['lineage_official'])} "
            f"| {_cell(dev['custom_os']['gsi_feasibility'], yes='good')} "
            f"| {dev.get('_score', '?')} |"
        )
    table.append("")
    table.append(
        "Per-device citations: `matrix/evidence/<device>.md`. Schema: "
        "[`matrix/schema.json`](schema.json). Lint and regenerate this file: "
        "`python3 tools/matrix/matrix_lint.py --render`."
    )
    return INTRO + "\n## The matrix (sorted by score)\n\n" + "\n".join(table) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--matrix-dir", type=Path, default=DEFAULT_MATRIX)
    parser.add_argument(
        "--render", action="store_true",
        help="regenerate matrix/README.md from the linted device rows",
    )
    args = parser.parse_args()

    errors, devices = lint(args.matrix_dir)

    for err in errors:
        print(f"ERROR: {err}", file=sys.stderr)
    if errors:
        print(f"\n{len(errors)} error(s); matrix NOT rendered.", file=sys.stderr)
        return 1

    print(f"OK: {len(devices)} device families validated against schema.json")
    print(coverage_report(devices))

    if args.render:
        readme = args.matrix_dir / "README.md"
        readme.write_text(render_readme(args.matrix_dir, devices), encoding="utf-8")
        print(f"\nrendered {readme}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
