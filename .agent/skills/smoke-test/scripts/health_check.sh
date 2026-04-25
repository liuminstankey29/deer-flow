#!/bin/bash
# health_check.sh - Comprehensive health check for DeerFlow services
# Verifies API endpoints, service responsiveness, and basic functionality

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

# Default configuration
API_HOST="${API_HOST:-localhost}"
API_PORT="${API_PORT:-8000}"
FRONTEND_PORT="${FRONTEND_PORT:-3000}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-30}"
RETRY_INTERVAL="${RETRY_INTERVAL:-3}"
MAX_RETRIES="${MAX_RETRIES:-10}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Result tracking
PASSED=0
FAILED=0
WARNINGS=0

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[PASS]${NC}  $*"; PASSED=$((PASSED + 1)); }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; WARNINGS=$((WARNINGS + 1)); }
log_error()   { echo -e "${RED}[FAIL]${NC}  $*"; FAILED=$((FAILED + 1)); }

# Wait for a service to become available
wait_for_service() {
    local name="$1"
    local url="$2"
    local retries=0

    log_info "Waiting for ${name} at ${url}..."
    while [ $retries -lt $MAX_RETRIES ]; do
        if curl -sf --max-time 5 "${url}" > /dev/null 2>&1; then
            log_success "${name} is reachable"
            return 0
        fi
        retries=$((retries + 1))
        sleep "$RETRY_INTERVAL"
    done

    log_error "${name} did not become available after $((MAX_RETRIES * RETRY_INTERVAL))s"
    return 1
}

# Check backend API health endpoint
check_api_health() {
    local url="http://${API_HOST}:${API_PORT}/health"
    log_info "Checking API health endpoint: ${url}"

    local response
    response=$(curl -sf --max-time 10 "${url}" 2>&1) || {
        log_error "API health endpoint unreachable: ${url}"
        return 1
    }

    if echo "${response}" | grep -qi '"status".*"ok"\|"healthy".*true\|"status".*"healthy"'; then
        log_success "API health endpoint returned healthy status"
    else
        log_warn "API health endpoint reachable but status unclear: ${response}"
    fi
}

# Check API docs endpoint (FastAPI default)
check_api_docs() {
    local url="http://${API_HOST}:${API_PORT}/docs"
    if curl -sf --max-time 10 "${url}" > /dev/null 2>&1; then
        log_success "API docs endpoint accessible: ${url}"
    else
        log_warn "API docs endpoint not accessible (may be disabled in production)"
    fi
}

# Check frontend is serving content
check_frontend() {
    local url="http://${API_HOST}:${FRONTEND_PORT}"
    log_info "Checking frontend at ${url}"

    local http_code
    http_code=$(curl -so /dev/null --max-time 10 -w "%{http_code}" "${url}" 2>&1) || true

    if [ "${http_code}" = "200" ] || [ "${http_code}" = "304" ]; then
        log_success "Frontend is serving content (HTTP ${http_code})"
    else
        log_error "Frontend returned unexpected HTTP status: ${http_code}"
    fi
}

# Verify a basic chat/inference API call
check_api_inference_route() {
    local url="http://${API_HOST}:${API_PORT}/api/chat/completions"
    log_info "Probing inference route: ${url}"

    local http_code
    http_code=$(curl -so /dev/null --max-time 10 -w "%{http_code}" \
        -X POST "${url}" \
        -H 'Content-Type: application/json' \
        -d '{"messages":[{"role":"user","content":"ping"}],"stream":false}' 2>&1) || true

    case "${http_code}" in
        200|201) log_success "Inference route responded with HTTP ${http_code}" ;;
        422)     log_warn "Inference route returned 422 (schema mismatch — acceptable for probe)" ;;
        401|403) log_warn "Inference route returned ${http_code} (auth required — expected in secured env)" ;;
        404)     log_warn "Inference route not found at ${url} (path may differ)" ;;
        *)       log_error "Inference route returned unexpected HTTP ${http_code}" ;;
    esac
}

# Summary report
print_summary() {
    echo
    echo "======================================"
    echo "  Health Check Summary"
    echo "======================================"
    echo -e "  ${GREEN}Passed${NC}:   ${PASSED}"
    echo -e "  ${YELLOW}Warnings${NC}: ${WARNINGS}"
    echo -e "  ${RED}Failed${NC}:   ${FAILED}"
    echo "======================================"

    if [ "$FAILED" -gt 0 ]; then
        echo -e "${RED}Health check FAILED — see errors above.${NC}"
        exit 1
    elif [ "$WARNINGS" -gt 0 ]; then
        echo -e "${YELLOW}Health check passed with warnings.${NC}"
        exit 0
    else
        echo -e "${GREEN}All health checks passed.${NC}"
        exit 0
    fi
}

main() {
    echo "======================================"
    echo "  DeerFlow Health Check"
    echo "  API:      http://${API_HOST}:${API_PORT}"
    echo "  Frontend: http://${API_HOST}:${FRONTEND_PORT}"
    echo "======================================"
    echo

    wait_for_service "Backend API" "http://${API_HOST}:${API_PORT}/health" || true
    check_api_health
    check_api_docs
    check_frontend
    check_api_inference_route

    print_summary
}

main "$@"
