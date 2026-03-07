#!/bin/bash
#
# status.sh - OpenClaw Multi-Agent System 상태 확인
#
# 1. run_state.json 읽기
# 2. backlog.json (대기/진행 중 작업 수)
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
BACKLOG_FILE="$STATE_DIR/backlog.json"
DECISION_LOG_FILE="$STATE_DIR/decision_log.md"
DEBATE_HASHES_FILE="$STATE_DIR/debate_hashes.json"
OPENCLAW_PROFILE="${OPENCLAW_PROFILE:-openclaw-multi-agent}"
OPENCLAW_CMD=(openclaw --profile "$OPENCLAW_PROFILE")

# ─────────────────────────────────────────────
# 색상 정의
# ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

# ─────────────────────────────────────────────
# 상태별 색상 함수
# ─────────────────────────────────────────────
status_color() {
    case "$1" in
        running)  echo -e "${GREEN}${BOLD}● RUNNING${NC}" ;;
        stopping) echo -e "${YELLOW}${BOLD}◐ STOPPING${NC}" ;;
        paused)   echo -e "${YELLOW}${BOLD}◑ PAUSED${NC}" ;;
        stopped)  echo -e "${RED}${BOLD}○ STOPPED${NC}" ;;
        error)    echo -e "${RED}${BOLD}✖ ERROR${NC}" ;;
        *)        echo -e "${DIM}? UNKNOWN${NC}" ;;
    esac
}

# ─────────────────────────────────────────────
# 헤더
# ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║       OpenClaw Multi-Agent System — Status Dashboard    ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# ─────────────────────────────────────────────
# Section 1: 시스템 상태
# ─────────────────────────────────────────────
echo -e "${BOLD}${BLUE}┌─ System State ──────────────────────────────────────────┐${NC}"

if [ -f "$RUN_STATE_FILE" ]; then
    export RUN_STATE_FILE
    python3 << 'PYEOF'
import json, os, sys
from datetime import datetime, timezone

# 색상 코드
GREEN = "\033[0;32m"
RED = "\033[0;31m"
YELLOW = "\033[1;33m"
CYAN = "\033[0;36m"
DIM = "\033[2m"
NC = "\033[0m"
BOLD = "\033[1m"

state_file = os.environ["RUN_STATE_FILE"]

with open(state_file) as f:
    state = json.load(f)

status = state.get("status", "unknown")
started_by = state.get("started_by") or "N/A"
stopped_by = state.get("stopped_by") or "N/A"
last_updated = state.get("last_updated", "N/A")
total_cycles = state.get("total_cycles", 0)
current_task = state.get("current_task") or "없음"
pid = state.get("pid") or "N/A"

# 상태 색상
if status == "running":
    status_display = f"{GREEN}{BOLD}● RUNNING{NC}"
elif status == "stopping":
    status_display = f"{YELLOW}{BOLD}◐ STOPPING{NC}"
elif status == "paused":
    status_display = f"{YELLOW}{BOLD}◑ PAUSED{NC}"
elif status == "stopped":
    status_display = f"{RED}{BOLD}○ STOPPED{NC}"
else:
    status_display = f"{DIM}? UNKNOWN{NC}"

# PID 활성 확인
pid_alive = False
if pid and pid != "N/A":
    try:
        os.kill(int(pid), 0)
        pid_alive = True
    except (ProcessLookupError, ValueError, PermissionError):
        pid_alive = False

pid_status = f"{GREEN}alive{NC}" if pid_alive else f"{DIM}inactive{NC}"

# 가동 시간 계산
uptime_str = "N/A"
if last_updated != "N/A" and status == "running":
    try:
        started = datetime.fromisoformat(last_updated.replace("Z", "+00:00"))
        now = datetime.now(timezone.utc)
        delta = now - started
        hours, remainder = divmod(int(delta.total_seconds()), 3600)
        minutes, seconds = divmod(remainder, 60)
        if hours > 0:
            uptime_str = f"{hours}h {minutes}m {seconds}s"
        elif minutes > 0:
            uptime_str = f"{minutes}m {seconds}s"
        else:
            uptime_str = f"{seconds}s"
    except:
        uptime_str = "N/A"

print(f"  {CYAN}Status:{NC}        {status_display}")
print(f"  {CYAN}PID:{NC}           {pid} ({pid_status})")
print(f"  {CYAN}Started by:{NC}    {started_by}")
print(f"  {CYAN}Last updated:{NC}  {last_updated}")
print(f"  {CYAN}Uptime:{NC}        {uptime_str}")
print(f"  {CYAN}Total cycles:{NC}  {total_cycles}")
print(f"  {CYAN}Current task:{NC}  {current_task}")
PYEOF
else
    echo -e "  ${DIM}run_state.json을 찾을 수 없습니다.${NC}"
    echo -e "  ${DIM}시스템이 시작된 적이 없습니다. ./scripts/start.sh를 실행하세요.${NC}"
fi

echo -e "${BLUE}└─────────────────────────────────────────────────────────┘${NC}"
echo ""

# ─────────────────────────────────────────────
# Section 2: 작업 백로그
# ─────────────────────────────────────────────
echo -e "${BOLD}${MAGENTA}┌─ Task Backlog ──────────────────────────────────────────┐${NC}"

if [ -f "$BACKLOG_FILE" ]; then
    python3 -c "
import json

CYAN = '\033[0;36m'
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
RED = '\033[0;31m'
DIM = '\033[2m'
NC = '\033[0m'

with open('$BACKLOG_FILE') as f:
    backlog = json.load(f)

tasks = backlog.get('tasks')

if isinstance(tasks, list):
    pending = sum(1 for t in tasks if t.get('status') == 'pending')
    in_progress = sum(1 for t in tasks if t.get('status') in ('in_progress', 'debating', 'implementing', 'verifying'))
    completed = sum(1 for t in tasks if t.get('status') == 'completed')
    failed = sum(1 for t in tasks if t.get('status') in ('failed', 'blocked'))
    total = len(tasks)
else:
    pending = len(backlog.get('pending', []))
    in_progress = len(backlog.get('in_progress', []))
    completed = len(backlog.get('completed', []))
    failed = len(backlog.get('failed', []))
    total = pending + in_progress + completed + failed

print(f'  {CYAN}Pending:{NC}       {YELLOW}{pending}{NC}')
print(f'  {CYAN}In Progress:{NC}   {GREEN}{in_progress}{NC}')
print(f'  {CYAN}Completed:{NC}     {GREEN}{completed}{NC}')
print(f'  {CYAN}Failed:{NC}        {RED}{failed}{NC}')
print(f'  {CYAN}Total:{NC}         {total}')

# 진행 중인 작업 세부 정보
if isinstance(tasks, list):
    active = [t for t in tasks if t.get('status') in ('in_progress', 'debating', 'implementing', 'verifying')]
    for task in active[:3]:
        title = task.get('title', task.get('id', 'unnamed'))
        status = task.get('status', 'unknown')
        print(f'  {CYAN}→ Active:{NC}      {title} ({status})')
else:
    for task in backlog.get('in_progress', []):
        if isinstance(task, dict):
            name = task.get('name', task.get('task', 'unnamed'))
            print(f'  {CYAN}→ Active:{NC}      {name}')
        elif isinstance(task, str):
            print(f'  {CYAN}→ Active:{NC}      {task}')
" 2>/dev/null || echo -e "  ${DIM}backlog.json 읽기 실패${NC}"
else
    echo -e "  ${DIM}백로그 없음 (backlog.json 미발견)${NC}"
fi

echo -e "${MAGENTA}└─────────────────────────────────────────────────────────┘${NC}"
echo ""

echo -e "${BOLD}${GREEN}┌─ Agent Sessions ────────────────────────────────────────┐${NC}"

if command -v openclaw &> /dev/null; then
    if SESSIONS=$("${OPENCLAW_CMD[@]}" sessions list 2>/dev/null); then
        :
    elif SESSIONS=$("${OPENCLAW_CMD[@]}" sessions_list 2>/dev/null); then
        :
    else
        SESSIONS=""
    fi
    if [ -n "$SESSIONS" ]; then
        echo -e "  ${CYAN}Active sessions:${NC}"
        echo "$SESSIONS" | while IFS= read -r line; do
            if [ -n "$line" ]; then
                echo -e "    ${GREEN}●${NC} $line"
            fi
        done
    else
        echo -e "  ${DIM}활성 세션 없음${NC}"
    fi
else
    echo -e "  ${DIM}openclaw CLI 미설치 — 세션 정보를 가져올 수 없습니다${NC}"
fi

# 에이전트 역할 목록
echo ""
echo -e "  ${CYAN}Configured agents:${NC}"
AGENTS=("orchestrator:Orchestrator — 토론 조율 및 최종 결정"
        "planner:Planner — 계획 수립 및 접근법 제안"
        "critic:Critic — 비판적 분석 및 대안 제시"
        "implementer:Implementer — 코드 구현"
        "verifier:Verifier — 구현 검증 및 품질 확인")

for agent_info in "${AGENTS[@]}"; do
    IFS=':' read -r agent_name agent_desc <<< "$agent_info"
    if command -v openclaw &> /dev/null && "${OPENCLAW_CMD[@]}" agents list 2>/dev/null | grep -q "$agent_name"; then
        echo -e "    ${GREEN}●${NC} ${agent_desc}"
    else
        echo -e "    ${DIM}○${NC} ${DIM}${agent_desc}${NC}"
    fi
done

echo -e "${GREEN}└─────────────────────────────────────────────────────────┘${NC}"
echo ""

echo -e "${BOLD}${CYAN}┌─ Recent Decisions ──────────────────────────────────────┐${NC}"

if [ -f "$DECISION_LOG_FILE" ]; then
    # 마지막 5줄의 의미 있는 내용 표시
    RECENT=$(python3 -c "
lines = []
with open('$DECISION_LOG_FILE') as f:
    for line in f:
        line = line.strip()
        if line and not line.startswith('#') and line != '---':
            lines.append(line)

# 마지막 8줄
for line in lines[-8:]:
    print(f'  {line}')

if not lines:
    print('  (기록 없음)')
" 2>/dev/null)
    echo "$RECENT"
else
    echo -e "  ${DIM}토론 기록 없음 (decision_log.md 미발견)${NC}"
fi

echo -e "${CYAN}└─────────────────────────────────────────────────────────┘${NC}"
echo ""

# ─────────────────────────────────────────────
# 안티루프 상태
# ─────────────────────────────────────────────
if [ -f "$DEBATE_HASHES_FILE" ]; then
    HASH_COUNT=$(python3 -c "
import json
with open('$DEBATE_HASHES_FILE') as f:
    data = json.load(f)
print(len(data.get('hashes', [])))
" 2>/dev/null || echo "0")
    if [ "$HASH_COUNT" -gt 0 ]; then
        echo -e "  ${DIM}Anti-loop hashes tracked: ${HASH_COUNT}${NC}"
    fi
fi

# ─────────────────────────────────────────────
# 푸터
# ─────────────────────────────────────────────
echo -e "${DIM}──────────────────────────────────────────────────────────${NC}"
echo -e "  ${DIM}Refreshed at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")${NC}"
echo -e "  ${DIM}Profile:      $OPENCLAW_PROFILE${NC}"
echo -e "  ${DIM}State dir:    $STATE_DIR${NC}"
echo ""
