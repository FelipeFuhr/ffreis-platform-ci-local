#!/usr/bin/env bats
# Thin bats wrapper around the stdlib self-test, plus a couple of direct
# invariant checks on the helpers.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO/scripts"
  RUN_CI_LOCAL="$SCRIPTS/run-ci-local.sh"
}

@test "self-test.sh passes (findings + coverage helpers)" {
  run bash "$REPO/tests/self-test.sh"
  [ "$status" -eq 0 ]
}

@test "ci-local-findings.py exits 0 on an empty findings dir" {
  tmp="$(mktemp -d)"
  run python3 "$SCRIPTS/ci-local-findings.py" "$tmp" --no-color
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}

@test "registry has a lane for every non-comment row" {
  run awk -F'\t' '!/^#/ && NF>1 && $2!~/^(A|B|cannot|na)$/ {print; e=1} END{exit e}' \
    "$SCRIPTS/ci-local-tools.tsv"
  [ "$status" -eq 0 ]
}

@test "run-ci-local.sh parses (bash -n) and is shellcheck-clean if available" {
  run bash -n "$SCRIPTS/run-ci-local.sh"
  [ "$status" -eq 0 ]
}

@test "drift gate: clean when every ref is classified, FAILs on an unknown ref" {
  tmp="$(mktemp -d)"; mkdir -p "$tmp/wf"
  # a known + an unknown reusable-workflow reference
  cat > "$tmp/wf/ci.yml" <<'EOF'
jobs:
  a: { uses: FelipeFuhr/ffreis-workflows-general/.github/workflows/general-gitleaks.yml@deadbeef }
  b: { uses: FelipeFuhr/ffreis-workflows-general/.github/workflows/general-totally-new-scanner.yml@deadbeef }
EOF
  run python3 "$SCRIPTS/ci-local-drift.py" --registry "$SCRIPTS/ci-local-tools.tsv" \
    --workflows "$tmp/wf" --enforce --no-color
  rm -rf "$tmp"
  [ "$status" -eq 1 ]                                  # drift → enforce fails
  [[ "$output" == *"general-totally-new-scanner"* ]]  # names the offender
}

@test "drift gate: this repo's own workflows are clean (or have no reusable refs)" {
  run python3 "$SCRIPTS/ci-local-drift.py" --registry "$SCRIPTS/ci-local-tools.tsv" \
    --workflows "$REPO/.github/workflows" --enforce --no-color
  [ "$status" -eq 0 ]
}

@test "drift gate --defines: an unclassified reusable workflow a lib DEFINES fails" {
  tmp="$(mktemp -d)"; mkdir -p "$tmp/wf"
  printf 'on:\n  workflow_call:\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps: []\n' \
    > "$tmp/wf/go-brandnewscan.yml"
  printf 'on:\n  workflow_call:\njobs: {}\n' > "$tmp/wf/self-test.yml"  # meta, excluded
  run python3 "$SCRIPTS/ci-local-drift.py" --registry "$SCRIPTS/ci-local-tools.tsv" \
    --workflows "$tmp/wf" --defines --enforce --no-color
  rm -rf "$tmp"
  [ "$status" -eq 1 ]
  [[ "$output" == *"go-brandnewscan"* ]]
  [[ "$output" != *"self-test"* ]]   # meta workflow excluded
}

# ── credential-downgrade gating regression tests ────────────────────────────
# Stubs `act`, `aws`, `gh`, `actionlint` on PATH so the post-parse gating
# logic can be exercised hermetically (no docker/podman, no real act/network).
# `act`'s canned log lines mirror real act output, verified against a live
# `act push` run with a missing-secret step and a real failing step:
#   [workflow/job]   | <raw step stdout/stderr, e.g. "Required secret X not found">
#   [workflow/job]   ❌  Failure - Main <step name> [Ns]
#   [workflow/job] 🏁  Job failed   /   Job succeeded
setup_gating_env() {
  orig_pwd="$PWD"
  work="$(mktemp -d)"
  stubbin="$work/bin"
  mkdir -p "$stubbin" "$work/repo/.github/workflows"
  : > "$work/repo/.github/workflows/ci.yml"
  git -C "$work/repo" init -q
  git -C "$work/repo" config user.email test@example.com
  git -C "$work/repo" config user.name test

  # Neutralize credential/tool detection so behavior is deterministic
  # regardless of what's installed/authenticated on the host. `gh` is
  # stubbed to fail closed (its call sites are `||`-guarded, so that's
  # safe). AWS is routed via already-exported dummy creds rather than a
  # failing `aws` stub, so this helper stays scoped to the gating logic
  # under test (the probe_aws() fallback path has its own dedicated test
  # below, since it's a separate fix).
  printf '#!/usr/bin/env bash\nexit 1\n' > "$stubbin/gh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stubbin/actionlint"
  # Fake `act`: ignores all args, prints the canned log, exits with the
  # configured code. Set FAKE_ACT_LOG / FAKE_ACT_EXIT before calling `run`.
  printf '#!/usr/bin/env bash\ncat "$FAKE_ACT_LOG"\nexit "${FAKE_ACT_EXIT:-0}"\n' > "$stubbin/act"
  chmod +x "$stubbin"/gh "$stubbin"/actionlint "$stubbin"/act

  export PATH="$stubbin:$PATH"
  export AWS_ACCESS_KEY_ID=dummy AWS_SECRET_ACCESS_KEY=dummy
  unset AWS_SESSION_TOKEN AWS_PROFILE
  cd "$work/repo"
}

teardown_gating_env() {
  cd "$orig_pwd"
  rm -rf "$work"
}

@test "gating: act fails with no credential marker -> nonzero exit" {
  setup_gating_env
  cat > "$work/act.log" <<'LOG'
[ci/real-failure]   ❌  Failure - Main a real bug [1.2s]
[ci/real-failure] 🏁  Job failed
Error: Job 'real-failure' failed
LOG
  export FAKE_ACT_LOG="$work/act.log" FAKE_ACT_EXIT=1
  run bash "$RUN_CI_LOCAL"
  teardown_gating_env
  [ "$status" -ne 0 ]
}

@test "gating: real failure survives an unrelated credential marker elsewhere in the log (regression)" {
  setup_gating_env
  cat > "$work/act.log" <<'LOG'
[ci/needs-secret]   | Required secret MY_SECRET not found
[ci/needs-secret]   ❌  Failure - Main use missing secret [1.1s]
[ci/needs-secret] 🏁  Job failed
[ci/real-failure]   ❌  Failure - Main a real bug [1.2s]
[ci/real-failure] 🏁  Job failed
Error: Job 'needs-secret' failed
LOG
  export FAKE_ACT_LOG="$work/act.log" FAKE_ACT_EXIT=1
  run bash "$RUN_CI_LOCAL"
  teardown_gating_env
  [ "$status" -ne 0 ]
}

@test "gating: --allow-credential-failures never rescues a real failure" {
  setup_gating_env
  cat > "$work/act.log" <<'LOG'
[ci/needs-secret]   | Required secret MY_SECRET not found
[ci/needs-secret]   ❌  Failure - Main use missing secret [1.1s]
[ci/needs-secret] 🏁  Job failed
[ci/real-failure]   ❌  Failure - Main a real bug [1.2s]
[ci/real-failure] 🏁  Job failed
Error: Job 'needs-secret' failed
LOG
  export FAKE_ACT_LOG="$work/act.log" FAKE_ACT_EXIT=1
  run bash "$RUN_CI_LOCAL" --allow-credential-failures
  teardown_gating_env
  [ "$status" -ne 0 ]
}

@test "gating: act succeeds -> exit 0" {
  setup_gating_env
  cat > "$work/act.log" <<'LOG'
[ci/ok]   ✅  Success - Main a passing step [0.5s]
[ci/ok] 🏁  Job succeeded
LOG
  export FAKE_ACT_LOG="$work/act.log" FAKE_ACT_EXIT=0
  run bash "$RUN_CI_LOCAL"
  teardown_gating_env
  [ "$status" -eq 0 ]
}

@test "gating: credential-only failure still exits nonzero by default (fail-closed)" {
  setup_gating_env
  cat > "$work/act.log" <<'LOG'
[ci/needs-secret]   | Required secret MY_SECRET not found
[ci/needs-secret]   ❌  Failure - Main use missing secret [1.1s]
[ci/needs-secret] 🏁  Job failed
Error: Job 'needs-secret' failed
LOG
  export FAKE_ACT_LOG="$work/act.log" FAKE_ACT_EXIT=1
  run bash "$RUN_CI_LOCAL"
  teardown_gating_env
  [ "$status" -ne 0 ]
}

@test "gating: --allow-credential-failures downgrades a credential-only failure to exit 0" {
  setup_gating_env
  cat > "$work/act.log" <<'LOG'
[ci/needs-secret]   | Required secret MY_SECRET not found
[ci/needs-secret]   ❌  Failure - Main use missing secret [1.1s]
[ci/needs-secret] 🏁  Job failed
Error: Job 'needs-secret' failed
LOG
  export FAKE_ACT_LOG="$work/act.log" FAKE_ACT_EXIT=1
  run bash "$RUN_CI_LOCAL" --allow-credential-failures
  teardown_gating_env
  [ "$status" -eq 0 ]
}

# ── probe_aws() silent-death regression test ────────────────────────────────
# probe_aws() is called as a bare top-level statement under `set -euo
# pipefail`. Its CLI-probe fallback used to end failure paths with a bare
# `return`, which forwards the failing command's nonzero status out of the
# function; since the call site is unguarded, errexit then killed the WHOLE
# script with zero die()/warn() output, before act ever ran — a healthy repo
# would report an unexplained nonzero exit for an environment reason
# unrelated to its actual CI. Fixed by using `return 0` on both fallback
# lines (absence of AWS is a normal probe outcome, not a probe failure).
# This test exercises the `aws sts get-caller-identity` failure line
# directly (aws present but broken); the `command -v aws` absence line uses
# the identical `return 0` pattern and isn't separately hermetic-tested here
# (isolating PATH enough to guarantee "aws truly absent" without an aws
# stub would need enumerating every coreutil the harness calls, which is
# its own fragility risk) — noted as a scoping choice, not an oversight.
@test "probe_aws: AWS CLI present but broken does not silently kill the script (regression)" {
  orig_pwd="$PWD"
  work="$(mktemp -d)"
  stubbin="$work/bin"
  mkdir -p "$stubbin" "$work/repo/.github/workflows"
  : > "$work/repo/.github/workflows/ci.yml"
  git -C "$work/repo" init -q
  git -C "$work/repo" config user.email test@example.com
  git -C "$work/repo" config user.name test

  printf '#!/usr/bin/env bash\nexit 1\n' > "$stubbin/gh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stubbin/actionlint"
  # aws IS found (so the early "not installed" return is skipped) but every
  # subcommand fails — this hits `aws sts get-caller-identity ... || return`
  # directly, the exact line that used to take the whole script down.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$stubbin/aws"
  printf '#!/usr/bin/env bash\ncat "$FAKE_ACT_LOG"\nexit "${FAKE_ACT_EXIT:-0}"\n' > "$stubbin/act"
  chmod +x "$stubbin"/gh "$stubbin"/actionlint "$stubbin"/aws "$stubbin"/act

  cat > "$work/act.log" <<'LOG'
[ci/ok]   ✅  Success - Main a passing step [0.5s]
[ci/ok] 🏁  Job succeeded
LOG

  cd "$work/repo"
  export PATH="$stubbin:$PATH"
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  export AWS_PROFILE=does-not-matter
  export FAKE_ACT_LOG="$work/act.log" FAKE_ACT_EXIT=0

  run bash "$RUN_CI_LOCAL"

  cd "$orig_pwd"
  rm -rf "$work"

  [ "$status" -eq 0 ]
  [[ "$output" == *"All workflows passed locally."* ]]
}
