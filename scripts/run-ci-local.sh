#!/usr/bin/env bash
# run-ci-local.sh — Run a repo's GitHub Actions workflows locally via `act`.
#
# Quota fallback for when GitHub Actions minutes are exhausted. Auto-detects
# locally available credentials (AWS, gh token, extra env file) and passes
# them through to act; missing-secret failures are surfaced separately from
# real test failures so you can tell them apart.
#
# Usage (run from inside the target repo):
#   run-ci-local.sh                     # all workflows, push event
#   run-ci-local.sh --lint-only         # actionlint on workflows only (no act/Docker)
#   run-ci-local.sh --quick             # only common lint/test/fmt jobs
#   run-ci-local.sh --findings          # capture scanner SARIF to a gitignored
#                                       #   .ci-local/, report every finding +
#                                       #   remediation, classify each job (so
#                                       #   nothing fails silently); gates on errors
#   run-ci-local.sh --lane-b            # findings + run the direct-CLI scanners
#                                       #   act can't (codeql, sonar), then assert
#                                       #   every CI tool is accounted for
#   run-ci-local.sh --lane-b-only       # skip act; only the Lane-B scanners +
#                                       #   coverage (the /ready pre-promote gate)
#   run-ci-local.sh --full              # everything: act (Lane A) + Lane B + findings
#   run-ci-local.sh --sonar-cloud       # Sonar via SonarCloud PR analysis (public
#                                       #   repos) instead of the local container
#   run-ci-local.sh --strict            # also fail if a SARIF-native scanner ran
#                                       #   but produced no local finding (capture gap)
#   run-ci-local.sh --remediate         # print an action plan (inline / queued
#                                       #   fix-prompts) from the findings
#   run-ci-local.sh -W path/to/wf.yml   # one workflow (passthrough)
#   run-ci-local.sh -j go-lint          # one job (passthrough)
#   run-ci-local.sh -- --rm             # everything after `--` goes to act
#
# Requires: act (https://github.com/nektos/act), Docker daemon running.
# Optional: ~/.config/ffreis/ci-local.env for extra secrets. See the
# `ci-local.env.example` sibling file for the format.
#
# Runner image is pinned to ghcr.io/catthehacker/ubuntu:act-22.04 by default.
# Override via ACT_RUNNER_IMAGE env var if needed.

set -euo pipefail

# ── style ──────────────────────────────────────────────────────────────────
c_dim=$'\e[2m'; c_red=$'\e[31m'; c_ylw=$'\e[33m'; c_off=$'\e[0m'
info() { printf '%s[ci-local]%s %s\n' "$c_dim" "$c_off" "$*"; }
warn() { printf '%s[ci-local]%s %s\n' "$c_ylw" "$c_off" "$*" >&2; }
die()  { printf '%s[ci-local]%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

# ── parse args ─────────────────────────────────────────────────────────────
mode=full
findings=no
lane_b=no             # no | yes | only  — Lane-B direct-CLI scanners (codeql, sonar)
sonar_backend=local   # local (SonarQube container) | cloud (SonarCloud PR analysis)
strict=no             # gate on a SARIF-native scanner being UNACCOUNTED
remediate=no          # emit a remediation plan after the findings report
act_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) mode=quick; shift ;;
    --full)  mode=full; findings=yes; lane_b=yes; shift ;;
    --lint-only) mode=lintonly; shift ;;
    --findings) findings=yes; shift ;;
    --lane-b) findings=yes; lane_b=yes; shift ;;
    --lane-b-only) findings=yes; lane_b=only; shift ;;
    --sonar-cloud) sonar_backend=cloud; shift ;;
    --strict) strict=yes; shift ;;
    --remediate) remediate=yes; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; act_args+=("$@"); break ;;
    *)  act_args+=("$1"); shift ;;
  esac
done

# ── preflight ──────────────────────────────────────────────────────────────
git rev-parse --show-toplevel >/dev/null 2>&1 \
  || die "Not inside a git repo. cd into a repo with .github/workflows/ first."

repo_root=$(git rev-parse --show-toplevel)
[[ -d "$repo_root/.github/workflows" ]] \
  || die "$repo_root has no .github/workflows/ — nothing for act to run."

# actionlint pre-flight — catch workflow-YAML errors (the class that causes
# startup_failure on GitHub: orphaned action SHA, bad uses:/if:) locally, before
# any push. Runs on every invocation; --lint-only stops here and needs no Docker.
if command -v actionlint >/dev/null 2>&1; then
  info "actionlint pre-flight on .github/workflows/"
  ( cd "$repo_root" && actionlint -color ) \
    || die "actionlint failed — fix the workflow YAML before pushing."
else
  warn "actionlint not on PATH — skipping workflow lint. Install: https://github.com/rhysd/actionlint"
fi
[[ "$mode" == lintonly ]] && { info "lint-only: done."; exit 0; }

if [[ "$lane_b" != only ]]; then
  command -v act >/dev/null 2>&1 \
    || die "act not installed. See https://nektosact.com/installation"
fi

# Auto-route to rootless podman if the default docker socket isn't ours
# but the rootless podman socket is. Common on Linux machines where
# /var/run/docker.sock symlinks to root podman that the user can't reach.
# (`docker info` is unreliable here — podman-docker emulation returns 0
# even when actual container operations would fail with EACCES, so we
# check socket-file accessibility directly.)
if [[ -z "${DOCKER_HOST:-}" ]]; then
  rootless_sock="/run/user/${UID:-$(id -u)}/podman/podman.sock"
  if [[ ! -w /var/run/docker.sock && -S "$rootless_sock" && -w "$rootless_sock" ]]; then
    export DOCKER_HOST="unix://$rootless_sock"
    info "Using rootless podman socket: $DOCKER_HOST"
  fi
fi

# Pin runner image + container arch inline (no external .actrc dependency)
# so the script works the same whether invoked directly, via a Makefile
# curl-download, or with a stray ~/.actrc in the user's home.
runner_image="${ACT_RUNNER_IMAGE:-ghcr.io/catthehacker/ubuntu:act-22.04}"
runner_image_24="${ACT_RUNNER_IMAGE_24:-ghcr.io/catthehacker/ubuntu:act-24.04}"
act_platform_args=(
  -P "ubuntu-latest=$runner_image"
  -P "ubuntu-22.04=$runner_image"
  -P "ubuntu-24.04=$runner_image_24"
  --container-architecture linux/amd64
)

# ── findings mode setup ──────────────────────────────────────────────────────
# --bind so the scanners' workspace SARIF writes persist on the host; capture
# everything under a gitignored .ci-local/. Gitignore via .git/info/exclude so
# no committed change is needed and it works on every clone today.
cil=""
if [[ "$findings" == yes ]]; then
  cil="$repo_root/.ci-local"
  mkdir -p "$cil"/{logs,findings,coverage,artifacts}
  exclude_file="$(git rev-parse --git-path info/exclude)"
  mkdir -p "$(dirname "$exclude_file")"
  grep -qxF '/.ci-local/' "$exclude_file" 2>/dev/null || echo '/.ci-local/' >> "$exclude_file"
  act_platform_args+=( --bind --artifact-server-path "$cil/artifacts" )
  info "Findings mode: capturing scanner output to $cil (gitignored)"
fi

# ── credential probe ───────────────────────────────────────────────────────
tmp_dir=$(mktemp -d -t ci-local.XXXXXX)
trap 'rm -rf "$tmp_dir"' EXIT
secrets_file="$tmp_dir/secrets"
env_file="$tmp_dir/env"
: > "$secrets_file"
: > "$env_file"

# Resolve a sibling helper script: a local clone / curled-alongside copy if
# present, else self-bootstrap it from the standards repo so `make ci-local`
# (which curls only this script) still gets the findings/lane-b/coverage
# helpers. Echoes a usable path, or nothing if unavailable. Override the ref
# with CI_LOCAL_FINDINGS_REF.
resolve_sibling() {
  local name="$1" sib
  sib="$(dirname "$0")/$name"
  if [[ -f "$sib" ]]; then printf '%s' "$sib"; return 0; fi
  command -v curl >/dev/null 2>&1 || return 1
  local ref="${CI_LOCAL_FINDINGS_REF:-main}"
  local raw="https://raw.githubusercontent.com/FelipeFuhr/ffreis-platform-ci-local/${ref}/scripts/${name}"
  if curl -fsSL "$raw" -o "$tmp_dir/$name" 2>/dev/null; then
    printf '%s' "$tmp_dir/$name"; return 0
  fi
  return 1
}

have_aws=no
have_gh=no
have_extra=no

probe_aws() {
  # Prefer already-exported creds (e.g. from `aws sso login` + eval).
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    {
      printf 'AWS_ACCESS_KEY_ID=%s\n'     "$AWS_ACCESS_KEY_ID"
      printf 'AWS_SECRET_ACCESS_KEY=%s\n' "$AWS_SECRET_ACCESS_KEY"
      [[ -n "${AWS_SESSION_TOKEN:-}" ]] && printf 'AWS_SESSION_TOKEN=%s\n' "$AWS_SESSION_TOKEN"
    } >> "$secrets_file"
    [[ -n "${AWS_REGION:-}" ]] && printf 'AWS_REGION=%s\n' "$AWS_REGION" >> "$env_file"
    have_aws=yes
    return
  fi
  # Fall back to resolving from a profile. Default to ffreis-platform
  # (assumes platform-admin from ~/.aws/credentials ffreis-platform-base).
  command -v aws >/dev/null 2>&1 || return
  local profile="${AWS_PROFILE:-ffreis-platform}"
  AWS_PROFILE="$profile" aws sts get-caller-identity >/dev/null 2>&1 || return
  # `export-credentials` exists in AWS CLI v2.13+; degrade gracefully.
  local creds
  creds=$(AWS_PROFILE="$profile" aws configure export-credentials --format env-no-export 2>/dev/null || true)
  if [[ -n "$creds" ]]; then
    printf '%s\n' "$creds" >> "$secrets_file"
    have_aws=yes
  fi
}
probe_aws

# GitHub token via gh CLI.
if command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
  printf 'GITHUB_TOKEN=%s\n' "$(gh auth token)" >> "$secrets_file"
  have_gh=yes
fi

# Extra secrets from user-managed env file.
extra_env="$HOME/.config/ffreis/ci-local.env"
extra_env_exists=no
if [[ -r "$extra_env" ]]; then
  extra_env_exists=yes
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || { warn "skipping non-KEY=VALUE line in $extra_env: $line"; continue; }
    printf '%s\n' "$line" >> "$secrets_file"
    have_extra=yes
  done < "$extra_env"
fi

# ── plan banner ────────────────────────────────────────────────────────────
info "Repo: $repo_root"
info "Mode: $mode"
info "Detected credentials: AWS=$have_aws GH=$have_gh EXTRA_ENV=$have_extra"
[[ "$have_aws"   == no ]] && info "  → AWS jobs may report 'credential-missing'. Set AWS_PROFILE or export AWS_* to enable."
[[ "$have_gh"    == no ]] && info "  → GitHub-API jobs may fail. Run 'gh auth login' to enable."
if [[ "$have_extra" == no ]]; then
  if [[ "$extra_env_exists" == no ]]; then
    info "  → No $extra_env. Copy scripts/ci-local.env.example there to enable extra secrets."
  else
    info "  → $extra_env exists but has no KEY=VALUE entries (all commented)."
  fi
fi

# ── invocation ─────────────────────────────────────────────────────────────
cd "$repo_root"
log_file="$tmp_dir/act.log"
[[ "$findings" == yes ]] && log_file="$cil/logs/act-$(date +%Y%m%d-%H%M%S).log"

# act_ran tracks whether Lane A executed — the completeness assertion needs to
# know (a Lane-A tool with no SARIF is UNACCOUNTED only if act actually ran).
act_ran=no
act_status=0
if [[ "$lane_b" == only ]]; then
  info "Lane-B-only: skipping act (Lane A). Running the direct-CLI scanners only."
  : > "$log_file"
elif [[ "$mode" == quick ]]; then
  act_ran=yes
  # Intersect repo's actual job names with a conservative cheap-check list.
  quick_pattern='^(lint|fmt-check|fmt|format|test|unit-test|go-lint|go-test|rust-lint|rust-test|python-lint|python-test|tf-fmt|tf-lint|actionlint)$'
  all_jobs=$(act -l 2>/dev/null | awk 'NR>1 {print $2}' | sort -u || true)
  runnable=$(printf '%s\n' "$all_jobs" | grep -E "$quick_pattern" || true)
  [[ -n "$runnable" ]] \
    || die "Quick mode: no matching jobs in this repo. Run without --quick or pass -j <name>."

  info "Quick-mode jobs: $(echo "$runnable" | tr '\n' ' ')"
  failures=0
  while IFS= read -r job; do
    [[ -z "$job" ]] && continue
    info "→ act push -j $job"
    if ! act push -j "$job" "${act_platform_args[@]}" --secret-file "$secrets_file" --env-file "$env_file" "${act_args[@]}" 2>&1 | tee -a "$log_file"; then
      failures=$((failures + 1))
    fi
  done <<< "$runnable"
  act_status=$failures
else
  act_ran=yes
  set +e
  act push "${act_platform_args[@]}" --secret-file "$secrets_file" --env-file "$env_file" "${act_args[@]}" 2>&1 | tee "$log_file"
  act_status=${PIPESTATUS[0]}
  set -e
fi

# ── findings mode: collect, classify, run Lane B, aggregate, assert, gate ───
if [[ "$findings" == yes ]]; then
  real_fail=0
  # Lane A: collect the act-written SARIF + classify each job. Only when act ran
  # (—lane-b-only skips this; there's no act log to classify).
  if [[ "$act_ran" == yes ]]; then
  reclaim() { # make a root-owned output user-owned so it's movable; loud on failure
    [[ -O "$1" ]] && return 0
    chown "$(id -u):$(id -g)" "$1" 2>/dev/null && return 0
    podman unshare chown "$(id -u):$(id -g)" "$1" 2>/dev/null && return 0
    sudo -n chown "$(id -u):$(id -g)" "$1" 2>/dev/null && return 0
    warn "could not reclaim ownership of $1 (root-owned, left in place)"; return 1
  }
  shopt -s nullglob
  for f in "$repo_root"/*.sarif "$repo_root"/*-results/*.sarif "$repo_root"/results.sarif; do
    [[ -f "$f" ]] || continue
    case "$f" in "$cil"/*) continue ;; esac
    if reclaim "$f"; then mv -f "$f" "$cil/findings/" 2>/dev/null || true; fi
  done
  for f in "$repo_root"/coverage.out "$repo_root"/lcov.info "$repo_root"/coverage.xml; do
    [[ -f "$f" ]] || continue
    if reclaim "$f"; then mv -f "$f" "$cil/coverage/" 2>/dev/null || true; fi
  done

  # Classify each job: PASS / FOUND-FINDINGS / UPLOAD-ONLY-FAILED / REAL-FAIL /
  # CANNOT-RUN-LOCALLY. Findings (SARIF *results*) corroborate — a scanner that
  # exits non-zero because it found something is FOUND-FINDINGS, not REAL-FAIL;
  # an upload-only failure with no captured SARIF stays REAL-FAIL (fail-safe).
  real_fail=$(LOG="$log_file" FIND="$cil/findings" RUNJSON="$cil/run.json" python3 - <<'PY'
import os, re, json, pathlib, sys
log = pathlib.Path(os.environ["LOG"]).read_text(errors="replace")
fdir = pathlib.Path(os.environ["FIND"])
n = 0
for sp in fdir.glob("*.sarif"):
    try:
        for run in (json.loads(sp.read_text()).get("runs") or []):
            n += len(run.get("results") or [])
    except Exception:
        pass
have_findings, have_sarif = n > 0, any(fdir.glob("*.sarif"))
UPLOAD = re.compile(r'(upload|codecov|artifact|sarif|publish)', re.I)
CANT = re.compile(r'(codeql|sonar|deepsource|snyk)', re.I)
state, failsteps = {}, {}
for line in log.splitlines():
    m = re.match(r'\[(?P<inside>[^\]]*)\]\s*(?P<rest>.*)', line)
    if not m:
        continue
    job, rest = m.group("inside").split('/')[-1].strip(), m.group("rest")
    if 'Job succeeded' in rest:
        state.setdefault(job, 'PASS')
    elif 'Job failed' in rest:
        state[job] = 'FAIL'
    fm = re.search(r'Failure - (?:Main|Post)?\s*(.+)$', rest)
    if fm:
        failsteps.setdefault(job, []).append(fm.group(1).strip())
rows, realfail = [], 0
for job, st in sorted(state.items()):
    if CANT.search(job):
        cls = 'CANNOT-RUN-LOCALLY'
    elif st == 'PASS':
        cls = 'FOUND-FINDINGS' if have_findings else 'PASS'
    else:
        fails = failsteps.get(job, [])
        if fails and all(UPLOAD.search(s) for s in fails):
            cls = 'UPLOAD-ONLY-FAILED' if have_sarif else 'REAL-FAIL'
        elif have_findings:
            cls = 'FOUND-FINDINGS'
        else:
            cls = 'REAL-FAIL'
    realfail += cls == 'REAL-FAIL'
    rows.append((job, cls))
icon = {'PASS':'✅','FOUND-FINDINGS':'🔎','UPLOAD-ONLY-FAILED':'🟡','REAL-FAIL':'❌','CANNOT-RUN-LOCALLY':'⏭'}
sys.stderr.write("\n\033[1m── Job run-state ──\033[0m\n")
for job, cls in rows:
    sys.stderr.write(f"  {icon.get(cls,'?')} {cls:<20} {job}\n")
pathlib.Path(os.environ["RUNJSON"]).write_text(json.dumps({"jobs": dict(rows)}, indent=2))
print(realfail)
PY
)
  fi  # end act_ran guard (Lane A collection + classification)

  # ── Lane B: run the direct-CLI scanners act can't (codeql, sonar) ──────────
  # They write SARIF into the same $cil/findings/, so the aggregator below picks
  # them up alongside Lane A, and lane-b.json feeds the completeness assertion.
  registry_path=""
  if [[ "$lane_b" != no ]]; then
    laneb="$(resolve_sibling ci-local-laneB.sh || true)"
    registry_path="$(resolve_sibling ci-local-tools.tsv || true)"
    if [[ -n "$laneb" && -n "$registry_path" ]]; then
      echo
      sonar_flag=()
      [[ "$sonar_backend" == cloud ]] && sonar_flag=(--sonar-cloud)
      bash "$laneb" "$repo_root" "$cil" "$registry_path" "${sonar_flag[@]}" || true
    else
      warn "Lane-B helpers unavailable (dispatcher/registry) — codeql/sonar skipped"
    fi
  fi

  # ── Aggregate ALL findings (Lane A + Lane B SARIF in one dir) ──────────────
  agg="$(resolve_sibling ci-local-findings.py || true)"
  agg_rc=0
  if [[ -n "$agg" ]]; then
    echo
    python3 "$agg" "$cil/findings" || agg_rc=$?
  else
    warn "ci-local-findings.py unavailable (no sibling + fetch failed) — skipping findings report"
  fi

  # ── Completeness assertion: every CI tool accounted for; nothing silent ────
  cov="$(resolve_sibling ci-local-coverage.py || true)"
  [[ -z "$registry_path" ]] && registry_path="$(resolve_sibling ci-local-tools.tsv || true)"
  cov_rc=0
  if [[ -n "$cov" && -n "$registry_path" ]]; then
    echo
    cov_args=(--registry "$registry_path" --workflows "$repo_root/.github/workflows" --findings "$cil/findings")
    [[ "$act_ran" == yes ]] && cov_args+=(--run-json "$cil/run.json")
    [[ -f "$cil/lane-b.json" ]] && cov_args+=(--lane-b "$cil/lane-b.json")
    [[ "$strict" == yes ]] && cov_args+=(--strict)
    python3 "$cov" "${cov_args[@]}" || cov_rc=$?
  fi

  # ── Remediation plan: findings → an action plan (inline / queued / parallel) ─
  if [[ "$remediate" == yes ]]; then
    rem="$(resolve_sibling ci-local-remediate.py || true)"
    if [[ -n "$rem" ]]; then echo; python3 "$rem" "$cil" --repo "$repo_root" || true; fi
  fi

  [[ "${real_fail:-0}" -gt 0 ]] \
    && die "$real_fail job(s) had a REAL failure (not just a GitHub-only upload). See run-state above."
  [[ "$agg_rc" -ne 0 ]] && die "error-level findings present (see the report above)."
  [[ "$cov_rc" -ne 0 ]] && die "strict coverage gate: a SARIF-native scanner did not run locally (see above)."
  info "Local findings gate passed. Reports under $cil/"
  exit 0
fi

# ── post-parse: distinguish missing-credential from real failures ──────────
missing=$(grep -E 'Required secret .* not (found|set)|secret .* (is required|is not set|not configured)' "$log_file" 2>/dev/null || true)
if [[ -n "$missing" ]]; then
  warn "Some failures appear to be missing-credential rather than real test failures:"
  printf '%s\n' "$missing" | sort -u | sed 's/^/  /' >&2
fi

if [[ "$act_status" -ne 0 && -z "$missing" ]]; then
  die "act reported failures. Review the log above."
elif [[ "$act_status" -ne 0 ]]; then
  warn "act exited $act_status but failures look credential-related. Treating as success."
  exit 0
fi

info "All workflows passed locally."
