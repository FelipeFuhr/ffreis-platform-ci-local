# Contributing

This repo is the fleet's local-CI harness. Before a PR:

- `make ci` — lint (shellcheck + py_compile) + test (self-test + bats) must pass.
- Keep the scripts stdlib-only / POSIX-portable where they ship to consumers.
- New reusable-workflow references must stay classified in `scripts/ci-local-tools.tsv`
  (the repo's own CI runs the drift gate on itself).

See `AGENTS.md` for the non-obvious constraints.
