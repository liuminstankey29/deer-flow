#!/usr/bin/env bash
# validate_config.sh - Validates configuration files and environment variables
# required for deer-flow to run correctly before deployment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASS=0
FAIL=0
WARN=0

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; ((WARN++)); }
log_info() { echo -e "[INFO] $1"; }

# ---------------------------------------------------------------------------
# Check that a required file exists and is non-empty
# ---------------------------------------------------------------------------
check_file_exists() {
  local filepath="$1"
  local label="$2"
  if [[ -f "${filepath}" && -s "${filepath}" ]]; then
    log_pass "${label} exists and is non-empty"
    return 0
  elif [[ -f "${filepath}" ]]; then
    log_warn "${label} exists but is empty: ${filepath}"
    return 1
  else
    log_fail "${label} not found: ${filepath}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Validate .env file keys
# ---------------------------------------------------------------------------
validate_env_file() {
  local env_file="${PROJECT_ROOT}/.env"

  log_info "Checking .env file at ${env_file}"

  if [[ ! -f "${env_file}" ]]; then
    # Fall back to .env.example if present
    if [[ -f "${PROJECT_ROOT}/.env.example" ]]; then
      log_warn ".env not found; falling back to .env.example for key validation"
      env_file="${PROJECT_ROOT}/.env.example"
    else
      log_fail ".env file is missing and no .env.example fallback found"
      return
    fi
  fi

  # Required keys that must be present (non-empty) in the env file
  local required_keys=(
    "OPENAI_API_KEY"
    "TAVILY_API_KEY"
  )

  # Optional but recommended keys
  local optional_keys=(
    "OPENAI_BASE_URL"
    "OPENAI_MODEL"
    "LOG_LEVEL"
  )

  for key in "${required_keys[@]}"; do
    if grep -qE "^${key}=.+" "${env_file}"; then
      log_pass "Required key present: ${key}"
    elif grep -qE "^${key}=" "${env_file}"; then
      log_fail "Required key is defined but empty: ${key}"
    else
      log_fail "Required key missing from env file: ${key}"
    fi
  done

  for key in "${optional_keys[@]}"; do
    if grep -qE "^${key}=.+" "${env_file}"; then
      log_pass "Optional key present: ${key}"
    else
      log_warn "Optional key not set (using default): ${key}"
    fi
  done
}

# ---------------------------------------------------------------------------
# Validate key project config files
# ---------------------------------------------------------------------------
validate_project_files() {
  log_info "Validating core project files"

  check_file_exists "${PROJECT_ROOT}/pyproject.toml"        "pyproject.toml"
  check_file_exists "${PROJECT_ROOT}/src/deer_flow/__init__.py" "Package __init__.py" || \
    check_file_exists "${PROJECT_ROOT}/deer_flow/__init__.py"   "Package __init__.py (alt path)"
  check_file_exists "${PROJECT_ROOT}/docker-compose.yml"    "docker-compose.yml" || \
    check_file_exists "${PROJECT_ROOT}/docker-compose.yaml" "docker-compose.yaml"
}

# ---------------------------------------------------------------------------
# Validate Python version constraint
# ---------------------------------------------------------------------------
validate_python_version() {
  log_info "Checking Python version"
  local python_bin
  python_bin=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo "")

  if [[ -z "${python_bin}" ]]; then
    log_fail "Python interpreter not found in PATH"
    return
  fi

  local version
  version=$("${python_bin}" -c "import sys; print('{}.{}'.format(*sys.version_info[:2]))")
  local major minor
  major=$(echo "${version}" | cut -d. -f1)
  minor=$(echo "${version}" | cut -d. -f2)

  if [[ "${major}" -ge 3 && "${minor}" -ge 11 ]]; then
    log_pass "Python version ${version} meets minimum requirement (>=3.11)"
  else
    log_fail "Python version ${version} does not meet minimum requirement (>=3.11)"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  echo "======================================="
  echo " deer-flow Configuration Validator"
  echo "======================================="
  echo ""

  validate_env_file
  echo ""
  validate_project_files
  echo ""
  validate_python_version

  echo ""
  echo "======================================="
  echo " Results: ${PASS} passed | ${WARN} warnings | ${FAIL} failed"
  echo "======================================="

  if [[ "${FAIL}" -gt 0 ]]; then
    echo -e "${RED}Configuration validation FAILED. Please fix the issues above.${NC}"
    exit 1
  elif [[ "${WARN}" -gt 0 ]]; then
    echo -e "${YELLOW}Configuration validation passed with warnings.${NC}"
    exit 0
  else
    echo -e "${GREEN}Configuration validation PASSED.${NC}"
    exit 0
  fi
}

main "$@"
