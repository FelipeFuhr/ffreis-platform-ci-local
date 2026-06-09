#!/usr/bin/env python3
"""ci-local-findings.py — aggregate SARIF (+ tool JSON) findings from a local act run.

Reads every *.sarif under a findings directory, parses them generically
(SARIF 2.1.0), de-duplicates, groups by severity → tool → file, prints each
finding as `file:line · SEVERITY · tool/rule · message` with a one-line fix
hint, and exits non-zero when any ERROR-level finding is present (so it can gate
a pre-promote check).

Stdlib only. Usage:
    ci-local-findings.py <findings-dir> [--json] [--warn-as-error] [--no-color]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# ── severity ──────────────────────────────────────────────────────────────────
SEV_ORDER = {"ERROR": 0, "WARNING": 1, "NOTE": 2, "INFO": 3}
SARIF_LEVEL_TO_SEV = {"error": "ERROR", "warning": "WARNING", "note": "NOTE", "none": "INFO"}

# A leaked secret is always error-worthy regardless of the tool's SARIF level.
SEV_FLOOR = {"gitleaks": "ERROR"}


def apply_floor(tool: str, sev: str) -> str:
    floor = SEV_FLOOR.get(tool.lower())
    if floor and SEV_ORDER.get(floor, 9) < SEV_ORDER.get(sev, 9):
        return floor
    return sev


def cvss_to_sev(score: float) -> str:
    if score >= 7.0:
        return "ERROR"
    if score >= 4.0:
        return "WARNING"
    if score > 0:
        return "NOTE"
    return "INFO"


# ── remediation hints ─────────────────────────────────────────────────────────
TOOL_FIX = {
    "trivy": "bump the flagged dependency to its fixed version (see the advisory).",
    "grype": "bump the flagged dependency to its fixed version.",
    "osv-scanner": "bump the flagged dependency to a version past the advisory.",
    "osv": "bump the flagged dependency to a version past the advisory.",
    "gitleaks": "ROTATE the leaked secret, purge it from git history, and add a "
    "`[allowlist]` entry to .gitleaks.toml if it is a false positive.",
    "govulncheck": "update the module to a version that fixes the vuln (go get -u <mod>).",
    "cargo-audit": "bump the crate (cargo update -p <crate>) or accept via deny.toml.",
    "cargo-deny": "resolve per failing check — advisories: bump; bans/licenses/sources: edit deny.toml.",
    "pip-audit": "upgrade the package to the fixed version (uv lock --upgrade-package <pkg>).",
    "semgrep": "fix the flagged pattern, or add a `# nosemgrep: <rule>` with justification.",
    "golangci-lint": "fix the lint, or //nolint:<linter> // <reason> if intentional.",
    "clippy": "fix the lint, or #[allow(clippy::<rule>)] // <reason> if intentional.",
    "tflint": "address the TFLint rule, or disable it in .tflint.hcl with a reason.",
    "hadolint": "fix the Dockerfile rule (hadolint.github.io/hadolint) or inline-ignore.",
    "trivy-config": "fix the misconfiguration flagged in the IaC.",
    "scorecard": "improve the supply-chain practice the check measures.",
}


def fix_hint(tool: str, rule_id: str) -> str:
    rid = (rule_id or "").upper()
    if rid.startswith(("CVE-", "GHSA-", "RUSTSEC-", "PYSEC-", "GO-")):
        return f"bump the affected dependency past {rule_id} (see the advisory)."
    t = tool.lower()
    for key, hint in TOOL_FIX.items():
        if key in t:
            return hint
    return "review the finding and remediate or justify-suppress it."


# ── finding model ─────────────────────────────────────────────────────────────
class Finding:
    __slots__ = ("tool", "rule_id", "sev", "message", "file", "line", "source")

    def __init__(self, tool, rule_id, sev, message, file, line, source):
        self.tool, self.rule_id, self.sev = tool, rule_id, sev
        self.message, self.file, self.line, self.source = message, file, line, source

    def key(self):
        # tool IS part of the key on purpose: trivy and grype both flagging the
        # same CVE are two legitimate findings, not a duplicate.
        return (self.tool.lower(), self.rule_id, self.file, self.line)

    def as_record(self):
        return {
            "tool": self.tool, "rule": self.rule_id, "severity": self.sev,
            "file": self.file, "line": self.line, "message": self.message,
            "fix": fix_hint(self.tool, self.rule_id), "source": self.source,
        }


# ── SARIF parsing ─────────────────────────────────────────────────────────────
def _norm_uri(uri: str) -> str:
    if not uri:
        return ""
    if uri.startswith("file://"):
        uri = uri[7:]
    uri = uri.replace("\\", "/")
    while uri.startswith("./"):
        uri = uri[2:]
    return uri


def _result_severity(res: dict, rule: dict) -> str:
    for props in (res.get("properties") or {}, rule.get("properties") or {}):
        ss = props.get("security-severity")
        if ss is not None:
            try:
                return cvss_to_sev(float(ss))
            except (TypeError, ValueError):
                pass
    level = res.get("level") or rule.get("defaultConfiguration", {}).get("level")
    return SARIF_LEVEL_TO_SEV.get((level or "warning").lower(), "WARNING")


def _rule_id(res: dict, rule_list: list) -> str:
    rid = res.get("ruleId")
    if not rid and isinstance(res.get("rule"), dict):
        rid = res["rule"].get("id")
    if not rid and isinstance(res.get("ruleIndex"), int):
        i = res["ruleIndex"]
        if 0 <= i < len(rule_list):
            rid = rule_list[i].get("id")
    return rid or "?"


def _location(res: dict):
    locs = res.get("locations") or []
    if not (locs and isinstance(locs[0], dict)):
        return "", 0
    phys = locs[0].get("physicalLocation") or {}
    file_ = _norm_uri((phys.get("artifactLocation") or {}).get("uri", ""))
    line = (phys.get("region") or {}).get("startLine", 0) or 0
    return file_, line


def parse_sarif(path: Path) -> list[Finding]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError, UnicodeDecodeError) as e:
        sys.stderr.write(f"[ci-local-findings] skip {path.name}: {e}\n")
        return []
    if not isinstance(data, dict) or "runs" not in data:
        return []
    out: list[Finding] = []
    for run in data.get("runs") or []:
        driver = (run.get("tool") or {}).get("driver") or {}
        tool = driver.get("name") or driver.get("fullName") or path.stem
        rule_list = driver.get("rules") or []
        rules_by_id = {r.get("id"): r for r in rule_list if isinstance(r, dict) and r.get("id")}
        for res in run.get("results") or []:
            if not isinstance(res, dict):
                continue
            rid = _rule_id(res, rule_list)
            sev = apply_floor(tool, _result_severity(res, rules_by_id.get(rid, {})))
            msg = ((res.get("message") or {}).get("text") or "").strip().replace("\n", " ")
            file_, line = _location(res)
            out.append(Finding(tool, rid, sev, msg, file_, line, path.name))
    return out


def load_unique(root: Path):
    sarifs = sorted(root.rglob("*.sarif"))
    findings: list[Finding] = []
    for p in sarifs:
        findings.extend(parse_sarif(p))
    seen, uniq = set(), []
    for f in findings:
        k = f.key()
        if k not in seen:
            seen.add(k)
            uniq.append(f)
    uniq.sort(key=lambda f: (SEV_ORDER.get(f.sev, 9), f.tool.lower(), f.file, f.line))
    return uniq, len(sarifs)


# ── rendering ─────────────────────────────────────────────────────────────────
SEV_COLOR = {"ERROR": "red", "WARNING": "ylw", "NOTE": "cyan", "INFO": "dim"}


def _palette(enabled):
    if not enabled:
        return dict.fromkeys(("red", "ylw", "cyan", "dim", "bold", "off"), "")
    return {"red": "\033[31m", "ylw": "\033[33m", "cyan": "\033[36m",
            "dim": "\033[2m", "bold": "\033[1m", "off": "\033[0m"}


def render_human(uniq, n_files, c):
    counts = {s: sum(1 for f in uniq if f.sev == s) for s in SEV_ORDER}
    print(f"{c['bold']}── Local CI findings ──{c['off']}  "
          f"({len(uniq)} unique from {n_files} report file(s))")
    if not uniq:
        print(f"  {c['cyan']}no findings{c['off']}")
        return
    print("  " + "  ".join(f"{c[SEV_COLOR[s]]}{s}: {counts[s]}{c['off']}"
                           for s in SEV_ORDER if counts[s]) + "\n")
    cur = None
    for f in uniq:
        if f.sev != cur:
            cur = f.sev
            print(f"{c[SEV_COLOR[f.sev]]}{c['bold']}{f.sev}{c['off']}")
        loc = f"{f.file}:{f.line}" if f.file else "(no location)"
        print(f"  {c['bold']}{loc}{c['off']}  {c['dim']}{f.tool}/{f.rule_id}{c['off']}")
        if f.message:
            print(f"      {f.message}")
        print(f"      {c['dim']}↳ fix: {fix_hint(f.tool, f.rule_id)}{c['off']}")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("findings_dir", help="directory containing *.sarif")
    ap.add_argument("--json", action="store_true", help="emit ndjson (one finding per line)")
    ap.add_argument("--warn-as-error", action="store_true", help="also gate on WARNING findings")
    ap.add_argument("--no-color", action="store_true")
    args = ap.parse_args()

    root = Path(args.findings_dir)
    if not root.is_dir():
        sys.stderr.write(f"[ci-local-findings] no findings dir: {root}\n")
        return 0

    uniq, n_files = load_unique(root)
    errs = sum(1 for f in uniq if f.sev == "ERROR")
    warns = sum(1 for f in uniq if f.sev == "WARNING")
    fail = bool(errs or (args.warn_as_error and warns))

    if args.json:
        for f in uniq:
            print(json.dumps(f.as_record(), separators=(",", ":")))
        return 1 if fail else 0

    c = _palette(sys.stdout.isatty() and not args.no_color)
    render_human(uniq, n_files, c)
    if not uniq:
        return 0
    print()
    if fail:
        tail = f", {warns} warning(s)" if args.warn_as_error else ""
        print(f"{c['red']}{c['bold']}GATE: FAIL{c['off']} — {errs} error(s){tail}")
        return 1
    print(f"{c['cyan']}GATE: pass{c['off']} (no error-level findings)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
