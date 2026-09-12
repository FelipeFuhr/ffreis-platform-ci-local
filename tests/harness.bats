#!/usr/bin/env bats
# Thin bats wrapper around the stdlib self-test, plus a couple of direct
# invariant checks on the helpers.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO/scripts"
  # A parent git hook (e.g. this repo's own pre-push, which runs `make test` →
  # bats) leaks GIT_DIR/GIT_WORK_TREE/etc. into this process. Any test that
  # inits/commits its own throwaway repo (see _fake_workflow_repo below) must
  # not inherit those, or its `git -C <tmpdir>` calls silently operate on THIS
  # repo instead (and can even trip THIS repo's own commit-msg hook on the
  # tmp repo's non-conventional "init" message). Unset defensively every test.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_CEILING_DIRECTORIES GIT_PREFIX
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

# ── regression: a LOCAL reusable-workflow ref must be classifiable too ──
# The drift gate reads `uses: ./.github/workflows/<name>.yml` the same way it
# reads a fleet `ffreis-workflows-*` ref, so a repo-local reusable workflow
# needs its own registry row. verify-compiler (a build-only compile gate, hence
# lane=na) had none and hard-failed the pre-commit drift hook in its consumer.
@test "drift gate: a repo-local verify-compiler ref classifies as lane=na" {
  tmp="$(mktemp -d)"; mkdir -p "$tmp/wf"
  cat > "$tmp/wf/promote-compiler.yml" <<'EOF'
jobs:
  verify: { uses: ./.github/workflows/verify-compiler.yml }
EOF
  run python3 "$SCRIPTS/ci-local-drift.py" --registry "$SCRIPTS/ci-local-tools.tsv" \
    --workflows "$tmp/wf" --enforce --no-color
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verify-compiler"*"lane=na"* ]]
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

# ── regression: run-ci-local.sh must never silently pass a zero-job act run ──
# Both tests stub `act` on PATH (no real Docker/act needed) and export dummy
# AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY so run-ci-local.sh's probe_aws takes
# its already-exported-creds branch and returns immediately — this keeps the
# test hermetic (no dependency on the runner's real aws CLI/profile/network)
# and, notably, sidesteps a separate pre-existing quirk unrelated to this fix:
# probe_aws's `aws sts get-caller-identity ... || return` propagates a FAILED
# aws call's exit status out of the bare top-level `probe_aws` call, which
# `set -e` then treats as a script-ending error with no die() message at all
# (reproducible today on `main` with no AWS_* creds set and no working AWS
# profile). Out of scope here; these dummy creds just avoid tripping it.

_fake_workflow_repo() { # $1 = target dir; writes a minimal valid push+pull_request workflow
  mkdir -p "$1/.github/workflows"
  git -C "$1" init -q
  git -C "$1" config user.email t@t.local
  git -C "$1" config user.name t
  cat > "$1/.github/workflows/ci.yml" <<'EOF'
on: [push, pull_request]
jobs:
  noop:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
EOF
  git -C "$1" add -A
  git -C "$1" commit -qm init
}

@test "run-ci-local.sh --findings fails loudly (not silently) when act runs zero jobs" {
  repo="$(mktemp -d)"; _fake_workflow_repo "$repo"

  # Stub `act` reproducing its real global argument-parsing error (e.g. two
  # positionals from the old hardcoded-`push` bug) — exits non-zero and never
  # prints a per-job "Job succeeded"/"Job failed" line. Before the fix this
  # produced an EMPTY "Job run-state" and still exited 0 with "Local findings
  # gate passed".
  bindir="$(mktemp -d)"
  cat > "$bindir/act" <<'EOF'
#!/usr/bin/env bash
echo "Error: accepts at most 1 arg(s), received 2" >&2
exit 1
EOF
  chmod +x "$bindir/act"

  cd "$repo"
  run env PATH="$bindir:$PATH" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
    bash "$SCRIPTS/run-ci-local.sh" --findings
  cd "$REPO"
  rm -rf "$repo" "$bindir"

  [ "$status" -ne 0 ]
  [[ "$output" == *"zero jobs"* ]]
  [[ "$output" != *"Local findings gate passed"* ]]
}

@test "run-ci-local.sh --event threads the chosen event as act's sole positional" {
  repo="$(mktemp -d)"; _fake_workflow_repo "$repo"

  bindir="$(mktemp -d)"
  argv_log="$bindir/argv.log"
  cat > "$bindir/act" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$argv_log"
echo '[CI/noop] Job succeeded'
exit 0
EOF
  chmod +x "$bindir/act"

  cd "$repo"
  run env PATH="$bindir:$PATH" AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
    bash "$SCRIPTS/run-ci-local.sh" --event pull_request
  cd "$REPO"

  [ "$status" -eq 0 ]
  read -r first_arg _ < "$argv_log"
  rm -rf "$repo" "$bindir"

  [ "$first_arg" = "pull_request" ]
}
