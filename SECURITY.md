# Security Policy

## Reporting a Vulnerability

This repository holds the fleet's **local-CI harness** — shell + Python tooling
that runs CI checks locally. It ships no runtime service and handles no user
data, but it does execute scanners and may read local credentials (AWS profile,
`gh` token, `~/.config/ffreis/ci-local.env`) to pass through to `act`.

If you find a security issue (e.g. a path that could leak a captured secret out
of the gitignored `.ci-local/`, or an injection in a scanner adapter), please do
**not** open a public issue. Email the maintainer at felipefuhr7@gmail.com with
details and a reproduction. You'll get an acknowledgement within a few days.

## Handling of secrets

- The harness never logs token/secret *values*; it passes them to `act` via a
  temporary secret-file that is removed on exit.
- All scanner output lands in a **gitignored** `.ci-local/` (via
  `.git/info/exclude`) so findings — which may quote secrets — are never
  committed.
- Lane-B backends run locally/offline by default (no SonarCloud writes).
