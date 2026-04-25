#!/bin/bash
# rollback.sh - Rollback deployment to previous state
# Part of the deer-flow smoke-test skill

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

# Source shared utilities if available
if [[ -f "${SCRIPT_DIR}/utils.sh" ]]; then
    source "${SCRIPT_DIR}/utils.sh"
fi

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }

# Deployment mode: docker | local
DEPLOY_MODE="${DEPLOY_MODE:-docker}"
BACKUP_DIR="${PROJECT_ROOT}/.agent/backups"
ROLLBACK_TARGET="${1:-latest}"

# ── Docker rollback ────────────────────────────────────────────────────────────
rollback_docker() {
    log_info "Rolling back Docker deployment..."

    if ! command -v docker &>/dev/null; then
        log_error "Docker is not installed or not in PATH."
        return 1
    fi

    local compose_file="${PROJECT_ROOT}/docker-compose.yml"
    if [[ ! -f "${compose_file}" ]]; then
        log_error "docker-compose.yml not found at ${compose_file}"
        return 1
    fi

    log_info "Stopping current containers..."
    docker compose -f "${compose_file}" down --remove-orphans 2>/dev/null || true

    # Attempt to pull previous image tag if specified
    if [[ "${ROLLBACK_TARGET}" != "latest" ]]; then
        log_info "Pulling image tag: ${ROLLBACK_TARGET}"
        IMAGE_TAG="${ROLLBACK_TARGET}" docker compose -f "${compose_file}" pull 2>/dev/null || {
            log_warn "Could not pull tag '${ROLLBACK_TARGET}', using cached images."
        }
        IMAGE_TAG="${ROLLBACK_TARGET}" docker compose -f "${compose_file}" up -d
    else
        log_info "Restarting with existing images (no tag specified)..."
        docker compose -f "${compose_file}" up -d
    fi

    log_ok "Docker rollback completed."
}

# ── Local rollback ─────────────────────────────────────────────────────────────
rollback_local() {
    log_info "Rolling back local deployment..."

    if [[ ! -d "${BACKUP_DIR}" ]]; then
        log_error "Backup directory not found: ${BACKUP_DIR}"
        log_error "Cannot perform local rollback without a prior backup."
        return 1
    fi

    # Find the backup to restore
    local backup_path
    if [[ "${ROLLBACK_TARGET}" == "latest" ]]; then
        backup_path=$(ls -td "${BACKUP_DIR}"/backup_* 2>/dev/null | head -1)
    else
        backup_path="${BACKUP_DIR}/backup_${ROLLBACK_TARGET}"
    fi

    if [[ -z "${backup_path}" || ! -d "${backup_path}" ]]; then
        log_error "No valid backup found (target: ${ROLLBACK_TARGET})."
        return 1
    fi

    log_info "Restoring from backup: ${backup_path}"

    # Stop running services
    if [[ -f "${PROJECT_ROOT}/.agent/run/pids" ]]; then
        log_info "Stopping running processes..."
        while IFS= read -r pid; do
            kill "${pid}" 2>/dev/null && log_info "Killed PID ${pid}" || true
        done < "${PROJECT_ROOT}/.agent/run/pids"
        rm -f "${PROJECT_ROOT}/.agent/run/pids"
    fi

    # Restore config files
    if [[ -f "${backup_path}/.env" ]]; then
        cp "${backup_path}/.env" "${PROJECT_ROOT}/.env"
        log_ok "Restored .env from backup."
    fi

    if [[ -f "${backup_path}/conf.yaml" ]]; then
        cp "${backup_path}/conf.yaml" "${PROJECT_ROOT}/conf.yaml"
        log_ok "Restored conf.yaml from backup."
    fi

    log_ok "Local rollback completed."
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    log_info "=== DeerFlow Rollback ==="
    log_info "Mode: ${DEPLOY_MODE}  |  Target: ${ROLLBACK_TARGET}"
    echo

    case "${DEPLOY_MODE}" in
        docker) rollback_docker ;;
        local)  rollback_local  ;;
        *)
            log_error "Unknown DEPLOY_MODE '${DEPLOY_MODE}'. Use 'docker' or 'local'."
            exit 1
            ;;
    esac

    echo
    log_ok "Rollback finished. Run health_check.sh to verify service status."
}

main "$@"
