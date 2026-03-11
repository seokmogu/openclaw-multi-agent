# OCMA: OpenClaw Multi-Agent Self-Evolving System

## 개요
OCMA는 5개의 AI 에이전트가 협력하여 코드를 자동 생성하고 관리하는 자가발전형 시스템입니다. Orchestrator, Planner, Critic, Implementer, Verifier가 토론, 구현, 검증 과정을 거쳐 GitHub PR까지 자동으로 만듭니다.

- **5개 AI 에이전트 협업**: claude-opus-4-6, claude-sonnet-4-6, gpt-5.4 모델을 조합하여 결과물을 만듭니다.
- **에이전트 자동 기동**: `openclaw.json`의 `agents.defaults.subagents.autoStartAgents` 설정으로 Planner/Implementer/Critic/Verifier 세션을 미리 띄워 debate 단계의 세션 부재 실패를 줄입니다.
- **인증 방식**: API 키를 직접 쓰지 않고 OAuth 및 로그인 세션 기반 인증을 사용합니다.
- **완전 격리**: Podman 컨테이너 환경에서 실행되어 호스트 시스템과 분리됩니다.
- **자가발전(Self-evolution)**: 백로그가 비어있을 때 `goals.md`를 분석하여 새로운 태스크를 스스로 찾습니다.

## 아키텍처 다이어그램
```
User/Slack/Cron
    ↓
┌─ Podman Container (ocma-gateway) ──────────────────┐
│  OpenClaw Gateway (ws://0.0.0.0:18789)              │
│                                                      │
│  Orchestrator (claude-opus-4-6)                      │
│    ├─ Step 0: Safety Pre-Check                       │
│    ├─ Step 0.5: Cycle Lock                           │
│    ├─ Step 1-2: Pick task, load debate config        │
│    ├─ Step 3: Task Discovery (self-evolution)        │
│    ├─ Step 5: Debate                                 │
│    │   ├─ Planner (claude-sonnet-4-6) ── propose     │
│    │   ├─ Critic (gpt-5.4) ── challenge              │
│    │   └─ Planner ── revise                          │
│    ├─ Step 6: Implement                              │
│    │   └─ Implementer (claude-sonnet-4-6)            │
│    ├─ Step 7: Verify                                 │
│    │   └─ Verifier (gpt-5.4)                         │
│    ├─ Step 8: Git commit + PR                        │
│    └─ Step 9.7: Self-Trigger Next Cycle              │
│                                                      │
│  Volume Mounts:                                      │
│    ./agents/ → /project/agents/                      │
│    ./state/  → /project/state/                       │
│    ./tools/  → /project/tools/ (ro)                  │
└──────────────────────────────────────────────────────┘
    ↓
GitHub Repos (clone → branch → implement → PR)
```

## 빠른 시작
```bash
# 1. 저장소 복제
git clone https://github.com/seokmogu/openclaw-multi-agent.git
cd openclaw-multi-agent

# 2. 환경 변수 설정
cp .env.example .env
# GH_TOKEN, OPENCLAW_GATEWAY_TOKEN, Slack 토큰 등을 설정하세요.

# 3. 빌드 및 실행
podman-compose build
podman-compose up -d

# 4. 상태 확인
podman ps
podman exec ocma-gateway openclaw --version

# 5. 백로그에 태스크 추가
# state/backlog.json 파일에 pending 상태의 태스크를 추가합니다.

# 6. 사이클 시작
podman exec ocma-gateway openclaw system event --mode now --text "start cycle"
```

## 이벤트 드리븐 아키텍처
시스템은 이벤트 기반으로 동작하며 효율적으로 자원을 관리합니다.

- **Watchdog**: 크론 작업은 30분마다 실행되어 사이클이 멈춘 경우에만 재시작을 돕습니다.
- **자동 트리거**: 사이클이 끝나면 `openclaw system event --mode now` 명령을 통해 즉시 다음 사이클을 시작합니다.
- **중복 방지**: `cycle_lock` 메커니즘을 사용하여 여러 사이클이 동시에 실행되는 것을 막습니다.
- **유휴 상태**: 백로그가 비어 있고 새로운 태스크 발견 조건이 맞지 않으면 대기합니다.

## 자가발전 엔진
OCMA는 스스로 할 일을 찾아내고 시스템을 개선합니다.

- **목표 기반 발견**: `state/goals.md`에 정의된 목표를 바탕으로 백로그가 비었을 때 자동으로 태스크를 만듭니다.
- **발견 소스**: goals.md 분석, Critic 패턴 파악, Verifier 실패 사례, 코드 건강도 체크 등 4가지 소스를 사용합니다.
- **안전 장치**: 연속 실패 횟수 추적, 우선순위 상한선 설정, 중복 태스크 감지 기능을 포함합니다.
- **설정 제어**: `state/discovery_config.json` 파일을 통해 엔진 동작을 조정할 수 있습니다.

## 에이전트 역할
각 에이전트는 특정 모델을 사용하여 전문적인 역할을 수행합니다.

- **Orchestrator (claude-opus-4-6)**: 전체 사이클을 지휘하고 토론을 조율하며 최종 결정을 내립니다.
- **Planner (claude-sonnet-4-6)**: 기술적인 설계를 제안하고 Critic의 피드백을 반영하여 계획을 고칩니다.
- **Critic (gpt-5.4)**: 제안된 계획을 비판적으로 검토하여 승인, 수정 요청 또는 거절 판정을 내립니다.
- **Implementer (claude-sonnet-4-6)**: 확정된 계획에 따라 코드를 구현하고 Git 브랜치 작업을 합니다.
- **Verifier (gpt-5.4)**: 구현된 결과물이 요구사항을 충족하는지 검증하고 최종 합격 여부를 판정합니다.

## 토론 프로토콜
Planner와 Critic 사이의 토론은 엄격한 규칙에 따라 진행됩니다.

- **Epoch 시스템**: 기본적으로 최대 3회까지 토론을 반복하여 합의점을 찾습니다.
- **JSON 컨트랙트**: 모든 에이전트 응답은 정해진 JSON 형식을 따라야 합니다.
- **수렴 기준**: Planner의 제안과 Critic의 검토 결과가 일치할 때 구현 단계로 넘어갑니다.

## GitHub 통합
코드 작업은 안전하게 격리된 환경에서 이루어집니다.

- **작업 공간 격리**: 각 태스크는 `/project/workspaces/.clones/{task-id}/{repo}/` 경로에 독립적으로 복제됩니다.
- **저장소 캐시**: `/project/workspaces/.repos/{repo}.git` 경로에 베어 저장소를 캐싱하여 속도를 높입니다.
- **브랜치 규칙**: `ocma/task-{id}` 형식의 브랜치 이름을 사용합니다.
- **자동 PR**: 검증을 통과한 작업은 `gh pr create` 명령을 통해 자동으로 Pull Request를 만듭니다.

## 상태 파일
시스템의 모든 상태는 `state/` 디렉토리의 JSON 및 Markdown 파일로 관리됩니다.

- **run_state.json**: 현재 실행 상태와 `cycle_lock` 정보를 담고 있습니다.
- **backlog.json**: 대기 중이거나 진행 중인 태스크 큐입니다.
- **decision_log.md**: 에이전트 간의 토론 기록을 보관합니다.
- **discovery_config.json**: 자가발전 엔진의 설정 파일입니다.
- **goals.md**: 시스템이 지향하는 장기적인 목표 정의서입니다.
- **learning_log.json**: 과거 작업으로부터 얻은 학습 기록입니다.
- **metrics.json**: 각 사이클의 성능 지표를 기록합니다.

## 프로젝트 구조
```
openclaw-multi-agent/
├── compose.yml                    # Podman Compose 설정
├── Containerfile                  # 컨테이너 이미지 빌드
├── .env                           # 시크릿 (gitignored)
├── container-config/              # OpenClaw 설정 (volume mount, gitignored)
│   └── openclaw.json
├── agents/
│   ├── orchestrator/
│   │   ├── AGENTS.md              # 에이전트 지시사항
│   │   └── HEARTBEAT.md           # 오케스트레이션 사이클 (22 steps)
│   ├── planner/AGENTS.md
│   ├── implementer/AGENTS.md
│   ├── critic/AGENTS.md
│   └── verifier/AGENTS.md
├── scripts/
│   ├── entrypoint.sh              # 컨테이너 초기화 및 CLI 자동 업데이트
│   ├── status.sh                  # 시스템 상태 확인
│   └── patch-gpt54.py             # GPT-5.4 모델 패치
├── state/                          # 런타임 상태 (volume mount)
│   ├── run_state.json
│   ├── backlog.json
│   ├── decision_log.md
│   ├── discovery_config.json
│   ├── goals.md
│   ├── learning_log.json
│   ├── metrics.json
│   └── debate_config.json
├── tools/cli/                      # CLI 래퍼 (volume mount, read-only)
│   ├── common.sh                   # 재시도, 타임아웃, 토큰 체크
│   ├── git.sh                      # 복제, 브랜치, 커밋, 푸시
│   └── gh.sh                       # PR 생성 및 상태 확인
└── workspaces/                     # 에이전트 작업 공간 (gitignored)
    ├── .repos/                     # 베어 저장소 캐시
    └── .clones/                    # 태스크별 복제본
```

## 설정
시스템 동작을 위해 다음 설정이 필요합니다.

- **.env 필수 변수**: `GH_TOKEN`, `OPENCLAW_GATEWAY_TOKEN`, `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`이 반드시 설정되어야 합니다.
- **container-config/openclaw.json**: 에이전트 정의, 모델 설정, 세션 정보를 관리합니다.
- **state/debate_config.json**: 최대 Epoch 횟수와 수렴 임계값 등을 설정합니다.

## 인증
보안을 위해 API 키 대신 세션 기반 인증을 우선합니다.

- **Anthropic**: `auth-profiles.json`에 저장된 OAuth 토큰을 사용합니다.
- **OpenAI**: Codex CLI를 통한 ChatGPT Pro OAuth 인증을 사용합니다.
- **GitHub**: `.env`의 `GH_TOKEN`을 컨테이너 내부의 `.git-credentials` 파일로 변환하여 사용합니다.

## 모니터링
다음 명령어를 사용하여 시스템 상태를 실시간으로 확인할 수 있습니다.

```bash
# 로그 확인
podman logs --tail 50 ocma-gateway

# 활성 세션 목록
podman exec ocma-gateway openclaw sessions

# 크론 작업 목록
podman exec ocma-gateway openclaw cron list

# 사이클 상태 확인
cat state/run_state.json | python3 -m json.tool

# 태스크 큐 확인
cat state/backlog.json | python3 -m json.tool
```

## 트러블슈팅
자주 발생하는 문제와 해결 방법입니다.

- **컨테이너 시작 실패**: `podman-compose logs` 명령으로 에러 메시지를 확인하세요.
- **GitHub 토큰 만료**: `.env` 파일을 갱신한 후 `podman-compose restart`를 실행하세요.
- **사이클 멈춤 현상**: `run_state.json`의 `cycle_lock`이 남아있는지 확인하고 필요하면 `null`로 초기화하세요.
- **토론 타임아웃**: `runTimeoutSeconds` 설정을 확인하세요. 기본값은 1800초입니다.
- **HEARTBEAT.md 잘림**: `bootstrapMaxChars` 설정을 늘리세요. 기본값은 50000입니다.

## 라이선스
MIT
