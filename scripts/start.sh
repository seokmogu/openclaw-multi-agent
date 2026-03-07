#!/bin/bash
#
# start.sh - OpenClaw Multi-Agent System 시작
#
# 1. OpenClaw 설치 확인
# 2. run_state.json을 "running"으로 설정
# 3. openclaw.json에서 cron heartbeat 활성화
# 4. OpenClaw gateway 시작/재시작
# 5. Slack으로 "System started" 전송
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
OPENCLAW_PROFILE="${OPENCLAW_PROFILE:-openclaw-multi-agent}"
OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-$(python3 -c "import zlib; s='${OPENCLAW_PROFILE}'; print(19000 + (zlib.crc32(s.encode()) % 2000))")}" 
PROFILE_SAFE="$(printf "%s" "$OPENCLAW_PROFILE" | tr -c '[:alnum:]_.-' '_')"

# ─────────────────────────────────────────────
# 색상 정의
# ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

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
# Step 1: OpenClaw 설치 확인
# ─────────────────────────────────────────────
log_info "OpenClaw 설치 확인 중..."

if ! command -v openclaw &> /dev/null; then
    log_error "openclaw 명령어를 찾을 수 없습니다."
    log_error "OpenClaw를 먼저 설치하세요: https://openclaw.dev/install"
    exit 1
fi

OPENCLAW_VERSION=$(openclaw --version 2>/dev/null || echo "unknown")
log_ok "OpenClaw 발견: $OPENCLAW_VERSION"
OPENCLAW_CMD=(openclaw --profile "$OPENCLAW_PROFILE")
log_info "OpenClaw profile: $OPENCLAW_PROFILE"
log_info "OpenClaw gateway port: $OPENCLAW_GATEWAY_PORT"

ensure_agent_registered() {
    local agent_id="$1"
    local workspace_dir="$2"
    local agent_dir="$3"
    local model_id="$4"

    if "${OPENCLAW_CMD[@]}" agents list 2>/dev/null | grep -Eq -- "^- ${agent_id}( |$)"; then
        return 0
    fi

    log_info "프로파일에 에이전트 등록: ${agent_id}"
    "${OPENCLAW_CMD[@]}" agents add "$agent_id" \
        --workspace "$workspace_dir" \
        --agent-dir "$agent_dir" \
        --model "$model_id" \
        --non-interactive >/dev/null 2>&1 || {
        log_warn "에이전트 등록 실패: ${agent_id}"
        return 1
    }
    return 0
}

# CLI 도구 확인 (경고만, 실패하지 않음)
for tool in opencode claude codex gemini; do
    if command -v "$tool" &> /dev/null; then
        log_ok "CLI 도구 발견: $tool"
    else
        log_warn "CLI 도구 미설치: $tool (일부 에이전트 기능이 제한될 수 있습니다)"
    fi
done

# 프로파일별 에이전트 부트스트랩
log_info "프로파일 에이전트 등록 상태 확인 중..."
ensure_agent_registered "orchestrator" "$PROJECT_DIR/workspaces/orchestrator" "$PROJECT_DIR/agents/orchestrator" "claude-opus-4-6" || true
ensure_agent_registered "planner" "$PROJECT_DIR/workspaces/planner" "$PROJECT_DIR/agents/planner" "claude-opus-4-6" || true
ensure_agent_registered "implementer" "$PROJECT_DIR/workspaces/implementer" "$PROJECT_DIR/agents/implementer" "claude-opus-4-6" || true
ensure_agent_registered "critic" "$PROJECT_DIR/workspaces/critic" "$PROJECT_DIR/agents/critic" "claude-opus-4-6" || true
ensure_agent_registered "verifier" "$PROJECT_DIR/workspaces/verifier" "$PROJECT_DIR/agents/verifier" "claude-opus-4-6" || true

# 프로파일별 gateway 포트 고정 (프로파일 간 충돌 방지)
"${OPENCLAW_CMD[@]}" config set gateway.port "$OPENCLAW_GATEWAY_PORT" >/dev/null 2>&1 || true
"${OPENCLAW_CMD[@]}" config set gateway.bind loopback >/dev/null 2>&1 || true

# ─────────────────────────────────────────────
# Step 2: 상태 디렉토리 및 파일 초기화
# ─────────────────────────────────────────────
log_info "상태 디렉토리 확인 중..."

mkdir -p "$STATE_DIR"

# run_state.json이 없으면 초기 생성
if [ ! -f "$RUN_STATE_FILE" ]; then
    log_info "run_state.json 초기 생성..."
    cat > "$RUN_STATE_FILE" << EOF
{
  "status": "stopped",
  "started_by": null,
  "stopped_by": null,
  "last_updated": "$(now_iso)",
  "total_cycles": 0,
  "current_task": null,
  "pid": null
}
EOF
fi

# decision_log.md 초기화 (없으면)
if [ ! -f "$STATE_DIR/decision_log.md" ]; then
    cat > "$STATE_DIR/decision_log.md" << EOF
# Decision Log

토론 결과 및 의사결정 기록.

---
EOF
fi

# debate_hashes.json 초기화 (없으면)
if [ ! -f "$STATE_DIR/debate_hashes.json" ]; then
    echo '{"hashes": []}' > "$STATE_DIR/debate_hashes.json"
fi

# backlog.json 초기화 (없으면)
if [ ! -f "$STATE_DIR/backlog.json" ]; then
    cat > "$STATE_DIR/backlog.json" << EOF
{
  "tasks": []
}
EOF
fi

log_ok "상태 파일 준비 완료"

# ─────────────────────────────────────────────
# Step 2: 이미 실행 중인지 확인
# ─────────────────────────────────────────────
CURRENT_STATUS=$(python3 -c "
import json, sys
try:
    with open('$RUN_STATE_FILE') as f:
        print(json.load(f).get('status', 'unknown'))
except:
    print('unknown')
" 2>/dev/null || echo "unknown")

if [ "$CURRENT_STATUS" = "running" ]; then
    log_warn "시스템이 이미 실행 중입니다."
    log_info "자동으로 재시작 절차를 진행합니다."
fi

# ─────────────────────────────────────────────
# Step 3: run_state.json을 "running"으로 업데이트
# ─────────────────────────────────────────────
log_info "시스템 상태를 'running'으로 설정 중..."

python3 -c "
import json
with open('$RUN_STATE_FILE', 'r') as f:
    state = json.load(f)
state['status'] = 'running'
state['started_by'] = 'manual'
state['stopped_by'] = None
state['last_updated'] = '$(now_iso)'
state['pid'] = None
with open('$RUN_STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2, ensure_ascii=False)
"

log_ok "run_state.json 업데이트 완료"

# ─────────────────────────────────────────────
# Step 4: openclaw.json에서 cron heartbeat 활성화
# ─────────────────────────────────────────────
log_info "Cron heartbeat 활성화 중..."

CRON_STATE_FILE="$STATE_DIR/cron_state.${PROFILE_SAFE}.json"

# 프로파일 gateway 준비 (크론 등록 전 선행)
if ! "${OPENCLAW_CMD[@]}" gateway health >/dev/null 2>&1; then
    "${OPENCLAW_CMD[@]}" gateway install >/dev/null 2>&1 || true
    "${OPENCLAW_CMD[@]}" gateway start --port "$OPENCLAW_GATEWAY_PORT" >/dev/null 2>&1 || true
fi

# 기존 cron job이 있으면 먼저 제거
if [ -f "$CRON_STATE_FILE" ]; then
    OLD_CRON_ID=$(python3 -c "
import json
with open('$CRON_STATE_FILE') as f:
    print(json.load(f).get('cron_job_id') or '')
" 2>/dev/null || echo "")
    if [ -n "$OLD_CRON_ID" ]; then
        log_info "기존 cron job 제거 중: $OLD_CRON_ID"
        "${OPENCLAW_CMD[@]}" cron remove "$OLD_CRON_ID" 2>/dev/null || true
    fi
fi

# 이름/agent 기준으로 중복 cron 정리
CRON_LIST=$("${OPENCLAW_CMD[@]}" cron list --json 2>/dev/null || echo "[]")
CRON_IDS=$(echo "$CRON_LIST" | python3 -c "
import json, sys
try:
    jobs = json.load(sys.stdin)
    if isinstance(jobs, list):
        for j in jobs:
            if 'orchestrat' in (j.get('name') or '').lower() or (j.get('agentId') or '') == 'orchestrator':
                print(j.get('id') or '')
except Exception:
    pass
" 2>/dev/null)

if [ -n "$CRON_IDS" ]; then
    while IFS= read -r cron_id; do
        if [ -n "$cron_id" ]; then
            log_info "기존 cron job 정리: $cron_id"
            "${OPENCLAW_CMD[@]}" cron remove "$cron_id" 2>/dev/null || "${OPENCLAW_CMD[@]}" cron disable "$cron_id" 2>/dev/null || true
        fi
    done <<< "$CRON_IDS"
fi

# 새 cron job 등록 및 ID 캡처
CRON_OUTPUT=$("${OPENCLAW_CMD[@]}" cron add \
    --name "orchestration-heartbeat" \
    --every "2m" \
    --agent orchestrator \
    --message "Read HEARTBEAT.md and follow the orchestration cycle instructions. Check run_state.json first — if stopped or paused, reply HEARTBEAT_OK." \
    --timeout-seconds 120 \
    --no-deliver \
    2>&1) && CRON_ADD_OK=true || CRON_ADD_OK=false

if [ "$CRON_ADD_OK" = false ]; then
    log_warn "첫 cron 등록 실패. gateway 준비 후 1회 재시도합니다..."
    "${OPENCLAW_CMD[@]}" gateway restart --port "$OPENCLAW_GATEWAY_PORT" >/dev/null 2>&1 || "${OPENCLAW_CMD[@]}" gateway start --port "$OPENCLAW_GATEWAY_PORT" >/dev/null 2>&1 || true
    CRON_OUTPUT=$("${OPENCLAW_CMD[@]}" cron add \
        --name "orchestration-heartbeat" \
        --every "2m" \
        --agent orchestrator \
        --message "Read HEARTBEAT.md and follow the orchestration cycle instructions. Check run_state.json first — if stopped or paused, reply HEARTBEAT_OK." \
        --timeout-seconds 120 \
        --no-deliver \
        2>&1) && CRON_ADD_OK=true || CRON_ADD_OK=false
fi

if [ "$CRON_ADD_OK" = true ]; then
    log_ok "Cron heartbeat 등록 완료 (매 2분)"

    # cron job ID 추출 및 저장
    CRON_JOB_ID=$(echo "$CRON_OUTPUT" | python3 -c "
import sys, re, json
text = sys.stdin.read()
# Try JSON parse first
try:
    data = json.loads(text)
    cid = data.get('id') or data.get('cronId') or data.get('cron_id') or ''
    if cid:
        print(cid)
        sys.exit(0)
except: pass
# Fallback: extract UUID-like pattern
m = re.search(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', text, re.IGNORECASE)
if m:
    print(m.group(0))
else:
    # Try any alphanumeric ID after common keywords
    m = re.search(r'(?:id|ID|Id)[:\s]+([A-Za-z0-9_-]+)', text)
    if m:
        print(m.group(1))
    else:
        print('')
" 2>/dev/null || echo "")

    # ID를 못 찾으면 cron list에서 최신 orchestrator job 찾기
    if [ -z "$CRON_JOB_ID" ]; then
        CRON_JOB_ID=$("${OPENCLAW_CMD[@]}" cron list --json 2>/dev/null | python3 -c "
import json, sys
try:
    jobs = json.load(sys.stdin)
    if isinstance(jobs, list):
        for j in jobs:
            if 'orchestrat' in j.get('name', '').lower() or j.get('agentId') == 'orchestrator':
                print(j.get('id', ''))
                sys.exit(0)
except: pass
print('')
" 2>/dev/null || echo "")
    fi

    # cron_state.json에 저장
    python3 -c "
import json
state = {
    'cron_job_id': '${CRON_JOB_ID}' if '${CRON_JOB_ID}' else None,
    'cron_name': 'orchestration-heartbeat',
    'agent_id': 'orchestrator',
    'interval': '2m',
    'enabled': True,
    'last_registered': '$(now_iso)',
    'last_disabled': None
}
with open('$CRON_STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
"
    if [ -n "$CRON_JOB_ID" ]; then
        log_ok "Cron job ID 저장: $CRON_JOB_ID"
    else
        log_warn "Cron job ID를 추출할 수 없었습니다. stop.sh에서 이름 기반으로 검색합니다."
    fi
else
    log_warn "Cron heartbeat 등록 실패. 수동으로 openclaw cron add 를 실행하세요."
fi

# ─────────────────────────────────────────────
# Step 5: OpenClaw gateway 시작/재시작
# ─────────────────────────────────────────────
log_info "OpenClaw gateway 시작 중..."

if "${OPENCLAW_CMD[@]}" gateway restart --port "$OPENCLAW_GATEWAY_PORT" 2>/dev/null; then
    log_ok "OpenClaw gateway 재시작 완료"
else
    log_warn "OpenClaw gateway 재시작 실패. 새로 시작을 시도합니다..."
    if "${OPENCLAW_CMD[@]}" gateway start --port "$OPENCLAW_GATEWAY_PORT" 2>/dev/null; then
        log_ok "OpenClaw gateway 시작 완료"
    else
        log_error "OpenClaw gateway를 시작할 수 없습니다."
        log_error "수동으로 'openclaw --profile ${OPENCLAW_PROFILE} gateway start'를 실행해 보세요."
        # 상태를 에러로 되돌리지는 않음 — gateway 없이도 일부 기능 가능
        log_warn "gateway 없이 계속합니다."
    fi
fi

# ─────────────────────────────────────────────
# Step 6: Slack 알림
# ─────────────────────────────────────────────
log_info "Slack 알림 전송 중..."

SLACK_WEBHOOK="${SLACK_WEBHOOK_URL:-}"

if [ -n "$SLACK_WEBHOOK" ]; then
    HOSTNAME=$(hostname)
    START_MSG="{\"text\": \":rocket: *OpenClaw Multi-Agent System Started*\n\`Host:\` ${HOSTNAME}\n\`Time:\` $(now_iso)\n\`Started by:\` manual\n\`PID:\` $$\"}"

    if curl -s -X POST -H 'Content-type: application/json' \
        --data "$START_MSG" \
        "$SLACK_WEBHOOK" > /dev/null 2>&1; then
        log_ok "Slack 알림 전송 완료"
    else
        log_warn "Slack 알림 전송 실패 (시스템은 계속 실행됩니다)"
    fi
else
    log_warn "Slack webhook URL이 설정되지 않았습니다."
    log_warn "openclaw.json의 slack.webhook_url을 설정하세요."
fi

# ─────────────────────────────────────────────
# 시작 완료 메시지
# ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  OpenClaw Multi-Agent System - STARTED${NC}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
echo -e "  ${CYAN}Status:${NC}      running"
echo -e "  ${CYAN}PID:${NC}         $$"
echo -e "  ${CYAN}Started at:${NC}  $(now_iso)"
echo -e "  ${CYAN}State dir:${NC}   $STATE_DIR"
echo -e "  ${CYAN}Profile:${NC}     $OPENCLAW_PROFILE"
echo -e "  ${CYAN}Config:${NC}      $CONFIG_FILE"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Slack에서 작업을 전송하거나"
echo -e "  ${CYAN}./scripts/status.sh${NC} 로 상태를 확인하세요."
echo -e "  ${CYAN}./scripts/stop.sh${NC} 로 시스템을 중지할 수 있습니다."
echo ""
