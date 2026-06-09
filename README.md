# ffreis-platform-ci-local

The fleet's **local-CI harness**: run every CI check on your machine, capture
all findings in one place, and guarantee no check silently falls off-local.

`act` is one lane, not the whole story. Some checks (Sonar, CodeQL) are
server-side and can't run under `act` at all; others run but their findings die
with the container. This harness runs each check **by the right mechanism** and
funnels everything into one gitignored `.ci-local/`, so every CI tool ends in
exactly one bucket — `ran` / `found` / `couldn't-run (reason)` — and anything
unaccounted-for is reported **loudly**.

## Quick start

```bash
# from inside any fleet repo with .github/workflows/
make ci-local ARGS=--findings        # Lane A (act) + capture + classify + gate
make ci-local ARGS=--full            # Lane A + Lane B (codeql, sonar) + coverage
make ci-local ARGS=--lane-b-only     # only the non-act scanners (the /ready gate)
```

Or invoke the script directly:

```bash
scripts/run-ci-local.sh --full
scripts/run-ci-local.sh --lane-b-only --sonar-cloud   # public-repo Sonar via SonarCloud PR analysis
```

## The two lanes

| Lane | Mechanism | Tools |
|---|---|---|
| **A** | `act --bind` | golangci-lint, gitleaks, trivy, grype, osv-scanner, semgrep, govulncheck, clippy, cargo-deny/-audit, pip-audit |
| **B** | direct CLI / container | codeql (CLI), sonar (local SonarQube container, or `--sonar-cloud`) |
| **cannot** | no faithful local run | scorecard, snyk, dependency-review, claude-judge (recorded loudly, with a reason) |

## Components (`scripts/`)

- **`run-ci-local.sh`** — the entrypoint. Runs Lane A (act), dispatches Lane B,
  aggregates findings, asserts coverage, gates on errors.
- **`ci-local-findings.py`** — stdlib SARIF 2.1.0 aggregator → `file:line ·
  severity · tool/rule · message · fix-hint`; exits non-zero on any ERROR.
- **`ci-local-laneB.sh`** — the Lane-B dispatcher (codeql, sonar) — runs each by
  its own CLI/container; an absent binary/backend is recorded `cannot-run` with
  a reason, never silently skipped.
- **`ci-local-coverage.py`** — the completeness assertion: reconciles the tools
  this repo's CI references against the tools the run accounted for; flags
  **UNACCOUNTED** loudly.
- **`ci-local-tools.tsv`** — the central tool registry (tool · lane ·
  workflow-pattern · probe · reason). The single source of truth for "how does
  each CI check run locally?"

## Everything lands here (gitignored)

```
.ci-local/
  findings/   *.sarif (Lane A + Lane B)
  coverage/   coverage.out / lcov.info / coverage.xml
  logs/       act-<ts>.log
  run.json    per-job classification
  lane-b.json per-Lane-B-tool status
```

`.ci-local/` is excluded via `.git/info/exclude` — no committed change needed.

## Distribution

Consumer repos pull this harness through their `make ci-local` target (it
`curl`s `run-ci-local.sh`, which self-bootstraps its sibling helpers). See each
repo's Makefile.

## Development

```bash
make ci          # lint (shellcheck + py_compile) + test (self-test + bats)
make self-test   # exercise the python helpers against fixtures (no act/network)
```
