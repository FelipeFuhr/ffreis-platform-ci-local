#!/usr/bin/env bash
# ci-local-laneB.sh — run the direct-CLI scanners act CAN'T (codeql, sonar).
#
# act faithfully reproduces lint/test/build and the SARIF-emitting CLIs ("Lane
# A"). Server-side / GitHub-only tools ("Lane B" — codeql needs a multi-GB DB,
# sonar needs a server) never run under act, so their findings are silently
# absent. This dispatcher runs each Lane-B tool by its own CLI, writes any SARIF
# into <cil>/findings/ (so it flows through ci-local-findings.py like Lane A),
# and records a per-tool status to <cil>/lane-b.json (consumed by
# ci-local-coverage.py). A tool whose binary/backend is absent is recorded as
# cannot-run WITH A REASON — visible, never silent.
#
# Usage:  ci-local-laneB.sh <repo_root> <cil_dir> <registry.tsv> [--sonar-cloud]
#
# Stdout: a per-tool line. Exit: 0 unless a Lane-B tool produced ERROR findings
# (the aggregator owns the actual error gate; this script only dispatches).

set -uo pipefail

repo_root="${1:?usage: ci-local-laneB.sh <repo_root> <cil_dir> <registry.tsv>}"
cil="${2:?missing cil dir}"
registry="${3:?missing registry tsv}"
sonar_backend="local"
[[ "${4:-}" == "--sonar-cloud" ]] && sonar_backend="cloud"

findings="$cil/findings"
status_file="$(mktemp -t lane-b-status.XXXXXX)"
laneb_tmp="$(mktemp -d -t lane-b.XXXXXX)"
trap 'rm -f "$status_file"; rm -rf "$laneb_tmp"' EXIT
mkdir -p "$findings"

c_dim=$'\e[2m'; c_ylw=$'\e[33m'; c_off=$'\e[0m'
info() { printf '%s[lane-b]%s %s\n' "$c_dim" "$c_off" "$*"; }
warn() { printf '%s[lane-b]%s %s\n' "$c_ylw" "$c_off" "$*" >&2; }

# Resolve a Lane-B backend directory (backends/<tool>/). When this dispatcher
# runs from a local checkout the backend is a sibling tree; when curled to a
# temp dir by run-ci-local.sh it isn't, so fetch the backend's files from the
# harness repo. Override the ref with CI_LOCAL_FINDINGS_REF.
HARNESS_REF="${CI_LOCAL_FINDINGS_REF:-main}"
HARNESS_RAW="https://raw.githubusercontent.com/FelipeFuhr/ffreis-platform-ci-local/${HARNESS_REF}"
# resolve_backend <tool> <file...> — echoes a dir holding the listed files, or rc1
resolve_backend() {
  local tool="$1"; shift
  local here repo_local
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_local="$(dirname "$here")/backends/$tool"
  local f have_all=1
  for f in "$@"; do [[ -f "$repo_local/$f" ]] || have_all=0; done
  if [[ "$have_all" == 1 ]]; then printf '%s' "$repo_local"; return 0; fi
  command -v curl >/dev/null 2>&1 || return 1
  local dest="$laneb_tmp/$tool"; mkdir -p "$dest"
  for f in "$@"; do
    curl -fsSL "${HARNESS_RAW}/backends/${tool}/${f}" -o "$dest/$f" 2>/dev/null || return 1
  done
  printf '%s' "$dest"
}

# record <tool> <status> <detail> — status ∈ ran|found|cannot-run
record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$status_file"; }

# probe_matches "<space-separated paths>" — true if any exists ("-" ⇒ always)
probe_matches() {
  local p
  for p in $1; do
    [[ "$p" == "-" ]] && return 0
    [[ -e "$repo_root/$p" ]] && return 0
  done
  return 1
}

# tool_in_ci "<egrep pattern>" — true if any workflow file references the tool.
# Gates dispatch on the SAME signal completeness uses: we only run a Lane-B tool
# locally if it's actually part of THIS repo's CI (e.g. a stray
# sonar-project.properties without a sonar workflow must not trigger a scan).
wf_dir="$repo_root/.github/workflows"
tool_in_ci() {
  [[ -d "$wf_dir" ]] || return 1
  grep -rEliq "$1" "$wf_dir" 2>/dev/null
}

# ── codeql ───────────────────────────────────────────────────────────────────
# The CodeQL CLI is rarely installed locally; the cannot-run path is the common
# one and must be loud. When present, build a DB for the detected language and
# analyze with the default security suite → findings/codeql.sarif.
detect_codeql_lang() {
  [[ -f "$repo_root/go.mod" ]] && { echo "go"; return; }
  [[ -f "$repo_root/Cargo.toml" ]] && { echo "rust"; return; }  # CLI support varies
  [[ -f "$repo_root/pyproject.toml" || -f "$repo_root/requirements.txt" ]] && { echo "python"; return; }
  ls "$repo_root"/*.js "$repo_root"/package.json >/dev/null 2>&1 && { echo "javascript"; return; }
  echo ""
}

run_codeql() {
  local reason="$1"
  if ! command -v codeql >/dev/null 2>&1; then
    record codeql cannot-run "$reason"
    warn "codeql: $reason"
    return
  fi
  local lang db out
  lang="$(detect_codeql_lang)"
  if [[ -z "$lang" ]]; then
    record codeql cannot-run "no CodeQL-supported language detected in $repo_root"
    return
  fi
  db="$cil/codeql-db"; out="$findings/codeql.sarif"
  info "codeql: building $lang database (this is slow)…"
  rm -rf "$db"
  if ! codeql database create "$db" --language="$lang" --source-root="$repo_root" \
        --overwrite >/dev/null 2>&1; then
    record codeql cannot-run "codeql database create failed for $lang (see CodeQL output)"
    return
  fi
  if codeql database analyze "$db" --format=sarif-latest --output="$out" \
        --download >/dev/null 2>&1; then
    local n
    n="$(grep -co '"ruleId"' "$out" 2>/dev/null || echo 0)"
    record codeql "$( [[ "$n" -gt 0 ]] && echo found || echo ran )" "$n result(s) → codeql.sarif"
  else
    record codeql cannot-run "codeql database analyze failed"
  fi
  rm -rf "$db"
}

# ── sonar ────────────────────────────────────────────────────────────────────
# Default backend = a centralized local SonarQube *server* container (offline,
# zero SonarCloud writes, no clobber of the server-side main analysis). The
# backend (backends/sonarqube/) is resolved from the local tree or fetched from
# the harness repo. --sonar-cloud routes to isolated SonarCloud PR analysis
# (public repos only). Either way an absent backend → cannot-run WITH a reason.
run_sonar() {
  local reason="$1"
  if [[ ! -f "$repo_root/sonar-project.properties" ]]; then
    record sonar cannot-run "no sonar-project.properties in $repo_root"
    return
  fi
  if [[ "$sonar_backend" == "cloud" ]]; then
    run_sonar_cloud
    return
  fi

  local bdir
  bdir="$(resolve_backend sonarqube backend.sh sonar-issues-to-sarif.py)" || {
    record sonar cannot-run "sonarqube backend unavailable (no local tree + fetch failed)"
    return
  }
  # shellcheck source=/dev/null
  source "$bdir/backend.sh"

  info "sonar: bringing up the local SonarQube server (first boot is slow)…"
  local token up_rc
  token="$( cd "$repo_root" && sonar_local_up )"; up_rc=$?
  if [[ "$up_rc" -ne 0 ]]; then
    record sonar cannot-run "$token"   # on failure the backend echoes the reason
    warn "sonar: $token"
    return
  fi

  info "sonar: scanning $repo_root"
  if ! sonar_local_run "$repo_root" "$token"; then
    record sonar cannot-run "scanner run failed (see SonarQube scanner output)"
    return
  fi

  local collect
  collect="$(sonar_local_collect "$repo_root" "$cil" "$token")"
  if [[ "$collect" != "ok" ]]; then
    record sonar cannot-run "$collect"
    return
  fi
  # gate verdict from the local quality gate (ERROR ⇒ a failing gate)
  local gate=""
  [[ -f "$cil/sonar-gate.json" ]] && gate="$(sed -n 's/.*"status":"\([A-Z]*\)".*/\1/p' "$cil/sonar-gate.json" | head -1)"
  local n
  n="$(grep -co '"ruleId"' "$findings/sonar.sarif" 2>/dev/null || echo 0)"
  if [[ "$gate" == "ERROR" || "$n" -gt 0 ]]; then
    record sonar found "$n issue(s); quality gate=${gate:-?} → sonar.sarif"
  else
    record sonar ran "quality gate=${gate:-OK}; no new issues"
  fi
}

# --sonar-cloud: isolated SonarCloud PR analysis (public repos). Requires
# SONAR_TOKEN + a non-main branch (so it never clobbers the main analysis).
run_sonar_cloud() {
  if [[ -z "${SONAR_TOKEN:-}" ]]; then
    record sonar cannot-run "--sonar-cloud needs SONAR_TOKEN (set it in ~/.config/ffreis/ci-local.env)"
    return
  fi
  local branch
  branch="$(cd "$repo_root" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
  if [[ "$branch" == "main" || "$branch" == "master" ]]; then
    record sonar cannot-run "--sonar-cloud refuses to analyze '$branch' (would clobber the server-side main analysis) — run from a feature branch"
    return
  fi
  info "sonar: SonarCloud branch analysis (branch=$branch, isolated from main)"
  local cmd="${CONTAINER_CMD:-podman}"
  if ! "$cmd" run --rm \
        -e SONAR_TOKEN="$SONAR_TOKEN" \
        -e SONAR_HOST_URL="https://sonarcloud.io" \
        -v "${repo_root}:/usr/src:rw" \
        docker.io/sonarsource/sonar-scanner-cli:latest \
        "-Dsonar.branch.name=$branch" >/dev/null 2>&1; then
    record sonar cannot-run "SonarCloud scanner run failed (check SONAR_TOKEN / organization in sonar-project.properties)"
    return
  fi
  record sonar ran "SonarCloud branch analysis submitted for '$branch' (view results on sonarcloud.io)"
}

# ── dispatch ─────────────────────────────────────────────────────────────────
dispatched=0
while IFS=$'\t' read -r tool lane pattern probe reason; do
  [[ -z "$tool" || "$tool" == \#* ]] && continue
  [[ "$lane" == "B" ]] || continue
  # Only run a Lane-B tool that is BOTH in this repo's CI and locally applicable.
  tool_in_ci "$pattern" || continue
  probe_matches "$probe" || continue
  dispatched=$((dispatched + 1))
  case "$tool" in
    codeql) run_codeql "$reason" ;;
    sonar)  run_sonar  "$reason" ;;
    *)      record "$tool" cannot-run "$reason (no Lane-B adapter)" ;;
  esac
done < "$registry"

# ── assemble lane-b.json (python for safe JSON; stdlib only) ──────────────────
LANE_B_JSON="$cil/lane-b.json" STATUS_FILE="$status_file" python3 - <<'PY'
import json, os, pathlib
tools = {}
sf = pathlib.Path(os.environ["STATUS_FILE"])
for line in sf.read_text().splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    if len(parts) < 3:
        continue
    tool, status, detail = parts[0], parts[1], parts[2]
    tools[tool] = {"status": status, "detail": detail}
pathlib.Path(os.environ["LANE_B_JSON"]).write_text(json.dumps({"tools": tools}, indent=2))
PY

if [[ "$dispatched" -eq 0 ]]; then
  info "no Lane-B tools applicable to this repo"
else
  info "Lane-B dispatch complete ($dispatched tool(s)) → $cil/lane-b.json"
fi
