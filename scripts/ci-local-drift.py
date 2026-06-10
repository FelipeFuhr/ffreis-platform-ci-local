#!/usr/bin/env python3
"""ci-local-drift.py — the drift gate: guarantee no CI check falls off-local.

Every reusable-workflow a repo's CI references must be CLASSIFIED in the central
registry (ci-local-tools.tsv) — as a findings producer that runs locally (lane
A/B), one that genuinely can't (cannot), or an explicit non-findings workflow
(na). A reference with NO matching registry row is **drift**: a CI check nobody
decided how to run locally. This tool finds it.

  --warn     (default) report drift, exit 0 — for the fleet audit / rollout
  --enforce  exit 1 if any referenced workflow is unclassified — the gate

It reads the reusable-workflow references (the fleet's unit of a CI check —
`uses: FelipeFuhr/ffreis-workflows-*/.github/workflows/<name>.yml@SHA` and local
`./.github/workflows/<name>.yml`) from a repo's workflows and matches each
basename against the registry's workflow_pattern column.

Stdlib only. Usage:
    ci-local-drift.py --registry <tsv> --workflows <dir> [--enforce] [--json] [--no-color]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# `uses:` referencing a fleet reusable workflow (remote) or a local one.
RE_REMOTE = re.compile(
    r"uses:\s*FelipeFuhr/ffreis-workflows-[^/]+/\.github/workflows/([a-z0-9-]+)\.ya?ml",
    re.I,
)
RE_LOCAL = re.compile(r"uses:\s*\./\.github/workflows/([a-z0-9-]+)\.ya?ml", re.I)


def load_registry(path: Path) -> list[dict]:
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        rows.append({"tool": parts[0].strip(), "lane": parts[1].strip(),
                     "pattern": parts[2].strip()})
    return rows


def referenced_workflows(workflows_dir: Path) -> set[str]:
    """Reusable-workflow basenames this repo's CI references (consumer mode)."""
    refs: set[str] = set()
    if not workflows_dir.is_dir():
        return refs
    for wf in sorted(workflows_dir.glob("*.y*ml")):
        try:
            text = wf.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for rx in (RE_REMOTE, RE_LOCAL):
            refs.update(m.lower() for m in rx.findall(text))
    return refs


# Meta/infra workflows a lib may define that are NOT fleet reusable tools.
META_WORKFLOWS = {"self-test", "ci", "release-please", "renovate", "release-please-manifest"}


def defined_workflows(workflows_dir: Path) -> set[str]:
    """Reusable-workflow basenames a LIBRARY defines (files with on: workflow_call).
    Used by a workflow-lib's self-test: adding a new reusable workflow must be
    classified in the registry or the gate fails — catching drift at the source.
    Meta/infra workflows (self-test, ci, release-please, …) are excluded."""
    defs: set[str] = set()
    if not workflows_dir.is_dir():
        return defs
    for wf in sorted(workflows_dir.glob("*.y*ml")):
        if wf.stem.lower() in META_WORKFLOWS:
            continue
        try:
            text = wf.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if re.search(r"^\s*workflow_call:", text, re.M):
            defs.add(wf.stem.lower())
    return defs


def classify(refs: set[str], registry: list[dict]) -> tuple[dict, list[str]]:
    """Map each ref → matching registry lane; collect the unclassified."""
    classified: dict[str, str] = {}
    unclassified: list[str] = []
    for ref in sorted(refs):
        lane = None
        for row in registry:
            if row["pattern"] and re.search(row["pattern"], ref, re.I):
                lane = row["lane"]
                break
        if lane is None:
            unclassified.append(ref)
        else:
            classified[ref] = lane
    return classified, unclassified


PALETTE = {"red": "\033[31m", "grn": "\033[32m", "dim": "\033[2m",
           "bold": "\033[1m", "off": "\033[0m"}


def render(classified, unclassified, enforce, color):
    c = PALETTE if color else dict.fromkeys(PALETTE, "")
    total = len(classified) + len(unclassified)
    print(f"{c['bold']}── CI-local drift check ──{c['off']}  "
          f"({total} reusable-workflow ref(s))")
    for ref, lane in sorted(classified.items()):
        print(f"  {c['grn']}✓{c['off']} {ref}  {c['dim']}lane={lane}{c['off']}")
    if unclassified:
        print(f"\n  {c['red']}{c['bold']}DRIFT — {len(unclassified)} unclassified:{c['off']}")
        for ref in unclassified:
            print(f"    {c['red']}✗{c['off']} {ref}")
        verb = "FAIL" if enforce else "WARN"
        print(f"\n  {c['red'] if enforce else c['dim']}{c['bold']}{verb}{c['off']} — "
              f"add a row to ci-local-tools.tsv classifying each: lane A (act-runnable), "
              f"B (direct-CLI/container), cannot (with reason), or na (non-findings).")
    else:
        print(f"\n  {c['grn']}{c['bold']}no drift{c['off']} — every CI check is classified.")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--registry", required=True)
    ap.add_argument("--workflows", required=True)
    ap.add_argument("--enforce", action="store_true", help="exit non-zero on any drift")
    ap.add_argument("--warn", action="store_true", help="report only (default)")
    ap.add_argument("--defines", action="store_true",
                    help="library mode: check the reusable workflows this dir DEFINES "
                         "(on: workflow_call), not the ones it references")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--no-color", action="store_true")
    args = ap.parse_args()

    registry = load_registry(Path(args.registry))
    refs = (defined_workflows(Path(args.workflows)) if args.defines
            else referenced_workflows(Path(args.workflows)))
    classified, unclassified = classify(refs, registry)

    if args.json:
        print(json.dumps({"classified": classified, "unclassified": unclassified}, indent=2))
    else:
        render(classified, unclassified, args.enforce,
               sys.stdout.isatty() and not args.no_color)

    return 1 if (args.enforce and unclassified) else 0


if __name__ == "__main__":
    sys.exit(main())
