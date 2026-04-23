#!/bin/bash
# cleanup.sh - Clean up smoke test artifacts, temporary files, and optionally stop services
# Part of the deer-flow smoke test skill

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/.agent/logs/smoke-test"
TMP_DIR="${PROJECT_ROOT}/.agent/tmp/smoke-test"

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Clean up smoke-test artifacts and optionally stop running services.

Options:
  --logs          Remove smoke-test log files
  --tmp           Remove temporary files created during tests
  --docker        Stop and remove smoke-test Docker containers
  --all           Perform all cleanup actions (default when no flag given)
  --dry-run       Print what would be done without executing
  -h, --help      Show this help message
EOF
}

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
CLEAN_LOGS=false
CLEAN_TMP=false
CLEAN_DOCKER=false
DRY_RUN=false

if [[ $# -eq 0 ]]; then
    CLEAN_LOGS=true
    CLEAN_TMP=true
    CLEAN_DOCKER=false   # Docker cleanup is opt-in even with --all
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --logs)     CLEAN_LOGS=true   ;;
        --tmp)      CLEAN_TMP=true    ;;
        --docker)   CLEAN_DOCKER=true ;;
        --all)      CLEAN_LOGS=true; CLEAN_TMP=true; CLEAN_DOCKER=true ;;
        --dry-run)  DRY_RUN=true      ;;
        -h|--help)  usage; exit 0     ;;
        *) log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Utility: remove a path (respects --dry-run)
# ---------------------------------------------------------------------------
remove_path() {
    local target="$1"
    if [[ ! -e "$target" ]]; then
        log_warn "Path not found, skipping: $target"
        return 0
    fi
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[dry-run] Would remove: $target"
    else
        rm -rf "$target"
        log_ok "Removed: $target"
    fi
}

# ---------------------------------------------------------------------------
# Cleanup: logs
# ---------------------------------------------------------------------------
clean_logs() {
    log_info "Cleaning smoke-test log files ..."
    remove_path "$LOG_DIR"
}

# ---------------------------------------------------------------------------
# Cleanup: tmp
# ---------------------------------------------------------------------------
clean_tmp() {
    log_info "Cleaning temporary smoke-test files ..."
    remove_path "$TMP_DIR"
    # Also remove any stray .smoke-test-* files in project root
    while IFS= read -r -d '' f; do
        remove_path "$f"
    done < <(find "$PROJECT_ROOT" -maxdepth 2 -name '.smoke-test-*' -print0 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Cleanup: Docker containers labelled for smoke-test
# ---------------------------------------------------------------------------
clean_docker() {
    log_info "Stopping/removing smoke-test Docker containers ..."
    if ! command -v docker &>/dev/null; then
        log_warn "Docker not found — skipping container cleanup."
        return 0
    fi

    local containers
    containers=$(docker ps -aq --filter "label=smoke-test=true" 2>/dev/null || true)

    if [[ -z "$containers" ]]; then
        log_ok "No smoke-test containers found."
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[dry-run] Would stop/remove containers: $(echo "$containers" | tr '\n' ' ')"
    else
        echo "$containers" | xargs docker rm -f
        log_ok "Removed smoke-test containers."
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo -e "\n${BLUE}=== Smoke-Test Cleanup ===${NC}\n"

[[ "$DRY_RUN" == true ]] && log_warn "Dry-run mode enabled — no changes will be made.\n"

$CLEAN_LOGS   && clean_logs
$CLEAN_TMP    && clean_tmp
$CLEAN_DOCKER && clean_docker

echo -e "\n${GREEN}Cleanup complete.${NC}\n"
