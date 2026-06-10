#!/usr/bin/env python3
"""ci-local-coverage.py — the "nothing silent" completeness assertion.

Reconciles the tools THIS repo's CI references (from .github/workflows/ via the
ci-local-tools.tsv registry) against the tools the local run actually accounted
for, so no CI scanner can fail silently. Every in-CI tool lands in exactly one
bucket:

    ran           Lane A: a captured SARIF carries the tool's driver name
                  (a clean run still emits an empty-but-named SARIF).
    found         Lane A: that SARIF carried >=1 result.
    direct        Lane B: ci-local-laneB.sh ran it (status from lane-b.json).
    cannot-run    no faithful local run exists — recorded with the reason.
    UNACCOUNTED   in CI, but produced no local row/SARIF and isn't lane=cannot
                  → reported LOUDLY (e.g. a workflow_dispatch-only or
                  draft-gated scanner act never triggered).

Stdlib only. Usage:
    ci-local-coverage.py --registry <tsv> --workflows <dir> --findings <dir> \
        [--lane-b <json>] [--run-json <json>] [--json] [--no-color]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


def load_registry(path: Path) -> list[dict]:
    """Parse the tab-separated tool registry, skipping comments/blank lines."""
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 5:
            continue
        tool, lane, pattern, probe, reason = (p.strip() for p in parts[:5])
        rows.append({"tool": tool, "lane": lane, "pattern": pattern,
                     "probe": probe, "reason": reason})
    return rows


def tools_in_ci(registry: list[dict], workflows_dir: Path) -> set[str]:
    """Tools whose workflow_pattern appears in any workflow file."""
    blob = ""
    if workflows_dir.is_dir():
        for wf in sorted(workflows_dir.glob("*.y*ml")):
            try:
                blob += wf.read_text(encoding="utf-8", errors="replace") + "\n"
            except OSError:
                pass
    in_ci = set()
    for row in registry:
        if row["pattern"] and re.search(row["pattern"], blob, re.I):
            in_ci.add(row["tool"])
    return in_ci


def _norm(name: str) -> str:
    """Normalize a SARIF driver name to the registry's canonical key."""
    n = re.sub(r"[^a-z0-9]+", "-", (name or "").lower()).strip("-")
    # collapse known aliases onto registry keys
    aliases = {
        "trivy": "trivy", "grype": "grype", "gitleaks": "gitleaks",
        "osv-scanner": "osv-scanner", "osv": "osv-scanner",
        "semgrep": "semgrep", "govulncheck": "govulncheck",
        "golangci-lint": "golangci-lint", "clippy": "clippy",
        "cargo-audit": "cargo-audit", "cargo-deny": "cargo-deny",
        "pip-audit": "pip-audit", "codeql": "codeql",
        "sonarqube": "sonar", "sonarcloud": "sonar", "sonar": "sonar",
    }
    for key, canon in aliases.items():
        if key in n:
            return canon
    return n


def lane_a_accounted(findings_dir: Path) -> dict[str, int]:
    """Map each Lane-A tool that produced a captured SARIF → its result count."""
    counts: dict[str, int] = {}
    if not findings_dir.is_dir():
        return counts
    for sp in sorted(findings_dir.glob("*.sarif")):
        try:
            data = json.loads(sp.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError, UnicodeDecodeError):
            continue
        for run in data.get("runs") or []:
            driver = (run.get("tool") or {}).get("driver") or {}
            tool = _norm(driver.get("name") or driver.get("fullName") or sp.stem)
            counts[tool] = counts.get(tool, 0) + len(run.get("results") or [])
    return counts


def build_coverage(registry, in_ci, sarif_counts, lane_b, act_ran):
    """Classify every in-CI tool into a bucket. Returns (rows, unaccounted)."""
    by_tool = {r["tool"]: r for r in registry}
    rows, unaccounted = [], []
    for tool in sorted(in_ci):
        row = by_tool[tool]
        lane, reason = row["lane"], row["reason"]
        if lane == "na":
            continue  # not a findings producer (build/test/fmt/housekeeping)
        if lane == "cannot":
            rows.append((tool, "cannot-run", reason))
        elif lane == "B":
            lb = lane_b.get(tool)
            if lb:
                rows.append((tool, lb.get("status", "direct"), lb.get("detail", "")))
            else:
                rows.append((tool, "cannot-run", reason or "Lane-B tool not dispatched"))
        else:  # Lane A
            if tool in sarif_counts:
                n = sarif_counts[tool]
                rows.append((tool, "found" if n else "ran", f"{n} finding(s)" if n else "clean"))
            elif act_ran:
                rows.append((tool, "UNACCOUNTED",
                             "in CI but no local SARIF — act may not have triggered it "
                             "(workflow_dispatch-only / draft-gated / event mismatch)"))
                unaccounted.append(tool)
            else:
                rows.append((tool, "skipped", "act did not run (lane-b-only / no act)"))
    return rows, unaccounted


PALETTE = {"red": "\033[31m", "ylw": "\033[33m", "grn": "\033[32m",
           "cyan": "\033[36m", "dim": "\033[2m", "bold": "\033[1m", "off": "\033[0m"}
BUCKET_COLOR = {"found": "ylw", "ran": "grn", "direct": "grn", "found-direct": "ylw",
                "cannot-run": "dim", "skipped": "dim", "UNACCOUNTED": "red"}


def render(rows, unaccounted, color):
    c = PALETTE if color else dict.fromkeys(PALETTE, "")
    icon = {"found": "🔎", "ran": "✅", "direct": "✅", "found-direct": "🔎",
            "cannot-run": "⏭", "skipped": "·", "UNACCOUNTED": "❗"}
    print(f"{c['bold']}── CI tool coverage ──{c['off']}  "
          f"({len(rows)} tool(s) referenced by this repo's workflows)")
    for tool, bucket, detail in rows:
        col = c[BUCKET_COLOR.get(bucket, "dim")]
        print(f"  {icon.get(bucket, '?')} {col}{bucket:<12}{c['off']} {tool}"
              f"  {c['dim']}{detail}{c['off']}")
    if unaccounted:
        print(f"\n{c['red']}{c['bold']}UNACCOUNTED ({len(unaccounted)}):{c['off']} "
              f"{', '.join(unaccounted)}")
        print(f"{c['dim']}  These tools run in CI but produced no local finding. "
              f"They are NOT silently passing — verify each ran in real CI or run "
              f"it directly.{c['off']}")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--registry", required=True)
    ap.add_argument("--workflows", required=True)
    ap.add_argument("--findings", required=True)
    ap.add_argument("--lane-b", help="lane-b.json from ci-local-laneB.sh")
    ap.add_argument("--run-json", help="run.json from the act classifier (presence ⇒ act ran)")
    ap.add_argument("--json", action="store_true", help="emit the coverage as JSON")
    ap.add_argument("--strict", action="store_true",
                    help="exit non-zero if a SARIF-native scanner is UNACCOUNTED "
                         "(a real local-capture failure, e.g. the trivy-action PATH bug) — "
                         "ignores stdout-only linters whose SARIF lands via Phase 2")
    ap.add_argument("--no-color", action="store_true")
    args = ap.parse_args()

    registry = load_registry(Path(args.registry))
    in_ci = tools_in_ci(registry, Path(args.workflows))
    sarif_counts = lane_a_accounted(Path(args.findings))

    lane_b = {}
    if args.lane_b and Path(args.lane_b).is_file():
        try:
            lane_b = json.loads(Path(args.lane_b).read_text(encoding="utf-8")).get("tools", {})
        except (json.JSONDecodeError, OSError):
            pass

    act_ran = bool(args.run_json and Path(args.run_json).is_file())

    rows, unaccounted = build_coverage(registry, in_ci, sarif_counts, lane_b, act_ran)

    # SARIF-native scanners emit SARIF under act TODAY; if one is UNACCOUNTED it's
    # a real local-capture failure worth gating. Stdout-only linters are expected
    # UNACCOUNTED until Phase 2 wires their SARIF, so --strict ignores them.
    sarif_native = {"trivy", "grype", "gitleaks", "osv-scanner", "semgrep"}
    strict_breach = sorted(t for t in unaccounted if t in sarif_native)

    if args.json:
        print(json.dumps({"coverage": [{"tool": t, "bucket": b, "detail": d}
                                       for t, b, d in rows],
                          "unaccounted": unaccounted,
                          "strict_breach": strict_breach}, indent=2))
        return 1 if (args.strict and strict_breach) else 0

    render(rows, unaccounted, sys.stdout.isatty() and not args.no_color)
    if args.strict and strict_breach:
        print(f"\nSTRICT: {len(strict_breach)} SARIF-native scanner(s) UNACCOUNTED "
              f"({', '.join(strict_breach)}) — local capture failed, not just missing.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
