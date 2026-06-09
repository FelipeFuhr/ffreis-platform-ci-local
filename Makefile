# ffreis-platform-ci-local — the fleet's local-CI harness.
# Run every CI check locally (Lane A via act, Lane B via direct CLI/container),
# capture all findings, and assert nothing fell off-local.

SHELL := /usr/bin/env bash
SCRIPTS := $(shell find scripts/ -maxdepth 1 -name '*.sh' ! -type l 2>/dev/null | sort)
PYFILES := $(shell find scripts/ -maxdepth 1 -name '*.py' ! -type l 2>/dev/null | sort)
BATS_FILES := $(wildcard tests/*.bats)

.PHONY: help ci lint shellcheck py-check shfmt-check test self-test ci-local sonarqube-up sonarqube-down

help:
	@echo "ffreis-platform-ci-local targets:"
	@echo "  make ci          — lint + test (the pre-PR gate)"
	@echo "  make lint        — shellcheck scripts/*.sh + py_compile scripts/*.py"
	@echo "  make shellcheck  — shellcheck only"
	@echo "  make py-check    — py_compile only"
	@echo "  make shfmt-check — shfmt --diff (informational, non-blocking)"
	@echo "  make test        — bats suite + self-test of the python helpers"
	@echo "  make self-test   — exercise ci-local-findings.py + ci-local-coverage.py on fixtures"
	@echo "  make ci-local    — dogfood: run the harness on THIS repo (ARGS=… to pass flags)"

ci: lint test

lint: shellcheck py-check

shellcheck:
	@if command -v shellcheck >/dev/null 2>&1; then \
	  echo "shellcheck: linting $(words $(SCRIPTS)) scripts"; \
	  shellcheck -x $(SCRIPTS); \
	else \
	  echo "shellcheck not installed — skip (apt-get install shellcheck)"; \
	fi

py-check:
	@echo "py_compile: checking $(words $(PYFILES)) python files"
	@python3 -m py_compile $(PYFILES)

shfmt-check:
	@if command -v shfmt >/dev/null 2>&1; then \
	  drift=$$(shfmt -l -i 2 -ci $(SCRIPTS) 2>/dev/null); \
	  if [ -n "$$drift" ]; then \
	    echo "shfmt: drift from canonical style (informational, non-blocking):"; \
	    printf '%s\n' "$$drift" | sed 's|^|  |'; \
	  else \
	    echo "shfmt: all scripts at canonical style"; \
	  fi \
	else \
	  echo "shfmt not installed — skip"; \
	fi

test: self-test
	@if command -v bats >/dev/null 2>&1; then \
	  echo "bats: running $(words $(BATS_FILES)) test file(s)"; \
	  bats $(BATS_FILES); \
	else \
	  echo "bats not installed — skip (apt-get install bats)"; \
	fi

# Stdlib-only self-test: the python helpers must parse a known fixture and gate.
self-test:
	@bash tests/self-test.sh

# Dogfood the harness on this repo. `make ci-local ARGS=--findings` etc.
ci-local:
	@bash scripts/run-ci-local.sh $(ARGS)

# Local SonarQube server lifecycle (the Lane-B sonar backend). Boot once and
# reuse across runs; tear down when done. Refuses to boot below safe RAM/disk.
sonarqube-up:
	@bash -c 'source backends/sonarqube/backend.sh; \
	  out=$$(sonar_local_up) && echo "SonarQube UP at $$SONAR_URL — analysis token: $$out" \
	  || { echo "SonarQube not started: $$out"; exit 1; }'

sonarqube-down:
	@bash -c 'source backends/sonarqube/backend.sh; sonar_local_down; echo "SonarQube server removed."'
