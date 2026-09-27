#!/usr/bin/env python3
"""Prepare a blind review: copy Anvil's artifact ("ours") and GrapheneOS's
equivalent ("theirs") into candidate_A/ and candidate_B/ with a randomized
assignment, so a fresh-context critic cannot tell which is which.

Usage:
  python3 tools/review/anonymize.py <piece_id> \
      --ours  path/to/ours1 [path/to/ours2 ...] \
      --theirs path/to/theirs1 [path/to/theirs2 ...]

Paths may be absolute or workspace-relative; files and directories are both
accepted. Directory contents are copied recursively, preserving the basenames
of the top-level arguments. The A/B mapping is written to
.review/<piece_id>/.mapping.json (gitignored) and printed to stdout for the
orchestrator only.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import secrets
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]


def copy_into(src: pathlib.Path, dest_dir: pathlib.Path) -> str:
    target = dest_dir / src.name
    if src.is_dir():
        shutil.copytree(src, target, ignore=shutil.ignore_patterns(".git"))
    else:
        shutil.copy2(src, target)
    return src.name


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("piece")
    ap.add_argument("--ours", nargs="+", required=True)
    ap.add_argument("--theirs", nargs="+", required=True)
    args = ap.parse_args()

    review_dir = ROOT / ".review" / args.piece
    if review_dir.exists():
        shutil.rmtree(review_dir)
    a_dir = review_dir / "candidate_A"
    b_dir = review_dir / "candidate_B"
    a_dir.mkdir(parents=True)
    b_dir.mkdir(parents=True)

    ours = [pathlib.Path(p) for p in args.ours]
    theirs = [pathlib.Path(p) for p in args.theirs]
    for p in ours + theirs:
        if not p.exists():
            print(f"missing path: {p}", file=sys.stderr)
            return 1

    ours_is_a = secrets.randbelow(2) == 0

    first, second = (a_dir, b_dir) if ours_is_a else (b_dir, a_dir)
    for p in ours:
        copy_into(p.resolve(), first)
    for p in theirs:
        copy_into(p.resolve(), second)

    mapping = {
        "piece": args.piece,
        "ours": "candidate_A" if ours_is_a else "candidate_B",
        "theirs": "candidate_B" if ours_is_a else "candidate_A",
        "ours_sources": [str(p) for p in ours],
        "theirs_sources": [str(p) for p in theirs],
    }
    mapping_path = review_dir / ".mapping.json"
    mapping_path.write_text(json.dumps(mapping, indent=2) + "\n")
    print(json.dumps(mapping, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
