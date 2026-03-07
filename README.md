# OpenClaw Multi-Agent Collaborative Problem Solver

여러 AI 에이전트가 토론과 협업을 통해 코딩 문제를 해결하는 멀티 에이전트 시스템입니다.

## 빠른 시작

```bash
git clone https://github.com/seokmogu/openclaw-multi-agent.git && cd openclaw-multi-agent
./scripts/start.sh                    # 시작 (기본 프로파일: openclaw-multi-agent)
./scripts/status.sh                   # 상태 확인
```

## 개요

OpenClaw Multi-Agent는 5개의 전문 AI 에이전트(Orchestrator, Planner, Critic, Implementer, Verifier)가 구조화된 토론 프로토콜을 통해 협력하여 복잡한 코딩 문제를 해결합니다. 각 에이전트는 OpenCode, Claude Code, Codex CLI, Gemini CLI 등의 도구를 사용하며, 무한 루프로 작업을 처리하고 결과를 Slack으로 보고합니다.

### 아키텍처

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
│          │                   │                                   │
└──────────┘                   │ propose/revise                    │ challenge
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

## 프로파일 격리

동일한 머신에서 여러 OpenClaw 프로젝트를 동시에 운영할 때 발생하는 설정 충돌을 방지하기 위해 프로파일 격리 기능을 제공합니다.

*   **필요성**: 모든 프로젝트가 기본 경로인 `~/.openclaw`를 공유하면 설정과 상태가 뒤섞일 수 있습니다.
*   **사용법**: `OPENCLAW_PROFILE=name ./scripts/start.sh` 명령어를 실행합니다.
*   **동작 원리**: 내부적으로 `openclaw --profile name`을 사용하며, 모든 상태는 `~/.openclaw-<name>` 경로에 독립적으로 저장됩니다.
*   **기본값**: 별도 설정이 없으면 `openclaw-multi-agent` 프로파일을 사용합니다.
*   **포트 관리**: Gateway 포트는 프로파일 이름을 기반으로 자동 계산됩니다. CRC32 해시를 사용하여 19000에서 20999 사이의 고유 포트를 할당합니다.
*   **스크립트 지원**: `start.sh`, `stop.sh`, `status.sh` 모든 스크립트가 프로파일 설정을 지원합니다.

## 사전 요구 사항

### 필수 도구

| 항목 | 설명 | 설치 방법 |
|------|------|----------|
| **OpenClaw** | 멀티 에이전트 오케스트레이션 프레임워크 | [openclaw.dev/install](https://openclaw.dev/install) |
| **Python 3.8+** | 상태 관리 스크립트 실행 | `brew install python` |
| **curl** | Slack 알림 및 API 통신 | 기본 설치됨 |

### CLI 에이전트 도구 (하나 이상 필수)

| 도구 | 역할 | 설치 방법 |
|------|------|----------|
| **OpenCode** | 코드 편집, 분석, 디버깅 | [opencode.dev](https://opencode.dev) |
| **Claude Code** | 코드 생성 및 리팩토링 | `npm install -g @anthropic-ai/claude-code` |
| **Codex CLI** | 코드 검증 및 테스트 생성 | `npm install -g @openai/codex` |
| **Gemini CLI** | 디자인 리뷰 및 문서화 | `npm install -g @google/gemini-cli` |

## Slack 연결

OpenClaw는 네이티브 Slack 채널 지원을 통해 실시간 알림과 작업 수신을 처리합니다.

```bash
openclaw channels add --channel slack --bot-token xoxb-... --app-token xapp-...
openclaw message send --channel slack --target "#channel-name" --message "text"
```

설정 전 [api.slack.com/apps](https://api.slack.com/apps)에서 Slack 앱을 생성해야 합니다. 앱 설정 시 Bot Token Scopes에 `chat:write`, `channels:read`, `channels:history` 권한을 반드시 추가하세요.

## 에이전트 역할

### Orchestrator (오케스트레이터)
전체 시스템의 지휘자입니다. 작업을 수신하고 에이전트 간 토론을 조율하며 최종 결정을 내립니다. 수렴 판정과 타이브레이크 역할을 수행합니다.

### Planner (플래너)
계획 수립 전문가입니다. 작업을 분석하여 기술적 접근법을 제안합니다. Critic의 비판을 반영하여 계획을 수정하고 최적의 설계안을 도출합니다.

### Critic (크리틱)
비판적 분석 전문가입니다. 제안된 계획의 약점을 분석하고 기술적 리스크를 평가합니다. 더 나은 대안을 제시하여 결과물의 품질을 높입니다.

### Implementer (구현자)
코드 구현 전문가입니다. 토론을 통해 합의된 계획을 실제 코드로 옮깁니다. 파일 생성, 수정 및 모듈 개발을 담당합니다.

### Verifier (검증자)
품질 검증 전문가입니다. 구현된 코드가 요구사항을 충족하는지 확인합니다. 보안, 성능, 정확성을 체크하고 최종 승인 여부를 결정합니다.

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
모든 에이전트는 다음 형식으로 응답하여 구조화된 데이터를 교환합니다.

```json
{
  "claim": "핵심 주장 또는 제안 (한 문장)",
  "evidence": ["근거 1", "근거 2", "근거 3"],
  "risk": ["리스크 1", "리스크 2"],
  "next_action": "implement | revise | escalate | verify"
}
```

### 에포크 시스템
OpenClaw의 세션당 턴 제한을 우회하기 위해 에포크 단위를 도입했습니다.

*   **1 에포크**: 제안(propose), 비판(challenge), 수정(revise) 단계로 구성됩니다.
*   미수렴 시 토론 요약을 기록하고 새 세션에서 다음 에포크를 시작합니다.
*   최대 에포크 도달 시 Orchestrator가 최종 결정을 내립니다.

## CLI 도구 활용

각 에이전트는 전문 분야에 맞춰 CLI 도구를 호출합니다.

*   **OpenCode**: 모든 에이전트가 코드 분석, 편집, 테스트 실행에 공통으로 사용합니다.
*   **Claude Code**: Planner와 Implementer가 아키텍처 설계 및 코드 생성에 사용합니다.
*   **Codex CLI**: Critic과 Verifier가 대안 검증 및 유닛 테스트 생성에 사용합니다.
*   **Gemini CLI**: 디자인 리뷰와 API 문서 자동 생성에 사용합니다.

## 상태 파일

시스템 상태는 `state/` 디렉토리에 저장되며 실시간으로 업데이트됩니다.

### backlog.json
작업 큐와 진행 상태를 관리합니다.
```json
{
  "tasks": [
    {
      "id": "task-001",
      "title": "작업 제목",
      "status": "pending",
      "debate_epochs": 0,
      "retry_count": 0
    }
  ]
}
```

## 트러블슈팅

### 시스템이 시작되지 않음

```bash
openclaw --version                     # OpenClaw 설치 확인
openclaw gateway health                # Gateway 상태 확인
OPENCLAW_PROFILE=openclaw-multi-agent ./scripts/status.sh  # 프로파일 상태 확인
```

### 세션/에이전트 문제

```bash
openclaw sessions list                 # 활성 세션 확인
openclaw agents list                   # 등록된 에이전트 확인
```

### Gateway 포트 충돌

여러 프로파일을 동시에 실행할 때 드물게 포트가 겹칠 수 있습니다. 프로파일 이름을 변경하면 새 포트가 자동 할당됩니다.

```bash
OPENCLAW_PROFILE=my-new-name ./scripts/start.sh
```

### run_state.json 손상

```bash
cat > state/run_state.json << 'EOF'
{"status":"stopped","started_by":null,"stopped_by":"manual_reset","last_updated":"2026-01-01T00:00:00Z","total_cycles":0,"current_task":null}
EOF
./scripts/start.sh
```

### Slack 알림 미수신

```bash
# 채널 연결 상태 확인
openclaw channels status
# 테스트 메시지 전송
openclaw message send --channel slack --target "#channel-name" --message "test" --dry-run
```

## 프로젝트 구조

```
openclaw-multi-agent/
├── README.md
├── openclaw.json                       # 참조용 설정 (JSON5, 문서 목적)
├── agents/
│   ├── orchestrator/                   # AGENTS.md, SOUL.md, auth-profiles.json
│   ├── planner/
│   ├── critic/
│   ├── implementer/
│   └── verifier/
├── scripts/
│   ├── start.sh                        # 시스템 시작 (프로파일 지원)
│   ├── stop.sh                         # 시스템 정지
│   └── status.sh                       # 상태 확인
├── skills/
│   └── debate-orchestrator/
│       └── SKILL.md                    # 토론 오케스트레이션 스킬
├── state/                              # 런타임 상태 (자동 생성)
│   ├── run_state.json                  # 실행 상태 (running/stopped/paused)
│   ├── backlog.json                    # 작업 큐
│   ├── decision_log.md                 # 토론 기록
│   └── debate_hashes.json              # 안티 루프 해시
├── tools/
│   └── cli/                            # CLI 래퍼 스크립트
│       ├── common.sh                   # 공통 함수 (타임아웃, 출력 제어)
│       ├── claude.sh                   # Claude Code 래퍼
│       ├── codex.sh                    # Codex CLI 래퍼
│       ├── gemini.sh                   # Gemini CLI 래퍼
│       └── opencode.sh                 # OpenCode 래퍼
└── workspaces/                         # 에이전트 런타임 작업 공간 (gitignored)
```

## 라이선스

MIT License
