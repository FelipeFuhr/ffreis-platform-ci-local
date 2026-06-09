#!/usr/bin/env bash
# self-test.sh — stdlib-only smoke test of the python helpers against fixtures.
# Verifies: (1) ci-local-findings.py lists a planted finding + gates non-zero on
# ERROR; (2) ci-local-coverage.py buckets tools (found / ran / UNACCOUNTED /
# cannot-run) correctly. No act, no network — runs anywhere with python3.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
scripts="$root/scripts"
work="$(mktemp -d -t ci-local-selftest.XXXXXX)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/findings" "$work/wf"
fail=0
check() { if [[ "$1" == "$2" ]]; then echo "  ok: $3"; else echo "  FAIL: $3 (got '$1', want '$2')"; fail=1; fi; }

# ── fixture 1: a gitleaks SARIF with one ERROR result ────────────────────────
cat > "$work/findings/gitleaks.sarif" <<'EOF'
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"gitleaks","rules":[]}},
"results":[{"ruleId":"github-pat","level":"error","message":{"text":"leaked token"},
"locations":[{"physicalLocation":{"artifactLocation":{"uri":"config.env"},"region":{"startLine":2}}}]}]}]}
EOF
# a trivy SARIF with zero results (ran clean)
cat > "$work/findings/trivy.sarif" <<'EOF'
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Trivy","rules":[]}},"results":[]}]}
EOF

echo "[self-test] ci-local-findings.py"
# the tool intentionally exits non-zero on ERROR — capture without tripping set -e
out="$(python3 "$scripts/ci-local-findings.py" "$work/findings" --no-color 2>&1)" && rc=0 || rc=$?
echo "$out" | grep -q 'config.env:2' && a=ok || a=no
check "$a" ok "findings report shows config.env:2"
echo "$out" | grep -q 'GATE: FAIL' && a=ok || a=no
check "$a" ok "findings gate FAILs on the ERROR finding"
check "$rc" 1 "findings exit code is non-zero on ERROR"

# ── fixture 2: a workflow referencing gitleaks (Lane A) + codeql (Lane B) ─────
cat > "$work/wf/security.yml" <<'EOF'
jobs:
  s:
    uses: FelipeFuhr/ffreis-workflows-general/.github/workflows/general-gitleaks.yml@deadbeef
  c:
    uses: FelipeFuhr/ffreis-workflows-general/.github/workflows/general-codeql.yml@deadbeef
EOF
echo '{"jobs":{}}' > "$work/run.json"   # presence ⇒ act ran

echo "[self-test] ci-local-coverage.py"
cov="$(python3 "$scripts/ci-local-coverage.py" --registry "$scripts/ci-local-tools.tsv" \
  --workflows "$work/wf" --findings "$work/findings" --run-json "$work/run.json" --no-color 2>&1)"
echo "$cov" | grep -qE 'found .*gitleaks' && a=ok || a=no
check "$a" ok "coverage: gitleaks = found (1 finding)"
echo "$cov" | grep -qE 'cannot-run .*codeql' && a=ok || a=no
check "$a" ok "coverage: codeql = cannot-run (Lane B, no dispatch)"

# JSON mode parses
python3 "$scripts/ci-local-coverage.py" --registry "$scripts/ci-local-tools.tsv" \
  --workflows "$work/wf" --findings "$work/findings" --json >/dev/null 2>&1 && a=ok || a=no
check "$a" ok "coverage --json emits valid output"

# ── fixture 3: sonar issues → SARIF → through the aggregator ──────────────────
echo "[self-test] sonar-issues-to-sarif.py"
conv="$root/backends/sonarqube/sonar-issues-to-sarif.py"
cat > "$work/sonar-issues.json" <<'EOF'
{"issues":[
{"rule":"go:S1192","severity":"CRITICAL","component":"p:internal/foo.go","line":42,"message":"dup literal"},
{"rule":"secrets:S6290","severity":"BLOCKER","component":"p:config.go","textRange":{"startLine":7},"message":"token leak"}]}
EOF
python3 "$conv" "$work/sonar-issues.json" "$work/sonar-conv.sarif" p >/dev/null 2>&1 && a=ok || a=no
check "$a" ok "converter writes SARIF"
python3 - "$work/sonar-conv.sarif" <<'PY' && a=ok || a=no
import json,sys
d=json.load(open(sys.argv[1])); r=d["runs"][0]
assert r["tool"]["driver"]["name"]=="sonar"
levels={x["level"] for x in r["results"]}
assert "error" in levels  # BLOCKER+CRITICAL → error
assert r["results"][1]["locations"][0]["physicalLocation"]["artifactLocation"]["uri"]=="config.go"
PY
check "$a" ok "converter: driver=sonar, BLOCKER/CRITICAL→error, component path stripped"

if [[ "$fail" -ne 0 ]]; then echo "[self-test] FAILED"; exit 1; fi
echo "[self-test] all checks passed"
