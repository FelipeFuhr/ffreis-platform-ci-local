#!/usr/bin/env bash
# backends/sonarqube/backend.sh — local SonarQube *server* backend (Lane B / sonar).
#
# Sourced by ci-local-laneB.sh. Implements the Lane-B backend contract:
#   sonar_local_up      → boot (or reuse) the server; echo an analysis token, or
#                         a reason + non-zero on failure (the dispatcher records
#                         cannot-run loudly — never silent).
#   sonar_local_run     → run the scanner container against the repo.
#   sonar_local_collect → fetch the quality gate + issues, write SARIF.
#   sonar_local_down    → stop + remove the server (separate Makefile target;
#                         not auto-called, so repeated runs reuse a warm server).
#
# A real SonarQube server is RAM- and disk-hungry, so sonar_local_up refuses to
# boot below safe thresholds (respecting the workspace's 10 GB disk guard) and
# emits a reason pointing at --sonar-cloud. Off-the-shelf image; no custom
# Dockerfile (containers/ is reserved for future custom backends).

CONTAINER_CMD="${CONTAINER_CMD:-podman}"
SONAR_IMAGE="${SONAR_IMAGE:-docker.io/library/sonarqube:community}"
SCANNER_IMAGE="${SCANNER_IMAGE:-docker.io/sonarsource/sonar-scanner-cli:latest}"
SONAR_CONTAINER="${SONAR_CONTAINER:-ci-local-sonarqube}"
SONAR_PORT="${SONAR_PORT:-9000}"
SONAR_URL="http://localhost:${SONAR_PORT}"
SONAR_ADMIN_USER="admin"
SONAR_ADMIN_PASS="${SONARQUBE_LOCAL_PASSWORD:-admin}"
SONAR_MIN_MEM_GB="${SONAR_MIN_MEM_GB:-4}"
SONAR_MIN_DISK_GB="${SONAR_MIN_DISK_GB:-10}"   # match the workspace check-disk guard
SONAR_BOOT_TRIES="${SONAR_BOOT_TRIES:-90}"     # × 3s ≈ 4.5 min (SonarQube first-boot is slow)

# the dispatcher reads stdout as either a token (rc 0) or a reason (rc != 0)
_sonar_emit() { printf '%s' "$1"; }

_sonar_status() { curl -fsS "${SONAR_URL}/api/system/status" 2>/dev/null; }

_sonar_enough_resources() {
  local mem_gb disk_gb
  mem_gb=$(free -g 2>/dev/null | awk '/^Mem:/{print $7}')
  [[ -z "$mem_gb" ]] && mem_gb=99
  if (( mem_gb < SONAR_MIN_MEM_GB )); then
    _sonar_emit "insufficient RAM (${mem_gb}GB available < ${SONAR_MIN_MEM_GB}GB the SonarQube server needs) — free memory or use --sonar-cloud"
    return 1
  fi
  disk_gb=$(df -BG . 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4); print $4}')
  [[ -z "$disk_gb" ]] && disk_gb=99
  if (( disk_gb < SONAR_MIN_DISK_GB )); then
    _sonar_emit "insufficient disk (${disk_gb}GB free < ${SONAR_MIN_DISK_GB}GB) — free space or use --sonar-cloud"
    return 1
  fi
  return 0
}

# generate an analysis token via the admin account (echoes token, or reason+rc1)
_sonar_token() {
  local tok
  tok=$(curl -fsS -u "${SONAR_ADMIN_USER}:${SONAR_ADMIN_PASS}" \
        -X POST "${SONAR_URL}/api/user_tokens/generate?name=ci-local-$$" 2>/dev/null \
        | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  if [[ -z "$tok" ]]; then
    _sonar_emit "could not mint a token (admin password may have changed — set SONARQUBE_LOCAL_PASSWORD)"
    return 1
  fi
  _sonar_emit "$tok"
}

sonar_local_up() {
  command -v "$CONTAINER_CMD" >/dev/null 2>&1 \
    || { _sonar_emit "$CONTAINER_CMD not installed"; return 1; }
  # reuse a warm server if one is already UP
  if _sonar_status | grep -q '"status":"UP"'; then
    _sonar_token; return $?
  fi
  _sonar_enough_resources || return 1
  "$CONTAINER_CMD" rm -f "$SONAR_CONTAINER" >/dev/null 2>&1 || true
  if ! "$CONTAINER_CMD" run -d --name "$SONAR_CONTAINER" \
        -p "${SONAR_PORT}:9000" \
        -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true \
        "$SONAR_IMAGE" >/dev/null 2>&1; then
    _sonar_emit "failed to start $SONAR_IMAGE (pull or run error)"
    return 1
  fi
  local i
  for ((i = 0; i < SONAR_BOOT_TRIES; i++)); do
    if _sonar_status | grep -q '"status":"UP"'; then
      _sonar_token; return $?
    fi
    sleep 3
  done
  _sonar_emit "SonarQube server did not reach UP in time (raise SONAR_BOOT_TRIES)"
  return 1
}

# sonar_local_run <repo_root> <token> — scan via the scanner container.
# --network=host so the scanner reaches the host-published server on :9000.
sonar_local_run() {
  local repo="$1" token="$2"
  "$CONTAINER_CMD" run --rm --network=host \
    -e SONAR_HOST_URL="$SONAR_URL" \
    -e SONAR_TOKEN="$token" \
    -v "${repo}:/usr/src:rw" \
    "$SCANNER_IMAGE" >/dev/null 2>&1
}

# sonar_local_collect <repo_root> <cil_dir> <token> — gate + issues → SARIF.
sonar_local_collect() {
  local repo="$1" cil="$2" token="$3"
  local rt="$repo/.scannerwork/report-task.txt"
  [[ -f "$rt" ]] || { _sonar_emit "no report-task.txt — the scan did not complete"; return 1; }
  local ce_task_id proj
  ce_task_id=$(sed -n 's/^ceTaskId=//p' "$rt")
  proj=$(sed -n 's/^projectKey=//p' "$rt")
  # poll the compute-engine task to completion
  local i status
  for ((i = 0; i < 60; i++)); do
    status=$(curl -fsS -u "${token}:" "${SONAR_URL}/api/ce/task?id=${ce_task_id}" 2>/dev/null \
             | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')
    [[ "$status" == "SUCCESS" ]] && break
    [[ "$status" == "FAILED" || "$status" == "CANCELED" ]] && { _sonar_emit "compute-engine task $status"; return 1; }
    sleep 2
  done
  curl -fsS -u "${token}:" "${SONAR_URL}/api/qualitygates/project_status?projectKey=${proj}" \
    -o "$cil/sonar-gate.json" 2>/dev/null || true
  curl -fsS -u "${token}:" "${SONAR_URL}/api/issues/search?componentKeys=${proj}&resolved=false&ps=500" \
    -o "$cil/sonar-issues.json" 2>/dev/null || true
  python3 "$(dirname "${BASH_SOURCE[0]}")/sonar-issues-to-sarif.py" \
    "$cil/sonar-issues.json" "$cil/findings/sonar.sarif" "$proj" 2>/dev/null || true
  # carry the .scannerwork trail into .ci-local for inspection
  if [[ -d "$repo/.scannerwork" ]]; then cp -r "$repo/.scannerwork" "$cil/scannerwork" 2>/dev/null || true; fi
  _sonar_emit "ok"
}

sonar_local_down() {
  "$CONTAINER_CMD" rm -f "$SONAR_CONTAINER" >/dev/null 2>&1 || true
}
