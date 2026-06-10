#!/usr/bin/env bats
# Thin bats wrapper around the stdlib self-test, plus a couple of direct
# invariant checks on the helpers.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO/scripts"
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
