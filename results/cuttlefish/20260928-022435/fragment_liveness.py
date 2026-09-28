#!/usr/bin/env python3
"""Anvil fragment liveness checker.

Parses hardening/kernel/base.cfg + arch-x86_64.cfg fragment lines and reports,
for each non-comment line, its state in a kernel config (built or running).
States: live-y / live-m / off-but-pinned / missing.
Usage: fragment_liveness.py <config-file-or-config.gz> [--json OUT]
"""
import sys, gzip, json, argparse, re, pathlib

def load_config(path):
    op = gzip.open if path.endswith(".gz") else open
    cfg = {}
    with op(path, "rt", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            m = re.match(r"^(CONFIG_[A-Z0-9_]+)=(.*)$", line)
            if m:
                cfg[m.group(1)] = m.group(2)
                continue
            m = re.match(r"^# (CONFIG_[A-Z0-9_]+) is not set$", line)
            if m:
                cfg[m.group(1)] = "n"
    return cfg

def fragment_lines(paths):
    lines = []
    for p in paths:
        for raw in open(p):
            s = raw.strip()
            if not s:
                continue
            if s.startswith("#"):
                # off-pins are "# CONFIG_X is not set"; other "#" lines are comments
                if re.match(r"^# CONFIG_[A-Z0-9_]+ is not set$", s):
                    lines.append((p, s))
                continue
            lines.append((p, s))
    return lines

def state_of(value, want):
    # want: fragment line spec, e.g. "CONFIG_X=y", "# CONFIG_X is not set", "CONFIG_X=32"
    if want.startswith("#"):
        sym = want.split()[1]
        want_v = "n"
    else:
        sym, want_v = want.split("=", 1)
    have = value.get(sym, None)
    if have is None:
        return sym, want_v, None, "missing"
    if want_v == "n":
        ok = (have == "n")
    elif want_v == "y":
        ok = (have == "y")
    elif want_v == "m":
        ok = (have == "m")
    else:
        ok = (have == want_v)
    state = "ok" if ok else "MISMATCH"
    return sym, want_v, have, state

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("config")
    ap.add_argument("--json", dest="jsonout")
    ap.add_argument("fragments", nargs="+")
    a = ap.parse_args()
    if a.jsonout:
        # Confinement: the JSON report is evidence and belongs next to this
        # script in the campaign dir. Reject anything resolving outside it
        # (no ../, no absolute paths elsewhere) rather than writing blind.
        here = pathlib.Path(__file__).resolve().parent
        out = pathlib.Path(a.jsonout).resolve()
        if out.parent != here:
            ap.error(f"--json must land in the campaign dir: {here}")
        a.jsonout = str(out)
    cfg = load_config(a.config)
    rows = []
    for src, want in fragment_lines(a.fragments):
        sym, want_v, have, state = state_of(cfg, want)
        state_label = {
            "ok": ("y" if want_v == "y" else "m" if want_v == "m" else "off-but-pinned"),
            "missing": "missing",
            "MISMATCH": "MISMATCH",
        }[state]
        rows.append({"fragment": src.split("/")[-1], "line": want, "symbol": sym,
                     "wanted": want_v, "config_value": have, "status": state_label})
    ok = sum(1 for r in rows if r["status"] in ("y", "m", "off-but-pinned"))
    print(f"fragment lines: {len(rows)}  ok(=y/=m/pinned-off): {ok}  missing: "
          f"{sum(1 for r in rows if r['status']=='missing')}  mismatch: "
          f"{sum(1 for r in rows if r['status']=='MISMATCH')}")
    for r in rows:
        print(f"{r['status']:16} {r['line']:50} config={r['config_value']}")
    if a.jsonout:
        out.write_text(json.dumps(rows, indent=1) + "\n")
    return 0 if ok == len(rows) else 1

if __name__ == "__main__":
    sys.exit(main())
