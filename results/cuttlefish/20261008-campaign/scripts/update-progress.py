#!/usr/bin/env python3
"""update-progress.py — refresh the repo's live progress page for the
cuttlefish boot campaign. RECONSTRUCTED 2026-10-08.

Usage: update-progress.py <status> <one-line-note> [<evidence-line>...]
"""
import json, pathlib, subprocess, sys, datetime

REPO = pathlib.Path("/home/potato/grafene/anvil")
PJ = REPO / "progress" / "progress.json"

def main():
    status = sys.argv[1]
    note = sys.argv[2]
    evidence = sys.argv[3:]
    d = json.loads(PJ.read_text())
    piece = next(p for p in d["pieces"] if p["id"] == "cuttlefish-kernel")
    piece["status"] = status
    rounds = piece.setdefault("rounds", [])
    r2 = next((r for r in rounds if r.get("round") == 2), None)
    if r2 is None:
        r2 = {"round": 2, "verdict": "pending", "gap": "", "detail": ""}
        rounds.append(r2)
    r2["detail"] = (r2.get("detail", "") + "\n" if r2.get("detail") else "") + note
    if evidence:
        ev = piece.setdefault("evidence", [])
        for e in evidence:
            if e not in ev:
                ev.append(e)
    d["updated"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    PJ.write_text(json.dumps(d, indent=2) + "\n")
    subprocess.run(["python3", str(REPO / "tools/progress/generate.py")], check=True)
    print("progress page updated:", d["updated"])

if __name__ == "__main__":
    main()
