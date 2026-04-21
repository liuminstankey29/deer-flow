#!/bin/bash
# check_services.sh - Verify all required services are running and healthy
# Part of the deer-flow smoke test suite

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ─── Config ───────────────────────────────────────────────────────────────────
BACKEND_HOST="${BACKEND_HOST:-localhost}"
BACKEND_PORT="${BACKEND_PORT:-8000}"
FRONTEND_HOST="${FRONTEND_HOST:-localhost}"
FRONTEND_PORT="${FRONTEND_PORT:-3000}"
HEALTH_ENDPOINT="${HEALTH_ENDPOINT:-/health}"
MAX_RETRIES="${MAX_RETRIES:-5}"
RETRY_DELAY="${RETRY_DELAY:-3}"
TIMEOUT="${TIMEOUT:-10}"

PASS=0
FAIL=0
WARN=0

# ─── Helpers ──────────────────────────────────────────────────────────────────
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[PASS]${NC}  $*"; ((PASS++)); }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; ((WARN++)); }
log_fail()  { echo -e "${RED}[FAIL]${NC}  $*"; ((FAIL++)); }

# Retry a command up to MAX_RETRIES times with RETRY_DELAY seconds between attempts
retry() {
  local cmd="$*"
  local attempt=1
  until eval "$cmd"; do
    if (( attempt >= MAX_RETRIES )); then
      return 1
    fi
    log_info "Attempt $attempt/$MAX_RETRIES failed, retrying in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
    ((attempt++))
  done
}

# ─── Checks ───────────────────────────────────────────────────────────────────
check_port_open() {
  local host="$1" port="$2" label="$3"
  log_info "Checking TCP connectivity to $label ($host:$port)..."
  if retry "nc -z -w $TIMEOUT $host $port 2>/dev/null"; then
    log_ok "$label is reachable on $host:$port"
  else
    log_fail "$label is NOT reachable on $host:$port after $MAX_RETRIES attempts"
  fi
}

check_http_health() {
  local url="$1" label="$2"
  log_info "Checking HTTP health for $label ($url)..."
  local http_code
  http_code=$(retry "curl -s -o /dev/null -w '%{http_code}' --max-time $TIMEOUT '$url'")
  if [[ "$http_code" == "200" ]]; then
    log_ok "$label health endpoint returned HTTP 200"
  elif [[ "$http_code" =~ ^[23] ]]; then
    log_warn "$label health endpoint returned HTTP $http_code (non-200 success)"
  else
    log_fail "$label health endpoint returned HTTP $http_code"
  fi
}

check_backend_api_docs() {
  local url="http://${BACKEND_HOST}:${BACKEND_PORT}/docs"
  log_info "Checking backend API docs availability..."
  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$url" 2>/dev/null || echo "000")
  if [[ "$http_code" == "200" ]]; then
    log_ok "Backend API docs accessible at $url"
  else
    log_warn "Backend API docs not accessible (HTTP $http_code) — may be disabled in production"
  fi
}

check_redis_if_present() {
  local redis_host="${REDIS_HOST:-localhost}"
  local redis_port="${REDIS_PORT:-6379}"
  if command -v redis-cli &>/dev/null; then
    log_info "Checking Redis connectivity..."
    if redis-cli -h "$redis_host" -p "$redis_port" ping 2>/dev/null | grep -q PONG; then
      log_ok "Redis is responding on $redis_host:$redis_port"
    else
      log_warn "Redis is not responding on $redis_host:$redis_port (may not be required)"
    fi
  else
    log_info "redis-cli not found — skipping Redis check"
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  echo -e "\n${BLUE}═══════════════════════════════════════════${NC}"
  echo -e "${BLUE}   deer-flow Service Health Checks${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════${NC}\n"

  check_port_open "$BACKEND_HOST"  "$BACKEND_PORT"  "Backend API"
  check_port_open "$FRONTEND_HOST" "$FRONTEND_PORT" "Frontend"

  check_http_health "http://${BACKEND_HOST}:${BACKEND_PORT}${HEALTH_ENDPOINT}" "Backend API"
  check_http_health "http://${FRONTEND_HOST}:${FRONTEND_PORT}"                 "Frontend"

  check_backend_api_docs
  check_redis_if_present

  echo -e "\n${BLUE}─── Summary ───────────────────────────────${NC}"
  echo -e "  ${GREEN}PASS${NC}: $PASS  ${YELLOW}WARN${NC}: $WARN  ${RED}FAIL${NC}: $FAIL"
  echo -e "${BLUE}───────────────────────────────────────────${NC}\n"

  if (( FAIL > 0 )); then
    echo -e "${RED}Service checks FAILED. See output above for details.${NC}"
    exit 1
  elif (( WARN > 0 )); then
    echo -e "${YELLOW}Service checks passed with warnings.${NC}"
    exit 0
  else
    echo -e "${GREEN}All service checks passed.${NC}"
    exit 0
  fi
}

main "$@"
