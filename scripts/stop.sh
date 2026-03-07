#!/bin/bash
#
# stop.sh - OpenClaw Multi-Agent System 정지
#
# 1. run_state.json을 "stopped"으로 설정
# 2. Cron heartbeat 비활성화
# 3. 실행 중인 사이클 완료 대기 (최대 60초)
# 4. Slack으로 "System stopped" 전송
#

set -euo pipefail

# ─────────────────────────────────────────────
# 경로 설정
# ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$PROJECT_DIR/state"
CONFIG_FILE="$PROJECT_DIR/openclaw.json"
RUN_STATE_FILE="$STATE_DIR/run_state.json"
COST_LEDGER_FILE="$STATE_DIR/cost_ledger.json"
OPENCLAW_PROFILE="${OPENCLAW_PROFILE:-openclaw-multi-agent}"
PROFILE_SAFE="$(printf "%s" "$OPENCLAW_PROFILE" | tr -c '[:alnum:]_.-' '_')"
OPENCLAW_CMD=(openclaw --profile "$OPENCLAW_PROFILE")

GRACEFUL_TIMEOUT=60

# ─────────────────────────────────────────────
# 색상 정의
# ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

# ─────────────────────────────────────────────
# 유틸리티 함수
# ─────────────────────────────────────────────
log_info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

now_iso() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# ─────────────────────────────────────────────
# 사전 확인
# ─────────────────────────────────────────────
if [ ! -f "$RUN_STATE_FILE" ]; then
    log_error "run_state.json을 찾을 수 없습니다: $RUN_STATE_FILE"
    log_error "시스템이 시작된 적이 없거나, state 디렉토리가 손상되었습니다."
    exit 1
fi

CURRENT_STATUS=$(python3 -c "
import json
with open('$RUN_STATE_FILE') as f:
    print(json.load(f).get('status', 'unknown'))
" 2>/dev/null || echo "unknown")

if [ "$CURRENT_STATUS" = "stopped" ]; then
    log_warn "시스템이 이미 정지 상태입니다."
    exit 0
fi

echo -e "${BOLD}${YELLOW}════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${YELLOW}  OpenClaw Multi-Agent System - STOPPING${NC}"
echo -e "${BOLD}${YELLOW}════════════════════════════════════════════════════${NC}"
echo ""

# ─────────────────────────────────────────────
# Step 1: run_state.json을 "stopping"으로 설정
# ─────────────────────────────────────────────
log_info "시스템 상태를 'stopping'으로 설정 중..."

python3 -c "
import json
with open('$RUN_STATE_FILE', 'r') as f:
    state = json.load(f)
state['status'] = 'stopping'
state['last_updated'] = '$(now_iso)'
with open('$RUN_STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2, ensure_ascii=False)
"

log_ok "상태 전환: running → stopping"

# ─────────────────────────────────────────────
# Step 2: Cron heartbeat 비활성화
# ─────────────────────────────────────────────
log_info "Cron heartbeat 비활성화 중..."

CRON_STATE_FILE="$STATE_DIR/cron_state.${PROFILE_SAFE}.json"
CRON_DISABLED=false

SAVED_CRON_ID=""
if [ -f "$CRON_STATE_FILE" ]; then
    SAVED_CRON_ID=$(python3 -c "
import json
with open('$CRON_STATE_FILE') as f:
    print(json.load(f).get('cron_job_id') or '')
" 2>/dev/null || echo "")
fi

if [ -n "$SAVED_CRON_ID" ]; then
if "${OPENCLAW_CMD[@]}" cron disable "$SAVED_CRON_ID" 2>/dev/null; then
        CRON_DISABLED=true
        log_ok "Cron heartbeat 비활성화 완료 (ID: $SAVED_CRON_ID)"
    else
        log_warn "저장된 ID로 비활성화 실패, 이름 기반 검색 시도..."
    fi
fi

if [ "$CRON_DISABLED" = false ]; then
    CRON_LIST=$("${OPENCLAW_CMD[@]}" cron list --json 2>/dev/null || echo "[]")
    CRON_IDS=$(echo "$CRON_LIST" | python3 -c "
import json, sys
try:
    jobs = json.load(sys.stdin)
    if isinstance(jobs, list):
        for j in jobs:
            if 'orchestrat' in j.get('name', '').lower() or j.get('agentId') == 'orchestrator':
                print(j.get('id', ''))
except: pass
" 2>/dev/null)

    if [ -n "$CRON_IDS" ]; then
        while IFS= read -r cron_id; do
            if [ -n "$cron_id" ]; then
                "${OPENCLAW_CMD[@]}" cron disable "$cron_id" 2>/dev/null && CRON_DISABLED=true
            fi
        done <<< "$CRON_IDS"
    fi

    if [ "$CRON_DISABLED" = true ]; then
        log_ok "Cron heartbeat 비활성화 완료 (이름 기반 검색)"
    else
        log_warn "비활성화할 cron job을 찾지 못했습니다."
    fi
fi

if [ -f "$CRON_STATE_FILE" ]; then
    python3 -c "
import json
with open('$CRON_STATE_FILE', 'r') as f:
    state = json.load(f)
state['enabled'] = False
state['last_disabled'] = '$(now_iso)'
with open('$CRON_STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
"
fi

# ─────────────────────────────────────────────
# Step 3: 실행 중인 사이클 완료 대기
# ─────────────────────────────────────────────
log_info "실행 중인 사이클 정리 대기 중 (최대 ${GRACEFUL_TIMEOUT}초)..."
sleep 2
log_info "PID 기반 종료는 사용하지 않습니다. cron 비활성화 후 새 사이클은 시작되지 않습니다."

log_info "OpenClaw 세션 정리는 gateway에서 자동 관리됩니다."

# ─────────────────────────────────────────────
# Step 4: run_state.json을 "stopped"으로 설정
# ─────────────────────────────────────────────
log_info "시스템 상태를 'stopped'으로 설정 중..."

python3 -c "
import json
with open('$RUN_STATE_FILE', 'r') as f:
    state = json.load(f)
state['status'] = 'stopped'
state['stopped_by'] = 'manual'
state['last_updated'] = '$(now_iso)'
state['pid'] = None
with open('$RUN_STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2, ensure_ascii=False)
"

log_ok "run_state.json 업데이트 완료"

# ─────────────────────────────────────────────
# Step 5: 비용 요약 출력
# ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}── Cost Summary ──────────────────────────────────${NC}"

if [ -f "$COST_LEDGER_FILE" ]; then
    python3 -c "
import json

with open('$COST_LEDGER_FILE') as f:
    ledger = json.load(f)

total = ledger.get('total_cost_usd', 0.0)
budget = ledger.get('hourly_budget_usd', ledger.get('budget_limit_usd', 20.0))
entries = ledger.get('entries', [])
debates = ledger.get('debates', [])
run_count = len(entries) if isinstance(entries, list) and entries else len(debates)
remaining = budget - total
usage_pct = (total / budget * 100) if budget > 0 else 0

print(f'  Total cost:     \${total:.2f}')
print(f'  Hourly budget:  \${budget:.2f}')
print(f'  Remaining:      \${remaining:.2f} ({100-usage_pct:.1f}%)')
print(f'  Runs logged:    {run_count}')

if entries:
    last = entries[-1]
    print('  Last run:       {} ({})'.format(last.get('tool', 'unknown'), last.get('task_id', 'n/a')))
elif debates:
    last = debates[-1]
    last_id = last.get('debate_id', 'unknown')
    last_cost = sum(e.get('epoch_cost', 0) for e in last.get('epochs', []))
    print(f'  Last debate:    {last_id} (\${last_cost:.2f})')
"
else
    echo -e "  ${DIM}비용 데이터 없음 (cost_ledger.json 미발견)${NC}"
fi

echo -e "${CYAN}──────────────────────────────────────────────────${NC}"

# ─────────────────────────────────────────────
# Step 6: Slack 알림
# ─────────────────────────────────────────────
log_info "Slack 알림 전송 중..."

SLACK_WEBHOOK="${SLACK_WEBHOOK_URL:-}"

if [ -n "$SLACK_WEBHOOK" ]; then
    # 비용 정보 가져오기
    COST_INFO=""
    if [ -f "$COST_LEDGER_FILE" ]; then
        COST_INFO=$(python3 -c "
import json
with open('$COST_LEDGER_FILE') as f:
    ledger = json.load(f)
total = ledger.get('total_cost_usd', 0)
print(f'Total cost: \${total:.2f}')
" 2>/dev/null || echo "N/A")
    fi

    HOSTNAME=$(hostname)
    STOP_MSG="{\"text\": \":octagonal_sign: *OpenClaw Multi-Agent System Stopped*\n\`Host:\` ${HOSTNAME}\n\`Time:\` $(now_iso)\n\`Stopped by:\` manual\n\`${COST_INFO}\`\"}"

    if curl -s -X POST -H 'Content-type: application/json' \
        --data "$STOP_MSG" \
        "$SLACK_WEBHOOK" > /dev/null 2>&1; then
        log_ok "Slack 알림 전송 완료"
    else
        log_warn "Slack 알림 전송 실패"
    fi
else
    log_warn "Slack webhook URL 미설정 — 알림 건너뜀"
fi

# ─────────────────────────────────────────────
# 정지 완료 메시지
# ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}${RED}════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${RED}  OpenClaw Multi-Agent System - STOPPED${NC}"
echo -e "${BOLD}${RED}════════════════════════════════════════════════════${NC}"
echo -e "  ${CYAN}Stopped at:${NC}  $(now_iso)"
echo -e "  ${CYAN}Stopped by:${NC}  manual"
echo -e "${BOLD}${RED}════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  다시 시작하려면: ${CYAN}./scripts/start.sh${NC}"
echo ""
