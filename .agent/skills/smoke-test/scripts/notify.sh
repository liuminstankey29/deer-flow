#!/usr/bin/env bash
# notify.sh — Send smoke-test result notifications via various channels.
# Supports: Slack webhook, email (sendmail/mailx), and local log file.
#
# Usage:
#   ./notify.sh --status <pass|fail|warn> --report <report_file> [OPTIONS]
#
# Options:
#   --status    pass | fail | warn  (required)
#   --report    Path to the HTML/text report file (required)
#   --channel   slack | email | log | all  (default: log)
#   --env       Deployment environment label (default: unknown)
#   --help      Show this help message

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
STATUS=""
REPORT_FILE=""
CHANNEL="${NOTIFY_CHANNEL:-log}"
ENV_LABEL="${DEPLOY_ENV:-unknown}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
NOTIFY_EMAIL="${NOTIFY_EMAIL:-}"
LOG_FILE="${SMOKE_TEST_LOG:-/tmp/smoke-test-notify.log}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Helpers ───────────────────────────────────────────────────────────────────
usage() {
  grep '^#' "$0" | sed 's/^# \?//'
  exit 0
}

log() { echo "[notify] $*" | tee -a "$LOG_FILE"; }
err() { echo "[notify][ERROR] $*" >&2 | tee -a "$LOG_FILE"; }

require_cmd() {
  command -v "$1" &>/dev/null || { err "Required command '$1' not found."; return 1; }
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)   STATUS="$2";      shift 2 ;;
    --report)   REPORT_FILE="$2"; shift 2 ;;
    --channel)  CHANNEL="$2";     shift 2 ;;
    --env)      ENV_LABEL="$2";   shift 2 ;;
    --help|-h)  usage ;;
    *) err "Unknown argument: $1"; exit 1 ;;
  esac
done

[[ -z "$STATUS" ]]      && { err "--status is required."; exit 1; }
[[ -z "$REPORT_FILE" ]] && { err "--report is required."; exit 1; }
[[ -f "$REPORT_FILE" ]] || { err "Report file not found: $REPORT_FILE"; exit 1; }

# Emoji / colour mapping
case "$STATUS" in
  pass) EMOJI=":white_check_mark:"; COLOUR="good" ;;
  fail) EMOJI=":x:";                COLOUR="danger" ;;
  warn) EMOJI=":warning:";          COLOUR="warning" ;;
  *)    err "Invalid status '$STATUS'. Expected pass|fail|warn."; exit 1 ;;
esac

TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
SUMMARY="Smoke-test *${STATUS^^}* on env=\`${ENV_LABEL}\` at ${TIMESTAMP}"

# ── Notification backends ─────────────────────────────────────────────────────
send_slack() {
  [[ -z "$SLACK_WEBHOOK_URL" ]] && { log "SLACK_WEBHOOK_URL not set — skipping Slack."; return 0; }
  require_cmd curl || return 1

  local body
  body=$(cat "$REPORT_FILE" | head -n 20 | sed 's/"/\\"/g')

  local payload
  payload=$(printf '{
    "attachments": [{
      "color": "%s",
      "title": "%s  deer-flow Smoke Test",
      "text": "%s",
      "footer": "deer-flow CI",
      "ts": %s
    }]
  }' "$COLOUR" "$EMOJI" "$SUMMARY" "$(date +%s)")

  if curl -s -o /dev/null -w "%{http_code}" \
       -X POST -H 'Content-type: application/json' \
       --data "$payload" "$SLACK_WEBHOOK_URL" | grep -q '^2'; then
    log "Slack notification sent."
  else
    err "Slack notification failed."
    return 1
  fi
}

send_email() {
  [[ -z "$NOTIFY_EMAIL" ]] && { log "NOTIFY_EMAIL not set — skipping email."; return 0; }

  local subject="[deer-flow] Smoke-test ${STATUS^^} — ${ENV_LABEL} ${TIMESTAMP}"

  if require_cmd mailx 2>/dev/null; then
    mailx -s "$subject" "$NOTIFY_EMAIL" < "$REPORT_FILE"
    log "Email sent via mailx to $NOTIFY_EMAIL."
  elif require_cmd sendmail 2>/dev/null; then
    { echo "Subject: $subject"; echo; cat "$REPORT_FILE"; } | sendmail "$NOTIFY_EMAIL"
    log "Email sent via sendmail to $NOTIFY_EMAIL."
  else
    err "No mail client found (mailx/sendmail). Cannot send email."
    return 1
  fi
}

send_log() {
  log "$SUMMARY"
  log "Full report appended to $LOG_FILE"
  cat "$REPORT_FILE" >> "$LOG_FILE"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
log "Notifying via channel(s): $CHANNEL"

FAILED=0
for ch in $(echo "$CHANNEL" | tr ',' ' '); do
  case "$ch" in
    slack) send_slack || FAILED=1 ;;
    email) send_email || FAILED=1 ;;
    log)   send_log ;;
    all)   send_slack || FAILED=1; send_email || FAILED=1; send_log ;;
    *)     err "Unknown channel: $ch"; FAILED=1 ;;
  esac
done

[[ $FAILED -eq 0 ]] && log "All notifications dispatched successfully." || { err "One or more notifications failed."; exit 1; }
