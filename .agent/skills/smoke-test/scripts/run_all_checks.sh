#!/bin/bash
# run_all_checks.sh — Orchestrates all smoke-test checks for deer-flow
# Runs environment, Docker, and frontend checks in sequence and reports results.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/../logs"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/smoke_test_${TIMESTAMP}.log"

# Colour codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Colour

# Track overall result
PASSED=0
FAILED=0
SKIPPED=0

mkdir -p "${LOG_DIR}"

log() {
  echo -e "$*" | tee -a "${LOG_FILE}"
}

run_check() {
  local label="$1"
  local script="$2"
  shift 2
  local extra_args=("$@")

  log "\n──────────────────────────────────────────"
  log "▶  ${label}"
  log "──────────────────────────────────────────"

  if [[ ! -x "${script}" ]]; then
    log "${YELLOW}[SKIP]${NC} ${script} not found or not executable."
    ((SKIPPED++)) || true
    return
  fi

  if bash "${script}" "${extra_args[@]}" 2>&1 | tee -a "${LOG_FILE}"; then
    log "${GREEN}[PASS]${NC} ${label}"
    ((PASSED++)) || true
  else
    log "${RED}[FAIL]${NC} ${label}"
    ((FAILED++)) || true
  fi
}

print_summary() {
  log "\n══════════════════════════════════════════"
  log "  Smoke-Test Summary — ${TIMESTAMP}"
  log "══════════════════════════════════════════"
  log "  ${GREEN}Passed : ${PASSED}${NC}"
  log "  ${RED}Failed : ${FAILED}${NC}"
  log "  ${YELLOW}Skipped: ${SKIPPED}${NC}"
  log "  Log    : ${LOG_FILE}"
  log "══════════════════════════════════════════"
}

# ---------------------------------------------------------------------------
# Parse optional flags
# ---------------------------------------------------------------------------
MODE="local"   # default: local (non-Docker) checks

while [[ $# -gt 0 ]]; do
  case "$1" in
    --docker)  MODE="docker" ; shift ;;
    --all)     MODE="all"    ; shift ;;
    --help|-h)
      echo "Usage: $0 [--local|--docker|--all]"
      echo "  --docker  Run Docker-specific checks only"
      echo "  --all     Run every available check (default: local)"
      exit 0
      ;;
    *) log "${YELLOW}Unknown argument: $1 — ignored.${NC}" ; shift ;;
  esac
done

log "Starting deer-flow smoke tests (mode: ${MODE}) …"

# ---------------------------------------------------------------------------
# Local environment checks
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "local" || "${MODE}" == "all" ]]; then
  run_check "Local environment prerequisites" "${SCRIPT_DIR}/check_local_env.sh"
  run_check "Frontend health check"           "${SCRIPT_DIR}/frontend_check.sh"
fi

# ---------------------------------------------------------------------------
# Docker checks
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "docker" || "${MODE}" == "all" ]]; then
  run_check "Docker availability"   "${SCRIPT_DIR}/check_docker.sh"
  run_check "Docker deployment"     "${SCRIPT_DIR}/deploy_docker.sh"
fi

# ---------------------------------------------------------------------------
# Local deployment check (always run for 'local' or 'all')
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "local" || "${MODE}" == "all" ]]; then
  run_check "Local deployment"  "${SCRIPT_DIR}/deploy_local.sh"
fi

print_summary

# Exit with non-zero if any check failed
[[ "${FAILED}" -eq 0 ]]
