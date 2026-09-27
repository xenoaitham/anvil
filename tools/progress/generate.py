#!/usr/bin/env python3
"""Generate progress/index.html from progress/progress.json.

Run after every status change:
    python3 tools/progress/generate.py

The page auto-refreshes; CI regenerates it on every push.
"""
from __future__ import annotations

import html
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
PROGRESS = ROOT / "progress" / "progress.json"
OUT = ROOT / "progress" / "index.html"

STATUS_STYLE = {
    "pending": ("#6b7280", "pending"),
    "in_progress": ("#b45309", "in progress"),
    "passed": ("#15803d", "critic-picked: ours"),
    "failed": ("#b91c1c", "failed"),
}

ROW = """<tr>
  <td><strong>{title}</strong><br><span class="dim">{owner}</span></td>
  <td><span class="pill" style="background:{color}">{status}</span></td>
  <td>{rounds}</td>
  <td>{commits}</td>
  <td>{evidence}</td>
</tr>"""


def rounds_html(piece: dict) -> str:
    if not piece.get("rounds"):
        return '<span class="dim">—</span>'
    rows = []
    for r in piece["rounds"]:
        verdict = r.get("verdict", "?")
        gap = html.escape(r.get("gap", ""))
        rows.append(f"R{r.get('round', '?')}: <strong>{verdict}</strong> — {gap}")
    return "<br>".join(rows)


def render(data: dict) -> str:
    m = data["metrics"]
    rows = []
    for p in data["pieces"]:
        color, label = STATUS_STYLE.get(p.get("status", "pending"), STATUS_STYLE["pending"])
        commits = "<br>".join(
            f'<code>{html.escape(c)}</code>' for c in p.get("commits", [])
        ) or '<span class="dim">—</span>'
        evidence = "<br>".join(
            f'<code>{html.escape(e)}</code>' for e in p.get("evidence", [])
        ) or '<span class="dim">—</span>'
        rows.append(
            ROW.format(
                title=html.escape(p["title"]),
                owner=html.escape(p.get("owner", "")),
                color=color,
                status=label,
                rounds=rounds_html(p),
                commits=commits,
                evidence=evidence,
            )
        )
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="20">
<title>{html.escape(data['project'])} — live build progress</title>
<style>
  body {{ font-family: ui-sans-serif, system-ui, sans-serif; background: #0f1115; color: #e5e7eb;
         margin: 0; padding: 2rem; }}
  h1 {{ font-weight: 700; margin: 0 0 .25rem; }}
  .tagline {{ color: #9ca3af; margin-bottom: 1.5rem; }}
  .metrics {{ display: flex; gap: 1rem; flex-wrap: wrap; margin-bottom: 1.5rem; }}
  .metric {{ background: #161a22; border: 1px solid #2a2f3a; border-radius: 8px;
             padding: .75rem 1rem; min-width: 9rem; }}
  .metric b {{ display: block; font-size: 1.6rem; }}
  table {{ border-collapse: collapse; width: 100%; background: #161a22;
           border: 1px solid #2a2f3a; border-radius: 8px; overflow: hidden; }}
  th, td {{ text-align: left; padding: .6rem .8rem; border-bottom: 1px solid #232833;
            vertical-align: top; font-size: .92rem; }}
  th {{ background: #1b202b; }}
  .pill {{ color: #fff; border-radius: 999px; padding: .15rem .6rem; font-size: .78rem; }}
  code {{ background: #0f1115; padding: .1rem .35rem; border-radius: 4px; font-size: .8rem; }}
  .dim {{ color: #6b7280; }}
  footer {{ margin-top: 1.5rem; color: #9ca3af; max-width: 60rem; }}
</style>
</head>
<body>
<h1>{html.escape(data['project'])} — live build progress</h1>
<p class="tagline">{html.escape(data.get('tagline', ''))}</p>
<div class="metrics">
  <div class="metric"><b>{m['pieces_passed']}/{m['pieces_total']}</b>pieces passed</div>
  <div class="metric"><b>{m['critic_wins_ours']}</b>blind critic wins (ours)</div>
  <div class="metric"><b>{m['total_review_rounds']}</b>review rounds</div>
</div>
<table>
<thead><tr><th>piece</th><th>status</th><th>critic rounds</th><th>commits</th><th>evidence</th></tr></thead>
<tbody>
{''.join(rows)}
</tbody>
</table>
<footer><strong>Honesty policy:</strong> {html.escape(data.get('honesty_policy', ''))}</footer>
</body>
</html>
"""


def main() -> int:
    if not PROGRESS.exists():
        print(f"missing {PROGRESS}", file=sys.stderr)
        return 1
    data = json.loads(PROGRESS.read_text())
    OUT.write_text(render(data))
    print(f"wrote {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
