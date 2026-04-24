#!/usr/bin/env bash
# report_results.sh — Aggregate smoke-test results and emit a human-readable
# summary (plus an optional JSON artefact for CI consumption).
#
# Usage:
#   ./report_results.sh [--json] [--output <file>] [--results-dir <dir>]
#
# Environment variables (all optional):
#   RESULTS_DIR   Directory that contains individual *.result files written by
#                 the other check scripts.  Defaults to /tmp/deerflow-smoke.
#   REPORT_JSON   Set to "1" to also write a machine-readable JSON summary.
#   REPORT_FILE   Path for the JSON output file.

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
RESULTS_DIR="${RESULTS_DIR:-/tmp/deerflow-smoke}"
REPORT_JSON="${REPORT_JSON:-0}"
REPORT_FILE="${REPORT_FILE:-${RESULTS_DIR}/smoke-report.json}"

# ── Colour helpers ────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' BOLD='' RESET=''
fi

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[PASS]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
fail()    { echo -e "${RED}[FAIL]${RESET}  $*"; }

# ── CLI argument parsing ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)           REPORT_JSON=1 ;;
    --output)         REPORT_FILE="$2"; shift ;;
    --results-dir)    RESULTS_DIR="$2"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# ── Collect results ───────────────────────────────────────────────────────────
if [[ ! -d "$RESULTS_DIR" ]]; then
  warn "Results directory not found: $RESULTS_DIR"
  warn "No individual check results to aggregate — was run_all_checks.sh executed?"
  exit 0
fi

PASS=0
FAIL=0
SKIP=0
declare -a DETAILS=()

while IFS= read -r -d '' result_file; do
  check_name="$(basename "$result_file" .result)"
  status="$(cat "$result_file" | tr -d '[:space:]')"

  case "$status" in
    PASS)
      (( PASS++ )) || true
      success "$check_name"
      DETAILS+=("\"$check_name\": \"pass\"")
      ;;
    FAIL)
      (( FAIL++ )) || true
      fail    "$check_name"
      DETAILS+=("\"$check_name\": \"fail\"")
      ;;
    SKIP)
      (( SKIP++ )) || true
      warn    "$check_name (skipped)"
      DETAILS+=("\"$check_name\": \"skip\"")
      ;;
    *)
      warn "$check_name — unrecognised status '${status}'"
      DETAILS+=("\"$check_name\": \"unknown\"")
      ;;
  esac
done < <(find "$RESULTS_DIR" -maxdepth 1 -name '*.result' -print0 | sort -z)

TOTAL=$(( PASS + FAIL + SKIP ))

# ── Print summary banner ──────────────────────────────────────────────────────
echo
echo -e "${BOLD}═══════════════════════════════════════${RESET}"
echo -e "${BOLD}  DeerFlow Smoke-Test Report${RESET}"
echo -e "${BOLD}═══════════════════════════════════════${RESET}"
printf "  Total checks : %d\n"  "$TOTAL"
printf "  ${GREEN}Passed${RESET}        : %d\n"  "$PASS"
printf "  ${RED}Failed${RESET}        : %d\n"  "$FAIL"
printf "  ${YELLOW}Skipped${RESET}       : %d\n"  "$SKIP"
echo -e "${BOLD}═══════════════════════════════════════${RESET}"
echo

# ── Optional JSON artefact ────────────────────────────────────────────────────
if [[ "$REPORT_JSON" == "1" ]]; then
  mkdir -p "$(dirname "$REPORT_FILE")"
  TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  DETAILS_JSON="$(IFS=','; echo "${DETAILS[*]}")"
  cat > "$REPORT_FILE" <<EOF
{
  "timestamp": "${TIMESTAMP}",
  "summary": {
    "total": ${TOTAL},
    "pass":  ${PASS},
    "fail":  ${FAIL},
    "skip":  ${SKIP}
  },
  "checks": { ${DETAILS_JSON} }
}
EOF
  info "JSON report written to: $REPORT_FILE"
fi

# ── Exit code reflects overall health ────────────────────────────────────────
if [[ "$FAIL" -gt 0 ]]; then
  fail "One or more checks failed.  Review the output above and consult:"
  fail "  .agent/skills/smoke-test/references/troubleshooting.md"
  exit 1
fi

success "All checks passed (or skipped)."
exit 0
