# AGENTS.md — ffreis-platform-ci-local

The fleet's local-CI harness. Read this before editing.

## What this repo is

A relocation + expansion of the `run-ci-local.sh` harness that used to live in
`ffreis-platform-standards/scripts/` (merged there as #48/#50, v1.4.0). It now
owns the full local-CI story: both lanes, the tool registry, the Lane-B
backends, and the drift guarantee.

## Non-obvious constraints

1. **`resolve_sibling` is the distribution contract.** `run-ci-local.sh` finds
   its helpers (`ci-local-findings.py`, `ci-local-laneB.sh`, `ci-local-coverage.py`,
   `ci-local-tools.tsv`) as siblings in the same dir, else `curl`s them from
   `raw.githubusercontent.com/FelipeFuhr/ffreis-platform-ci-local/<ref>/scripts/<name>`.
   **All four helpers must stay in `scripts/` next to `run-ci-local.sh`** (not a
   subdir) or the curl path breaks. Override the ref with `CI_LOCAL_FINDINGS_REF`.

2. **The registry (`scripts/ci-local-tools.tsv`) is the single source of truth.**
   Tab-separated: `tool · lane · workflow_pattern · probe · reason`. `lane ∈
   {A, B, cannot}` (and `na` once Phase E lands). `workflow_pattern` matches the
   **reusable-workflow filename / action ref** — bare tool names don't appear in
   callers (the fleet calls `ffreis-workflows-*/…@SHA`). Keep it in sync with the
   actual reusable-workflow catalog; the drift gate enforces this.

3. **Lane assignment rule.** A tool act faithfully runs (SARIF-emitting CLI) →
   `A`. A tool act can't run (needs a server/DB/GitHub API) → `B` with an adapter
   in `ci-local-laneB.sh`, or `cannot` with a reason. **Never** add a CI tool
   without a registry row — that's exactly the drift this repo prevents.

4. **Lane-B dispatch is gated on BOTH** "in this repo's CI" (workflow_pattern
   grep) AND "locally applicable" (probe path exists). A stray
   `sonar-project.properties` without a sonar workflow must NOT trigger a scan.

5. **Nothing silent.** Every Lane-B tool whose binary/backend is absent is
   recorded `cannot-run` WITH a reason. The completeness assertion flags any
   in-CI tool that produced no local row as `UNACCOUNTED`. Preserve both.

6. **Everything is gitignored via `.git/info/exclude`** (`/.ci-local/`) — the
   harness never makes a committed change to the repo it runs in.

7. **Container backends are centralized here** (`containers/` + `backends/<tool>/`,
   Phase B), never per-repo. The Sonar backend is a real local SonarQube *server*
   container; `.mcp.json`'s `sonarqube` server is only the MCP *client* (for
   querying findings during the fix step), not the analysis backend.

## Layout

```
scripts/    run-ci-local.sh + ci-local-findings.py + ci-local-laneB.sh +
            ci-local-coverage.py + ci-local-tools.tsv + ci-local.env.example +
            install_act.sh        (all siblings — see constraint #1)
containers/ Dockerfile.sonarqube (+ compose)        # Phase B
backends/   sonarqube/ <future>/  # per-backend adapters, ports-and-adapters
tests/      self-test.sh (stdlib smoke) + *.bats
```

## Dev gate

`make ci` = `lint` (shellcheck `-x` + `py_compile`) + `test` (self-test + bats).
Keep `make self-test` green — it's the stdlib smoke that needs no act/network.

## Distribution

Consumer repos `curl` `run-ci-local.sh` via their `make ci-local` target. After
cutting a release tag here, the consumer Makefiles' `ci-local` source is
repointed to `ffreis-platform-ci-local@<TAG>` (one fleet scatter).
