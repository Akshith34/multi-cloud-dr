#!/usr/bin/env bash
###############################################################
# DR Drill Automation Script
# Runs full DR failover drill with validation and reporting
#
# Usage:
#   ./dr-drill.sh --mode active-passive --target us-west-2
#   ./dr-drill.sh --mode active-active --weight 0:100 --duration 30m
#   ./dr-drill.sh --validate-only --region us-west-2
#   ./dr-drill.sh --dry-run --mode active-passive
###############################################################

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── Defaults ──────────────────────────────────────────────────
MODE="active-passive"
TARGET_REGION="us-west-2"
DURATION="30m"
PRIMARY_WEIGHT=0
SECONDARY_WEIGHT=100
DRY_RUN=false
VALIDATE_ONLY=false
NOTIFY_SLACK=false
INCIDENT_ID="DRILL-$(date +%Y%m%d-%H%M%S)"
LAMBDA_FUNCTION="dr-orchestrator-prod"
LAMBDA_REGION="us-east-1"
LOG_FILE="/tmp/dr-drill-${INCIDENT_ID}.log"

# ── Parse Arguments ───────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --mode)         MODE="$2"; shift 2 ;;
    --target)       TARGET_REGION="$2"; shift 2 ;;
    --weight)       IFS=":" read -r PRIMARY_WEIGHT SECONDARY_WEIGHT <<< "$2"; shift 2 ;;
    --duration)     DURATION="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --validate-only) VALIDATE_ONLY=true; shift ;;
    --notify-slack) NOTIFY_SLACK=true; shift ;;
    --region)       TARGET_REGION="$2"; shift 2 ;;
    *)              echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Logging ───────────────────────────────────────────────────
log() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo -e "${ts} $*" | tee -a "${LOG_FILE}"
}

log_step() { log "${BLUE}${BOLD}[STEP]${NC} $*"; }
log_ok()   { log "${GREEN}${BOLD}[OK]${NC}   $*"; }
log_warn() { log "${YELLOW}${BOLD}[WARN]${NC} $*"; }
log_fail() { log "${RED}${BOLD}[FAIL]${NC} $*"; }
log_info() { log "${BOLD}[INFO]${NC} $*"; }

# ── Header ────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Multi-Cloud DR Drill — ${INCIDENT_ID}${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "  Mode:        ${BOLD}${MODE}${NC}"
echo -e "  Target:      ${BOLD}${TARGET_REGION}${NC}"
echo -e "  Dry Run:     ${BOLD}${DRY_RUN}${NC}"
echo -e "  Validate:    ${BOLD}${VALIDATE_ONLY}${NC}"
echo -e "  Log file:    ${LOG_FILE}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""

DRILL_START=$(date +%s)

# ── Validate Only Mode ────────────────────────────────────────
if [[ "${VALIDATE_ONLY}" == "true" ]]; then
  log_step "Running post-failover validation only for region: ${TARGET_REGION}"
  aws lambda invoke \
    --function-name "${LAMBDA_FUNCTION}" \
    --region "${LAMBDA_REGION}" \
    --payload "$(jq -n \
      --arg region "${TARGET_REGION}" \
      --arg incident "${INCIDENT_ID}" \
      '{action:"validate",trigger:"manual",target_region:$region,incident_id:$incident}'
    )" \
    --cli-binary-format raw-in-base64-out \
    /tmp/dr-validate-result.json

  cat /tmp/dr-validate-result.json | jq .
  exit 0
fi

# ── Pre-Drill Checks ──────────────────────────────────────────
log_step "Running pre-drill checks..."

# Confirm AWS credentials
if ! aws sts get-caller-identity --region "${LAMBDA_REGION}" &>/dev/null; then
  log_fail "AWS credentials not configured or expired. Aborting."
  exit 1
fi
log_ok "AWS credentials valid"

# Check Lambda function exists
if ! aws lambda get-function --function-name "${LAMBDA_FUNCTION}" --region "${LAMBDA_REGION}" &>/dev/null; then
  log_fail "Lambda function '${LAMBDA_FUNCTION}' not found in ${LAMBDA_REGION}. Aborting."
  exit 1
fi
log_ok "Lambda orchestrator found"

# Confirm replication status before drill
log_step "Checking replication health before drill..."
bash "$(dirname "$0")/validate-replication.sh" || {
  log_warn "Replication issues detected. Review before continuing."
  read -rp "  Continue with drill anyway? (yes/no): " confirm
  [[ "${confirm}" == "yes" ]] || { log_info "Drill aborted by user."; exit 0; }
}
log_ok "Pre-drill checks passed"

# ── Execute Failover ──────────────────────────────────────────
log_step "Invoking DR orchestrator Lambda (mode: ${MODE})..."

PAYLOAD=$(jq -n \
  --arg action "$([ "${MODE}" == "active-active" ] && echo "weight-shift" || echo "failover")" \
  --arg mode "${MODE}" \
  --arg region "${TARGET_REGION}" \
  --arg incident "${INCIDENT_ID}" \
  --argjson dry_run "${DRY_RUN}" \
  --argjson primary_weight "${PRIMARY_WEIGHT}" \
  '{
    action: $action,
    trigger: "dr-drill",
    target_region: $region,
    dry_run: $dry_run,
    incident_id: $incident,
    initiated_by: "dr-drill-script",
    new_primary_weight: $primary_weight
  }'
)

INVOKE_START=$(date +%s)
aws lambda invoke \
  --function-name "${LAMBDA_FUNCTION}" \
  --region "${LAMBDA_REGION}" \
  --payload "${PAYLOAD}" \
  --cli-binary-format raw-in-base64-out \
  /tmp/dr-drill-result.json \
  --log-type Tail \
  --query 'LogResult' \
  --output text 2>/dev/null | base64 -d >> "${LOG_FILE}" || true

INVOKE_END=$(date +%s)
FAILOVER_TIME=$((INVOKE_END - INVOKE_START))

RESULT=$(cat /tmp/dr-drill-result.json)
STATUS=$(echo "${RESULT}" | jq -r '.body | fromjson | .status' 2>/dev/null || echo "UNKNOWN")

if [[ "${STATUS}" == "COMPLETED" ]]; then
  log_ok "Failover completed in ${FAILOVER_TIME}s"
else
  log_fail "Failover FAILED. Status: ${STATUS}"
  echo "${RESULT}" | jq .
  exit 1
fi

# ── Post-Failover Monitoring ──────────────────────────────────
log_step "Monitoring post-failover health for 5 minutes..."

for i in {1..10}; do
  sleep 30
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    "https://app.yourdomain.com/health" 2>/dev/null || echo "000")

  if [[ "${HTTP_STATUS}" == "200" ]]; then
    log_ok "Health check ${i}/10 — HTTP ${HTTP_STATUS} ✅"
  else
    log_warn "Health check ${i}/10 — HTTP ${HTTP_STATUS} ⚠️"
  fi
done

# ── Drill Summary ─────────────────────────────────────────────
DRILL_END=$(date +%s)
TOTAL_DURATION=$((DRILL_END - DRILL_START))

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  DR Drill Complete — ${INCIDENT_ID}${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "  Total duration:   ${BOLD}${TOTAL_DURATION}s${NC}"
echo -e "  Failover time:    ${BOLD}${FAILOVER_TIME}s${NC}"
echo -e "  Final status:     ${GREEN}${BOLD}${STATUS}${NC}"
echo -e "  Full log:         ${LOG_FILE}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"

# Upload drill results to S3
if [[ "${DRY_RUN}" == "false" ]]; then
  RESULT_JSON=$(jq -n \
    --arg id "${INCIDENT_ID}" \
    --arg mode "${MODE}" \
    --arg region "${TARGET_REGION}" \
    --argjson duration "${TOTAL_DURATION}" \
    --argjson failover_time "${FAILOVER_TIME}" \
    --arg status "${STATUS}" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      drill_id: $id,
      mode: $mode,
      target_region: $region,
      total_duration_seconds: $duration,
      failover_time_seconds: $failover_time,
      status: $status,
      timestamp: $ts
    }'
  )

  echo "${RESULT_JSON}" | aws s3 cp - \
    "s3://myapp-dr-audit-logs/drill-results/${INCIDENT_ID}.json" \
    --content-type application/json \
    --region us-east-1 2>/dev/null && \
    log_ok "Drill results saved to S3" || \
    log_warn "Could not save drill results to S3 (non-fatal)"
fi

log_info "DR drill complete. Remember to:"
log_info "  1. Update README.md drill results table"
log_info "  2. Execute rollback if this was not a live DR event"
log_info "  3. Schedule post-drill review with SRE + DBA teams"
