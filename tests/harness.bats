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
