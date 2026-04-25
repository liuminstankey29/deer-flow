#!/usr/bin/env bash
# collect_logs.sh — Gather logs from all services for smoke-test diagnostics
# Usage: ./collect_logs.sh [--output-dir <dir>] [--mode docker|local] [--tail <n>]

set -euo pipefail

# ──────────────────────────────────────────
# Defaults
# ──────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

OUTPUT_DIR="${PROJECT_ROOT}/.agent/logs/smoke-test/$(date +%Y%m%d_%H%M%S)"
MODE="local"
TAIL_LINES=200

# ──────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --mode)       MODE="$2";       shift 2 ;;
    --tail)       TAIL_LINES="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "${OUTPUT_DIR}"

log()  { echo "[collect_logs] $*"; }
warn() { echo "[collect_logs][WARN] $*" >&2; }

# ──────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────
save_log() {
  local label="$1"
  local dest="${OUTPUT_DIR}/${label}.log"
  # stdin → file; also print line count when done
  cat > "${dest}"
  local lines
  lines=$(wc -l < "${dest}")
  log "  Saved ${label}.log (${lines} lines) → ${dest}"
}

# ──────────────────────────────────────────
# Docker mode
# ──────────────────────────────────────────
collect_docker_logs() {
  log "Collecting Docker container logs (tail=${TAIL_LINES}) …"

  local containers
  containers=$(docker compose -f "${PROJECT_ROOT}/docker-compose.yml" ps -q 2>/dev/null || true)

  if [[ -z "${containers}" ]]; then
    warn "No running containers found via docker compose."
    return
  fi

  while IFS= read -r cid; do
    local name
    name=$(docker inspect --format '{{.Name}}' "${cid}" | sed 's|/||')
    log "  → ${name} (${cid:0:12})"
    docker logs --tail "${TAIL_LINES}" "${cid}" 2>&1 | save_log "docker_${name}"
  done <<< "${containers}"

  # Also capture compose events / ps snapshot
  docker compose -f "${PROJECT_ROOT}/docker-compose.yml" ps 2>&1 | save_log "docker_compose_ps"
}

# ──────────────────────────────────────────
# Local mode
# ──────────────────────────────────────────
collect_local_logs() {
  log "Collecting local process / file logs (tail=${TAIL_LINES}) …"

  # Common log file locations for DeerFlow
  local log_paths=(
    "${PROJECT_ROOT}/logs"
    "${PROJECT_ROOT}/backend/logs"
    "${PROJECT_ROOT}/web/.next/server"
    "/tmp/deerflow"
  )

  local found=0
  for dir in "${log_paths[@]}"; do
    [[ -d "${dir}" ]] || continue
    while IFS= read -r logfile; do
      local label
      label=$(echo "${logfile}" | sed "s|${PROJECT_ROOT}/||" | tr '/' '_' | sed 's|\.log$||')
      tail -n "${TAIL_LINES}" "${logfile}" 2>/dev/null | save_log "local_${label}"
      (( found++ ))
    done < <(find "${dir}" -maxdepth 3 -name '*.log' -type f 2>/dev/null)
  done

  if [[ ${found} -eq 0 ]]; then
    warn "No .log files found in expected directories."
  fi

  # Capture systemd journal for deerflow units if available
  if command -v journalctl &>/dev/null; then
    for unit in deerflow-backend deerflow-frontend; do
      if journalctl -u "${unit}" --no-pager -n "${TAIL_LINES}" &>/dev/null; then
        journalctl -u "${unit}" --no-pager -n "${TAIL_LINES}" 2>&1 | save_log "journal_${unit}"
      fi
    done
  fi
}

# ──────────────────────────────────────────
# System snapshot (always collected)
# ──────────────────────────────────────────
collect_system_snapshot() {
  log "Collecting system snapshot …"
  {
    echo "=== date ===";          date
    echo "=== uptime ===";        uptime
    echo "=== df -h ===";         df -h 2>/dev/null || true
    echo "=== free -m ===";       free -m 2>/dev/null || true
    echo "=== listening ports ==="; ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || true
    echo "=== env (filtered) ==="; env | grep -iE 'DEER|OPENAI|API|PORT|HOST|NODE_ENV|PYTHONPATH' | sort || true
  } | save_log "system_snapshot"
}

# ──────────────────────────────────────────
# Main
# ──────────────────────────────────────────
main() {
  log "Starting log collection — mode=${MODE}, output=${OUTPUT_DIR}"

  collect_system_snapshot

  case "${MODE}" in
    docker) collect_docker_logs ;;
    local)  collect_local_logs  ;;
    *) warn "Unknown mode '${MODE}'; defaulting to local."; collect_local_logs ;;
  esac

  log "Log collection complete. Artifacts saved to: ${OUTPUT_DIR}"
  echo "${OUTPUT_DIR}"   # allow callers to capture the path
}

main "$@"
