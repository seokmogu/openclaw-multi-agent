# OpenClaw Multi-Agent Collaborative Problem Solver

여러 AI 에이전트가 토론과 협업을 통해 코딩 문제를 해결하는 멀티 에이전트 시스템.

## 개요

OpenClaw Multi-Agent는 5개의 전문 AI 에이전트(Orchestrator, Planner, Implementer, Critic, Verifier)가 구조화된 토론 프로토콜을 통해 협력하여 복잡한 코딩 문제를 해결합니다. 각 에이전트는 OpenCode, Claude Code, Codex CLI, Gemini CLI 등의 도구를 활용하며, 무한 루프로 작업을 처리하고 결과를 Slack으로 보고합니다.

### 핵심 특징

- **구조화된 토론**: propose → challenge → revise → decide 사이클로 의사결정 품질 보장
- **에포크 기반 세션 관리**: OpenClaw의 5-turn 제한을 우회하는 에포크 시스템
- **수렴 감지**: 에이전트 간 합의를 자동으로 감지하여 불필요한 토론 방지
- **안티 루프 보호**: 해시 기반 루프 감지 및 자동 타이브레이크
- **비용 관리**: 토론별/전체 예산 캡 및 실시간 비용 추적
- **Slack 통합**: 작업 수신, 진행 보고, 결과 알림 자동화

## 아키텍처

```
                            ┌─────────────────────────────────────────┐
                            │          OpenClaw Gateway               │
                            └──────────────┬──────────────────────────┘
                                           │
┌──────────┐                ┌──────────────▼──────────────────────────┐
│          │   Slack 작업   │                                         │
│   User   │ ──────────────►│           Orchestrator                  │
│ (Slack)  │                │    (debate-orchestrator 스킬 로드)       │
│          │◄───────────────│                                         │
│          │   결과 보고    └──┬───────────────────────────────────┬──┘
└──────────┘                   │                                   │
                               │ propose/revise                    │ challenge
                               ▼                                   ▼
                   ┌───────────────────┐           ┌───────────────────────┐
                   │                   │           │                       │
                   │     Planner       │◄─────────►│       Critic          │
                   │                   │  토론     │                       │
                   └─────────┬─────────┘           └───────────────────────┘
                             │
                             │ 구현 지시
                             ▼
                   ┌───────────────────┐
                   │                   │
                   │   Implementer     │
                   │                   │
                   └─────────┬─────────┘
                             │
                             │ 구현 결과
                             ▼
                   ┌───────────────────┐
                   │                   │
                   │    Verifier       │──── 실패 시 ────► Orchestrator (재시도)
                   │                   │
                   └─────────┬─────────┘
                             │
                             │ 검증 통과
                             ▼
                      ┌──────────────┐
                      │  Slack 보고  │
                      └──────────────┘
```

### 간략 흐름도

```
User (Slack) → Orchestrator → [Planner ↔ Critic] → Implementer → Verifier → Report
                    ↑                                                    │
                    └────────────────── retry if fail ────────────────────┘
```

## 사전 요구 사항

### 필수

| 항목 | 설명 | 설치 방법 |
|------|------|----------|
| **OpenClaw** | 멀티 에이전트 오케스트레이션 프레임워크 | [openclaw.dev/install](https://openclaw.dev/install) |
| **Python 3.8+** | 상태 관리 스크립트 실행 | macOS 기본 설치 또는 `brew install python` |
| **curl** | Slack 알림 전송 | macOS 기본 설치 |
| **jq** (선택) | JSON 파일 수동 조회 시 유용 | `brew install jq` |

### CLI 도구 (하나 이상 필수)

| 도구 | 역할 | 설치 방법 |
|------|------|----------|
| **OpenCode** | 코드 편집, 분석, 디버깅 | [opencode.dev](https://opencode.dev) |
| **Claude Code** | 코드 생성, 리팩토링, 설명 | `npm install -g @anthropic-ai/claude-code` |
| **Codex CLI** | 코드 생성, 검증, 테스트 | `npm install -g @openai/codex` |
| **Gemini CLI** | 디자인 리뷰, 문서 작성 | `npm install -g @google/gemini-cli` |

### Slack 설정

1. [Slack App](https://api.slack.com/apps) 생성
2. Bot Token Scopes 추가: `chat:write`, `channels:read`, `channels:history`
3. Incoming Webhook URL 생성
4. Bot Token과 Webhook URL을 `openclaw.json`에 설정

## 빠른 시작

### 1. 프로젝트 복사

```bash
git clone <repository-url> openclaw-multi-agent
cd openclaw-multi-agent
```

### 2. Slack 설정

`openclaw.json`을 편집하여 Slack 봇 토큰과 Webhook URL을 설정합니다:

```bash
# openclaw.json에서 slack 섹션 수정
{
  "slack": {
    "bot_token": "xoxb-your-bot-token-here",
    "webhook_url": "https://hooks.slack.com/services/YOUR/WEBHOOK/URL",
    "channel": "#openclaw-agent"
  }
}
```

### 3. 에이전트 등록

```bash
openclaw agents add orchestrator \
  --skill ./skills/debate-orchestrator/SKILL.md \
  --model claude-sonnet-4-6

openclaw agents add planner \
  --tools opencode,claude \
  --model claude-sonnet-4-6

openclaw agents add critic \
  --tools opencode,codex \
  --model claude-sonnet-4-6

openclaw agents add implementer \
  --tools opencode,claude,codex \
  --model claude-sonnet-4-6

openclaw agents add verifier \
  --tools opencode,codex \
  --model claude-sonnet-4-6
```

### 4. 시스템 시작

```bash
./scripts/start.sh
```

여러 OpenClaw 프로젝트를 같은 유저에서 동시에 운영할 때는 프로파일을 분리해서 충돌을 방지합니다:

```bash
OPENCLAW_PROFILE=openclaw-multi-agent ./scripts/start.sh
OPENCLAW_PROFILE=openclaw-multi-agent ./scripts/status.sh
OPENCLAW_PROFILE=openclaw-multi-agent ./scripts/stop.sh
```

기본값은 `openclaw-multi-agent`이며, 내부적으로 `openclaw --profile <name>`을 사용해 `~/.openclaw-<name>` 경로로 격리됩니다.

### 5. Slack에서 작업 전송

Slack 채널에서 봇에게 메시지를 보냅니다:

```
@openclaw REST API에 JWT 기반 사용자 인증 기능을 구현해줘.
요구사항:
- Node.js/Express 환경
- PostgreSQL 사용
- refresh token rotation 적용
- 모바일 앱 지원
```

### 6. 에이전트 토론 관찰

```bash
# 실시간 상태 확인
./scripts/status.sh

# 토론 로그 확인
cat state/decision_log.md

# 비용 확인
cat state/cost_ledger.json | python3 -m json.tool
```

### 7. 시스템 중지

```bash
./scripts/stop.sh
```

## 설정 파일 (openclaw.json)

```json
{
  "version": "1.0",
  "project": "openclaw-multi-agent",

  "slack": {
    "bot_token": "xoxb-your-bot-token",
    "webhook_url": "https://hooks.slack.com/services/XXX/YYY/ZZZ",
    "channel": "#openclaw-agent",
    "notify_on": ["task_start", "task_complete", "task_fail", "system_start", "system_stop"]
  },

  "cron": {
    "enabled": true,
    "interval_seconds": 30,
    "heartbeat": true
  },

  "debate": {
    "max_epochs": 3,
    "max_cost_per_debate_usd": 5.00,
    "convergence_threshold": 0.7,
    "epoch_summary_max_tokens": 500,
    "anti_loop_enabled": true,
    "tiebreak_strategy": "lowest_risk"
  },

  "budget": {
    "daily_limit_usd": 50.00,
    "monthly_limit_usd": 500.00,
    "alert_threshold_pct": 80
  },

  "agents": {
    "orchestrator": {
      "model": "claude-sonnet-4-6",
      "skills": ["debate-orchestrator"],
      "max_concurrent_sessions": 1
    },
    "planner": {
      "model": "claude-sonnet-4-6",
      "tools": ["opencode", "claude"],
      "max_concurrent_sessions": 2
    },
    "critic": {
      "model": "claude-sonnet-4-6",
      "tools": ["opencode", "codex"],
      "max_concurrent_sessions": 2
    },
    "implementer": {
      "model": "claude-sonnet-4-6",
      "tools": ["opencode", "claude", "codex"],
      "max_concurrent_sessions": 1
    },
    "verifier": {
      "model": "claude-sonnet-4-6",
      "tools": ["opencode", "codex"],
      "max_concurrent_sessions": 1
    }
  },

  "gateway": {
    "port": 8080,
    "host": "localhost"
  }
}
```

### 주요 설정 항목

| 섹션 | 항목 | 설명 |
|------|------|------|
| `slack` | `bot_token` | Slack Bot OAuth Token |
| `slack` | `webhook_url` | Incoming Webhook URL |
| `slack` | `notify_on` | 알림 트리거 이벤트 목록 |
| `cron` | `interval_seconds` | heartbeat 주기 (초) |
| `debate` | `max_epochs` | 토론 최대 에포크 수 |
| `debate` | `max_cost_per_debate_usd` | 토론당 비용 상한 |
| `debate` | `convergence_threshold` | Verifier 수렴 판정 기준 |
| `debate` | `tiebreak_strategy` | 타이브레이크 전략 |
| `budget` | `daily_limit_usd` | 일일 비용 상한 |

## 에이전트 역할

### Orchestrator (오케스트레이터)

전체 시스템의 지휘자. 토론을 관리하고 최종 결정을 내린다.

- **역할**: 작업 수신, 에이전트 간 토론 조율, 수렴 판정, 타이브레이크
- **스킬**: `debate-orchestrator` (이 프로젝트의 핵심 스킬)
- **입력**: Slack에서 받은 작업 요청
- **출력**: 구현 지시, Slack 보고

### Planner (플래너)

계획 수립 및 접근법 설계 전문가.

- **역할**: 작업 분석, 기술적 접근법 제안, Critic의 비판 반영 후 수정
- **도구**: OpenCode (코드 분석), Claude (계획 생성)
- **propose 단계**: 초기 계획을 JSON Contract 형식으로 제출
- **revise 단계**: Critic의 비판을 반영한 수정 계획 제출

### Critic (크리틱)

비판적 분석 및 품질 보증 전문가.

- **역할**: 제안의 약점 분석, 대안 제시, 리스크 평가
- **도구**: OpenCode (코드 리뷰), Codex (대안 검증)
- **challenge 단계**: 기술적 리스크, 누락 사항, 대안을 JSON Contract로 제출

### Implementer (구현자)

코드 구현 전문가.

- **역할**: 합의된 계획을 실제 코드로 구현
- **도구**: OpenCode (편집), Claude (생성), Codex (보조 생성)
- **동작**: 토론에서 수렴된 계획을 받아 실제 파일 생성/수정

### Verifier (검증자)

구현 품질 검증 전문가.

- **역할**: 구현된 코드의 정확성, 보안, 성능 검증
- **도구**: OpenCode (분석), Codex (테스트 생성)
- **동작**: 체크리스트 기반 검증 후 confidence score 반환
- **실패 시**: Orchestrator에게 재구현/수정 요청

## 토론 프로토콜

### 4단계 사이클

```
┌─────────┐     ┌───────────┐     ┌─────────┐     ┌─────────┐
│ propose │────►│ challenge │────►│ revise  │────►│ decide  │
│(Planner)│     │ (Critic)  │     │(Planner)│     │(Orch.)  │
└─────────┘     └───────────┘     └─────────┘     └────┬────┘
                                                       │
                                          ┌────────────┼────────────┐
                                          ▼            ▼            ▼
                                    [수렴: 구현]  [미수렴: 재토론]  [타이브레이크]
```

### JSON Contract

모든 에이전트는 아래 형식으로 응답합니다:

```json
{
  "claim": "핵심 주장 또는 제안 (한 문장)",
  "evidence": ["근거 1", "근거 2", "근거 3"],
  "risk": ["리스크 1", "리스크 2"],
  "next_action": "implement | revise | escalate | verify"
}
```

### 에포크 시스템

OpenClaw의 `sessions_send` 5-turn 제한을 우회하기 위해 에포크 단위로 세션을 분리합니다:

- **1 epoch** = 1 propose + 1 challenge + 1 revise = 3 `sessions_send` 호출
- 미수렴 시 요약을 `state/decision_log.md`에 저장하고 새 세션에서 다음 epoch 시작
- **최대 3 epochs** 후에도 미수렴이면 Orchestrator가 강제 결정 (타이브레이크)

### 수렴 조건

- **에이전트 합의**: 2개 이상 에이전트가 동일 접근법에 동의 (`next_action = "implement"`)
- **Verifier 확신**: Verifier의 confidence score > 0.7

## 상태 파일

`state/` 디렉토리에 시스템의 모든 상태가 저장됩니다:

| 파일 | 형식 | 설명 |
|------|------|------|
| `run_state.json` | JSON | 시스템 실행 상태 (running/stopped/paused), PID, 시작/종료 시간 |
| `backlog.json` | JSON | 작업 큐: pending, in_progress, completed, failed 목록 |
| `cost_ledger.json` | JSON | 비용 추적: 토론별/에포크별 비용, 총 비용, 예산 잔액 |
| `decision_log.md` | Markdown | 토론 기록: 각 에포크 요약, 최종 결정, 타이브레이크 기록 |
| `debate_hashes.json` | JSON | 안티 루프: 이전 토론 결정의 SHA256 해시 저장 |

### run_state.json 예시

```json
{
  "status": "running",
  "started_by": "manual",
  "stopped_by": null,
  "last_updated": "2026-03-06T10:30:00Z",
  "total_cycles": 15,
  "current_task": "REST API 인증 구현",
  "pid": 12345
}
```

### backlog.json 예시

```json
{
  "pending": [
    {"task": "결제 모듈 구현", "priority": "high", "created_at": "2026-03-06T10:00:00Z"}
  ],
  "in_progress": [
    {"task": "REST API 인증 구현", "started_at": "2026-03-06T10:30:00Z", "epoch": 2}
  ],
  "completed": [
    {"task": "DB 스키마 설계", "completed_at": "2026-03-06T09:45:00Z", "cost_usd": 2.30}
  ],
  "failed": []
}
```

## CLI 도구 활용

각 에이전트가 CLI 도구를 어떻게 사용하는지:

### OpenCode

모든 에이전트가 공통으로 사용하는 핵심 도구.

```bash
# Planner: 기존 코드 분석
opencode "src/ 디렉토리의 인증 관련 코드를 분석하고 구조를 설명해줘"

# Critic: 코드 리뷰
opencode "이 구현의 보안 취약점과 성능 문제를 찾아줘"

# Implementer: 코드 편집
opencode "JWT 미들웨어를 src/middleware/auth.js에 구현해줘"

# Verifier: 테스트 실행
opencode "모든 인증 관련 테스트를 실행하고 결과를 분석해줘"
```

### Claude Code

주로 Planner와 Implementer가 사용.

```bash
# 계획 수립
claude "다음 요구사항으로 인증 시스템 아키텍처를 설계해줘: ..."

# 코드 생성
claude "refresh token rotation을 포함한 JWT 인증 모듈을 구현해줘"
```

### Codex CLI

주로 Critic과 Verifier가 사용.

```bash
# 대안 검증
codex "이 인증 접근법의 대안을 구현하고 비교해줘"

# 테스트 생성
codex "JWT 인증 모듈에 대한 통합 테스트를 작성해줘"
```

### Gemini CLI

디자인 리뷰와 문서화에 사용.

```bash
# 아키텍처 리뷰
gemini "이 인증 시스템 아키텍처를 리뷰하고 개선점을 제안해줘"

# 문서 생성
gemini "구현된 API의 사용 문서를 작성해줘"
```

## 비용 관리

### 비용 계층 구조

```
월간 예산 ($500)
  └─ 일일 예산 ($50)
       └─ 토론당 예산 ($5)
            └─ 에포크당 비용 (~$0.50-1.50)
                 └─ sessions_send 호출당 비용 (~$0.15-0.30)
```

### 비용 모니터링

```bash
# 현재 비용 확인
./scripts/status.sh

# 상세 비용 확인
python3 -c "
import json
with open('state/cost_ledger.json') as f:
    ledger = json.load(f)
print(f'Total: \${ledger[\"total_cost_usd\"]:.2f}')
print(f'Budget: \${ledger[\"budget_limit_usd\"]:.2f}')
print(f'Remaining: \${ledger[\"budget_limit_usd\"] - ledger[\"total_cost_usd\"]:.2f}')
"
```

### 비용 초과 시 동작

1. **토론당 $5 초과**: 해당 토론 즉시 중단, 현재 best evidence로 결정
2. **일일 $50 초과**: 새 작업 수신 중단, 진행 중 작업은 완료
3. **월간 $500 초과**: 시스템 자동 일시정지, Slack으로 알림

### 예산 조정

`openclaw.json`에서 예산을 조정합니다:

```json
{
  "debate": {
    "max_cost_per_debate_usd": 10.00
  },
  "budget": {
    "daily_limit_usd": 100.00,
    "monthly_limit_usd": 1000.00
  }
}
```

## 트러블슈팅

### 시스템이 시작되지 않음

```bash
# OpenClaw 설치 확인
openclaw --version

# gateway 상태 확인
openclaw gateway status

# 설정 파일 검증
python3 -c "import json; json.load(open('openclaw.json')); print('OK')"
```

### 에이전트가 응답하지 않음

```bash
# 활성 세션 확인
openclaw sessions_list

# 특정 에이전트 상태 확인
openclaw agents status planner

# 강제 세션 종료
openclaw sessions_close <session-id>
```

### 토론이 무한 루프에 빠짐

시스템의 안티 루프 보호가 자동으로 감지하지만, 수동 개입이 필요한 경우:

```bash
# debate_hashes 확인
cat state/debate_hashes.json | python3 -m json.tool

# 해시 초기화 (루프 감지 리셋)
echo '{"hashes": []}' > state/debate_hashes.json

# 시스템 재시작
./scripts/stop.sh && ./scripts/start.sh
```

### Slack 알림이 오지 않음

```bash
# Webhook URL 테스트
curl -X POST -H 'Content-type: application/json' \
  --data '{"text":"Test message from OpenClaw"}' \
  https://hooks.slack.com/services/YOUR/WEBHOOK/URL

# Bot token 확인
openclaw config get slack.bot_token
```

### 비용이 예상보다 많이 나옴

```bash
# 비용 상세 확인
./scripts/status.sh

# 토론당 비용 제한 줄이기
# openclaw.json에서 max_cost_per_debate_usd 값 조정

# 현재 토론 강제 종료
./scripts/stop.sh
```

### run_state.json이 깨짐

```bash
# 상태 파일 재초기화
cat > state/run_state.json << 'EOF'
{
  "status": "stopped",
  "started_by": null,
  "stopped_by": "manual_reset",
  "last_updated": "2026-01-01T00:00:00Z",
  "total_cycles": 0,
  "current_task": null,
  "pid": null
}
EOF

# 시스템 재시작
./scripts/start.sh
```

### 로그 확인

```bash
# 토론 기록 확인
cat state/decision_log.md

# OpenClaw 자체 로그
openclaw logs --tail 50

# 시스템 로그 (macOS)
log show --predicate 'processImagePath contains "openclaw"' --last 1h
```

## 프로젝트 구조

```
openclaw-multi-agent/
├── README.md                           # 이 파일
├── openclaw.json                       # OpenClaw 설정 (사용자가 생성)
├── scripts/
│   ├── start.sh                        # 시스템 시작
│   ├── stop.sh                         # 시스템 정지
│   └── status.sh                       # 상태 확인
├── skills/
│   └── debate-orchestrator/
│       └── SKILL.md                    # 토론 오케스트레이션 스킬
└── state/                              # 런타임 상태 (자동 생성)
    ├── run_state.json                  # 실행 상태
    ├── backlog.json                    # 작업 큐
    ├── cost_ledger.json                # 비용 추적
    ├── decision_log.md                 # 토론 기록
    └── debate_hashes.json              # 안티 루프 해시
```

## 라이선스

MIT License
