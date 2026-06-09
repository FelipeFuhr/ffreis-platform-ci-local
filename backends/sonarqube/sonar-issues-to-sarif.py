#!/usr/bin/env python3
"""sonar-issues-to-sarif.py — convert a SonarQube /api/issues/search response
into SARIF 2.1.0 so Sonar findings flow through ci-local-findings.py like every
other tool (one `file:line · severity · tool/rule · message · fix` pipeline).

The driver name is "sonar" so the aggregator/coverage normalizer maps it onto
the registry's `sonar` key. Severity maps SonarQube → SARIF:
  BLOCKER, CRITICAL → error    MAJOR → warning    MINOR, INFO → note

Stdlib only. Usage:
    sonar-issues-to-sarif.py <issues.json> <out.sarif> [<projectKey>]
"""

from __future__ import annotations

import json
import sys

SEVERITY_TO_LEVEL = {
    "BLOCKER": "error",
    "CRITICAL": "error",
    "MAJOR": "warning",
    "MINOR": "note",
    "INFO": "note",
}


def _component_to_path(component: str, project_key: str) -> str:
    """`projectKey:path/to/file` → `path/to/file` (component is project-relative)."""
    if not component:
        return ""
    prefix = f"{project_key}:" if project_key else ""
    if prefix and component.startswith(prefix):
        return component[len(prefix):]
    # fall back to stripping any `key:` prefix
    return component.split(":", 1)[1] if ":" in component else component


def to_sarif(issues_doc: dict, project_key: str) -> dict:
    results = []
    for issue in issues_doc.get("issues") or []:
        level = SEVERITY_TO_LEVEL.get((issue.get("severity") or "").upper(), "warning")
        path = _component_to_path(issue.get("component") or "", project_key)
        line = issue.get("line") or issue.get("textRange", {}).get("startLine") or 1
        result = {
            "ruleId": issue.get("rule") or "sonar",
            "level": level,
            "message": {"text": (issue.get("message") or "").strip()},
        }
        if path:
            result["locations"] = [{
                "physicalLocation": {
                    "artifactLocation": {"uri": path},
                    "region": {"startLine": int(line)},
                }
            }]
        results.append(result)
    return {
        "version": "2.1.0",
        "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
        "runs": [{
            "tool": {"driver": {"name": "sonar", "informationUri": "https://www.sonarsource.com/"}},
            "results": results,
        }],
    }


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        sys.stderr.write("usage: sonar-issues-to-sarif.py <issues.json> <out.sarif> [<projectKey>]\n")
        return 2
    in_path, out_path = argv[1], argv[2]
    project_key = argv[3] if len(argv) > 3 else ""
    try:
        with open(in_path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        sys.stderr.write(f"[sonar→sarif] cannot read {in_path}: {exc}\n")
        return 1
    sarif = to_sarif(doc, project_key)
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(sarif, fh, indent=2)
    n = len(sarif["runs"][0]["results"])
    sys.stderr.write(f"[sonar→sarif] wrote {n} issue(s) → {out_path}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
