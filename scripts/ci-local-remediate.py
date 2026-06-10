#!/usr/bin/env python3
"""ci-local-remediate.py — turn local findings into an action plan.

Reads the aggregated findings (via ci-local-findings.py --json), groups them by
remediation category, and emits either:
  • INLINE     — a small, single-category set: fix directly in the main thread.
  • QUEUED      (default) — a sequence of ready-to-dispatch fix-prompts, ONE per
                 category, so parallel work doesn't lose the main chain of thought.
  • AUTO-PARALLEL (--auto-parallel) — per-category worktree-subagent dispatch lines.

The decision rule: inline when ≤3 errors AND ≤1 error-bearing category; otherwise
queued (the safe default — the human dispatches the parallel work). This is the
orchestration contract behind the harness: findings → a plan, not a dead end.

Stdlib only. Usage:
    ci-local-remediate.py <.ci-local dir> [--repo <path>] [--auto-parallel] [--json]
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

# tool → remediation category (drives one fix-prompt per category)
CATEGORY = {
    "trivy": "deps", "grype": "deps", "osv-scanner": "deps", "osv": "deps",
    "govulncheck": "deps", "cargo-audit": "deps", "pip-audit": "deps",
    "gitleaks": "secrets",
    "semgrep": "sast", "codeql": "sast",
    "sonar": "quality",
    "golangci-lint": "lint", "clippy": "lint", "shellcheck": "lint",
    "actionlint": "lint", "markdownlint": "lint", "ruff": "lint",
    "checkov": "iac", "tfsec": "iac", "tflint": "iac", "hadolint": "iac",
    "cargo-deny": "policy",
}


def category(tool: str) -> str:
    t = (tool or "").lower()
    for key, cat in CATEGORY.items():
        if key in t:
            return cat
    return "other"


def load_findings(cil: Path, scripts_dir: Path) -> list[dict]:
    """Reuse the canonical aggregator's --json output (ndjson)."""
    agg = scripts_dir / "ci-local-findings.py"
    findings_dir = cil / "findings"
    try:
        proc = subprocess.run(
            [sys.executable, str(agg), str(findings_dir), "--json"],
            capture_output=True, text=True, check=False,
        )
    except OSError:
        return []
    rows = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if line:
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return rows


def plan(rows: list[dict]):
    by_cat: dict[str, list[dict]] = defaultdict(list)
    for r in rows:
        by_cat[category(r.get("tool", ""))].append(r)
    n_err = sum(1 for r in rows if r.get("severity") == "ERROR")
    err_cats = [c for c, items in by_cat.items()
                if any(x.get("severity") == "ERROR" for x in items)]
    inline = n_err <= 3 and len(err_cats) <= 1
    return by_cat, n_err, inline


def render(rows, by_cat, n_err, inline, repo, auto_parallel):
    print(f"── Remediation plan ──  {len(rows)} finding(s), {n_err} error(s), "
          f"{len(by_cat)} categor(ies)")
    if not rows:
        print("  nothing to remediate.")
        return
    if inline:
        print("\nMode: INLINE (small, single error-category) — fix directly now:")
        for r in (r for r in rows if r.get("severity") == "ERROR") or rows:
            print(f"  • {r.get('file')}:{r.get('line')} "
                  f"[{r.get('tool')}/{r.get('rule')}] {r.get('message')}")
            print(f"    fix: {r.get('fix')}")
        return
    mode = "AUTO-PARALLEL (worktree subagents)" if auto_parallel else "QUEUED PROMPTS"
    print(f"\nMode: {mode} — {len(by_cat)} categor(ies); handle each independently "
          "so the main thread isn't lost.\n")
    for i, (cat, items) in enumerate(sorted(by_cat.items()), 1):
        errs = sum(1 for x in items if x.get("severity") == "ERROR")
        print(f"[{i}] category={cat}  ({len(items)} finding(s), {errs} error(s))")
        if auto_parallel:
            locs = "; ".join(f"{x.get('file')}:{x.get('line')}" for x in items[:10])
            print(f"    → spawn a worktree-isolated subagent (isolation:\"worktree\") to fix "
                  f"the {cat} findings in {repo}: {locs}")
        else:
            print(f"    PROMPT — In {repo}, fix these {cat} findings, then re-run "
                  f"`make ci-local ARGS=--full`:")
            for x in items:
                print(f"      - {x.get('file')}:{x.get('line')} "
                      f"[{x.get('tool')}/{x.get('rule')}] {x.get('message')} "
                      f"→ {x.get('fix')}")
        print()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("cil", help="the .ci-local directory from a harness run")
    ap.add_argument("--repo", default=".", help="repo path to reference in prompts")
    ap.add_argument("--auto-parallel", action="store_true",
                    help="emit worktree-subagent dispatch lines instead of queued prompts")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    scripts_dir = Path(__file__).resolve().parent
    rows = load_findings(Path(args.cil), scripts_dir)
    by_cat, n_err, inline = plan(rows)

    if args.json:
        print(json.dumps({
            "total": len(rows), "errors": n_err, "inline": inline,
            "categories": {c: items for c, items in by_cat.items()},
        }, indent=2))
        return 0

    render(rows, by_cat, n_err, inline, args.repo, args.auto_parallel)
    return 0


if __name__ == "__main__":
    sys.exit(main())
