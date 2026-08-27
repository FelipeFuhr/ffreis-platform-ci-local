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

@test "act caches use the cache tier and honour explicit per-path overrides" {
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  bin="$tmp/bin"
  calls="$tmp/act.calls"
  mkdir -p "$repo/.github/workflows" "$bin" "$tmp/home/.cache-tier"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name test
  printf 'name: test\non: push\njobs: {}\n' > "$repo/.github/workflows/test.yml"
  git -C "$repo" add .github/workflows/test.yml
  git -C "$repo" commit -qm fixture

  cat > "$bin/act" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-l" ]]; then
  printf 'Stage Job ID Job name Workflow name Workflow file Events\n'
  printf '0 lint lint test test.yml push\n'
  exit 0
fi
printf '%s\n' "$*" >> "$ACT_CALLS"
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/actionlint"
  # Exercise the optional-credential path: an expired/missing AWS profile
  # must not abort the harness before it invokes act.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$bin/aws"
  chmod +x "$bin/act" "$bin/actionlint" "$bin/aws"

  run env HOME="$tmp/home" PATH="$bin:$PATH" ACT_CALLS="$calls" \
    bash "$SCRIPTS/run-ci-local.sh" --quick
  [ "$status" -eq 0 ]
  run grep -F -- "--action-cache-path $tmp/home/.cache-tier/act" "$calls"
  [ "$status" -eq 0 ]
  run grep -F -- "--cache-server-path $tmp/home/.cache-tier/actcache" "$calls"
  [ "$status" -eq 0 ]

  : > "$calls"
  run env HOME="$tmp/home" PATH="$bin:$PATH" ACT_CALLS="$calls" \
    CI_LOCAL_CACHE_DIR="$tmp/cache-root" \
    bash "$SCRIPTS/run-ci-local.sh" --quick
  [ "$status" -eq 0 ]
  run grep -F -- "--action-cache-path $tmp/cache-root/act" "$calls"
  [ "$status" -eq 0 ]
  run grep -F -- "--cache-server-path $tmp/cache-root/actcache" "$calls"
  [ "$status" -eq 0 ]

  : > "$calls"
  run env HOME="$tmp/home" PATH="$bin:$PATH" ACT_CALLS="$calls" \
    CI_LOCAL_ACT_ACTION_CACHE_PATH="$tmp/actions" \
    CI_LOCAL_ACT_CACHE_SERVER_PATH="$tmp/server" \
    bash "$SCRIPTS/run-ci-local.sh" --quick
  [ "$status" -eq 0 ]
  run grep -F -- "--action-cache-path $tmp/actions" "$calls"
  [ "$status" -eq 0 ]
  run grep -F -- "--cache-server-path $tmp/server" "$calls"
  [ "$status" -eq 0 ]
  rm -rf "$tmp"
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
