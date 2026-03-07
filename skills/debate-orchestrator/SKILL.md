---
name: debate-orchestrator
description: Orchestrate multi-round debates between AI agents using epoched sessions_send. Manages propose→challenge→revise→decide cycles with convergence detection and tie-breaking.
---

# Debate Orchestrator

Orchestrator 에이전트가 로드하는 핵심 스킬. 여러 AI 에이전트 간의 구조화된 토론을 관리하여 고품질 의사결정을 도출한다.

## 1. Debate Protocol

모든 토론은 4단계 사이클을 따른다:

```
propose → challenge → revise → decide
```

| 단계 | 주체 | 목적 | sessions_send 호출 |
|------|------|------|-------------------|
| **propose** | Planner | 작업에 대한 초기 계획/접근법 제안 | 1회 |
| **challenge** | Critic | 제안의 약점, 리스크, 대안 지적 | 1회 |
| **revise** | Planner | 비판을 반영한 수정 계획 제출 | 1회 |
| **decide** | Orchestrator | 수렴 여부 판단, 다음 행동 결정 | 0회 (내부 판단) |

### 각 단계 세부 동작

**propose 단계:**
- Orchestrator가 Planner에게 작업 컨텍스트와 요구사항을 전달한다.
- Planner는 JSON Contract 형식으로 초기 계획을 응답한다.
- 이전 epoch의 요약이 있으면 해당 컨텍스트도 함께 전달한다.

**challenge 단계:**
- Orchestrator가 Planner의 제안을 Critic에게 전달한다.
- Critic은 기술적 리스크, 누락된 고려사항, 대안적 접근법을 제시한다.
- Critic은 반드시 구체적 근거(evidence)와 함께 비판해야 한다.

**revise 단계:**
- Orchestrator가 Critic의 비판을 Planner에게 전달한다.
- Planner는 비판을 수용/반박하며 수정된 계획을 제출한다.
- 수용한 비판과 반박한 비판을 명시적으로 구분해야 한다.

**decide 단계:**
- Orchestrator가 전체 토론 내용을 분석한다.
- 수렴 규칙에 따라 진행/재토론/타이브레이크를 결정한다.
- 결정 결과를 `state/decision_log.md`에 기록한다.

## 2. Epoching System

OpenClaw의 `sessions_send`는 세션당 최대 5회 호출 제한이 있다. 이를 우회하기 위해 에포크(epoch) 시스템을 사용한다.

### 에포크 구조

```
Epoch 1: propose(1) → challenge(1) → revise(1) = 3 sessions_send 호출
  ↓ 미수렴 시
[요약 작성 → state/decision_log.md 저장]
  ↓
Epoch 2: propose(1) → challenge(1) → revise(1) = 3 sessions_send 호출 (새 세션)
  ↓ 미수렴 시
[요약 작성 → state/decision_log.md 저장]
  ↓
Epoch 3: propose(1) → challenge(1) → revise(1) = 3 sessions_send 호출 (새 세션)
  ↓ 미수렴 시
[Orchestrator 타이브레이크 강제 결정]
```

### 에포크 전환 절차

1. 현재 epoch의 토론 내용을 압축 요약한다 (최대 500 토큰).
2. 요약을 `state/decision_log.md`에 append한다.
3. 새 세션을 시작하고, 요약을 초기 컨텍스트로 주입한다.
4. epoch 카운터를 증가시키고 다음 propose를 진행한다.

### 요약 템플릿

```markdown
## Epoch {N} Summary
- **Task**: {원래 작업 설명}
- **Proposed**: {Planner의 핵심 제안}
- **Challenged**: {Critic의 핵심 비판}
- **Revised**: {수정된 핵심 내용}
- **Status**: converged | diverged | partial_agreement
- **Open Issues**: {미해결 쟁점 목록}
- **Accumulated Evidence**: {누적된 근거}
```

### 최대 에포크 제한

- 기본값: **3 epochs** (총 최대 9 sessions_send 호출)
- 3 epoch 이후에도 미수렴 시, Orchestrator가 누적된 evidence를 기반으로 강제 결정한다.
- 강제 결정 시 `decision_log.md`에 `[TIE-BREAK]` 태그를 붙인다.

## 3. JSON Contract

모든 에이전트는 반드시 아래 JSON 구조로 응답해야 한다. 자유형 텍스트 응답은 허용되지 않는다.

```json
{
  "claim": "핵심 주장 또는 제안을 한 문장으로 기술",
  "evidence": [
    "주장을 뒷받침하는 구체적 근거 1",
    "주장을 뒷받침하는 구체적 근거 2",
    "주장을 뒷받침하는 구체적 근거 3"
  ],
  "risk": [
    "이 접근법의 잠재적 위험 1",
    "이 접근법의 잠재적 위험 2"
  ],
  "next_action": "implement | revise | escalate | verify"
}
```

### 필드 설명

| 필드 | 타입 | 필수 | 설명 |
|------|------|------|------|
| `claim` | string | Y | 핵심 주장. 120자 이내 권장 |
| `evidence` | string[] | Y | 최소 1개의 근거. 구체적이고 검증 가능해야 함 |
| `risk` | string[] | Y | 최소 1개의 리스크. 빈 배열 불가 |
| `next_action` | string | Y | 다음 행동. 4개 값 중 하나 |

### next_action 값 정의

- **implement**: 합의 도달, 구현 단계로 진행
- **revise**: 추가 수정 필요, 다음 epoch에서 재토론
- **escalate**: 에이전트 범위 밖, 사용자 개입 필요
- **verify**: 구현 완료 후 검증 단계로 진행

### 역할별 JSON 예시

**Planner (propose 단계):**
```json
{
  "claim": "JWT 기반 인증에 refresh token rotation을 적용하여 보안성과 사용성을 모두 확보한다",
  "evidence": [
    "OWASP 가이드라인에서 refresh token rotation을 권장",
    "access token 만료 시간 15분으로 설정 시 탈취 위험 최소화",
    "Redis 기반 token blacklist로 즉시 무효화 가능"
  ],
  "risk": [
    "Redis 장애 시 token 무효화 불가 - fallback 전략 필요",
    "refresh token rotation 구현 복잡도 증가"
  ],
  "next_action": "implement"
}
```

**Critic (challenge 단계):**
```json
{
  "claim": "Redis 단일 장애점 문제를 해결하지 않으면 프로덕션 배포 불가",
  "evidence": [
    "Redis 장애 시 모든 사용자 세션이 즉시 무효화되는 치명적 결함",
    "Redis Sentinel/Cluster 없이는 99.9% SLA 달성 불가",
    "대안으로 DB 기반 token 저장 + 캐시 레이어 아키텍처가 더 안정적"
  ],
  "risk": [
    "DB 기반 접근 시 인증 지연 시간 증가 (평균 50ms → 200ms)",
    "캐시 레이어 추가로 인프라 복잡도 증가"
  ],
  "next_action": "revise"
}
```

## 4. Convergence Rules

수렴 판정은 Orchestrator가 decide 단계에서 수행한다.

### 수렴 조건 (하나라도 충족 시)

1. **에이전트 합의**: 2개 이상의 에이전트가 동일한 접근법에 동의
   - `next_action`이 모두 `implement`이고 `claim`의 핵심 방향이 일치하면 합의로 판정
2. **Verifier 확신도**: Verifier의 confidence score가 0.7 이상
   - Verifier가 계획을 검토 후 `{"confidence": 0.8}` 등으로 응답하면 진행 가능

### 미수렴 처리

1. **부분 합의** (1개 에이전트만 implement): 다음 epoch에서 재토론
2. **완전 미합의** (모두 revise): 다음 epoch에서 재토론, Orchestrator가 논점 정리
3. **에스컬레이션** (escalate 발생): 사용자에게 Slack으로 판단 요청

### 최대 에포크 도달 시

3 epoch 후에도 미수렴이면 Orchestrator가 타이브레이크를 실행한다:
- 모든 epoch의 evidence를 누적하여 가중 평가
- 리스크가 가장 적은 접근법을 선택
- `[TIE-BREAK]` 로그에 선택 근거를 명시

## 5. Anti-Loop Protection

토론이 무한 루프에 빠지는 것을 방지한다.

### debate_hash 메커니즘

```
debate_hash = SHA256(last_2_decisions)
```

- 각 epoch의 decide 결과에서 `claim` + `next_action`을 연결하여 해시 생성
- 해시를 `state/debate_hashes.json`에 저장
- 새 epoch 시작 전에 이전 해시와 비교

### 루프 감지 규칙

```python
# 의사 코드
current_hash = sha256(epoch_N_decision + epoch_N-1_decision)
if current_hash in previous_hashes:
    # 동일한 논쟁이 반복됨 → 강제 타이브레이크
    force_tiebreak(reason="stale_debate_detected")
```

- 해시가 `state/debate_hashes.json`에 이미 존재하면 stale debate로 판정
- 즉시 타이브레이크를 실행하고 다음 단계로 진행

## 6. Example Debate Flow

실제 sessions_send 호출을 포함한 전체 토론 흐름 예시.

### 작업: "REST API에 사용자 인증 기능 구현"

#### Epoch 1

**Step 1: Orchestrator → Planner (propose)**

```bash
openclaw sessions_send \
  --agent planner \
  --session "debate-auth-001-e1" \
  --message '{
    "role": "propose",
    "task": "REST API에 사용자 인증 기능 구현",
    "constraints": ["Node.js/Express 환경", "기존 PostgreSQL DB 사용", "모바일 앱 지원 필요"],
    "previous_context": null
  }'
```

**Planner 응답:**
```json
{
  "claim": "JWT 기반 인증에 refresh token rotation을 적용하여 보안성과 사용성을 모두 확보한다",
  "evidence": [
    "OWASP 가이드라인에서 refresh token rotation을 권장",
    "access token 만료 시간 15분으로 설정 시 탈취 위험 최소화",
    "Redis 기반 token blacklist로 즉시 무효화 가능"
  ],
  "risk": [
    "Redis 장애 시 token 무효화 불가 - fallback 전략 필요",
    "refresh token rotation 구현 복잡도 증가"
  ],
  "next_action": "implement"
}
```

**Step 2: Orchestrator → Critic (challenge)**

```bash
openclaw sessions_send \
  --agent critic \
  --session "debate-auth-001-e1" \
  --message '{
    "role": "challenge",
    "proposal": {
      "claim": "JWT 기반 인증에 refresh token rotation을 적용",
      "evidence": ["OWASP 권장", "15분 만료", "Redis blacklist"],
      "risk": ["Redis 장애", "구현 복잡도"]
    },
    "focus": "보안 취약점, 인프라 의존성, 대안적 접근법"
  }'
```

**Critic 응답:**
```json
{
  "claim": "Redis 단일 장애점 문제를 해결하지 않으면 프로덕션 배포 불가",
  "evidence": [
    "Redis 장애 시 모든 사용자 세션이 즉시 무효화되는 치명적 결함",
    "Redis Sentinel/Cluster 없이는 99.9% SLA 달성 불가",
    "대안으로 DB 기반 token 저장 + 캐시 레이어 아키텍처가 더 안정적"
  ],
  "risk": [
    "DB 기반 접근 시 인증 지연 시간 증가 (평균 50ms → 200ms)",
    "캐시 레이어 추가로 인프라 복잡도 증가"
  ],
  "next_action": "revise"
}
```

**Step 3: Orchestrator → Planner (revise)**

```bash
openclaw sessions_send \
  --agent planner \
  --session "debate-auth-001-e1" \
  --message '{
    "role": "revise",
    "original_claim": "JWT + Redis blacklist",
    "criticism": {
      "claim": "Redis 단일 장애점 문제",
      "evidence": ["Redis 장애 시 세션 무효화", "SLA 달성 불가", "DB+캐시 대안"]
    },
    "instruction": "Critic의 비판을 반영하여 수정 계획을 제출하라. 수용/반박을 명시하라."
  }'
```

**Planner 수정 응답:**
```json
{
  "claim": "PostgreSQL 기반 token 저장 + Redis 캐시 레이어로 안정성과 성능을 모두 확보한다",
  "evidence": [
    "PostgreSQL을 source of truth로 사용하여 Redis 장애 시에도 인증 가능 (Critic 비판 수용)",
    "Redis를 캐시로만 활용하여 평균 응답시간 80ms 유지 가능",
    "Redis 장애 시 자동 DB fallback으로 200ms 이내 응답 보장"
  ],
  "risk": [
    "초기 구현 시 DB 스키마 마이그레이션 필요",
    "캐시 무효화 전략 설계 필요"
  ],
  "next_action": "implement"
}
```

**Step 4: Orchestrator (decide)**

Orchestrator 내부 판단:
- Planner: `next_action = "implement"` (수정 후)
- Critic의 핵심 우려 (Redis 단일 장애점)가 수정안에 반영됨
- 판정: **수렴 (converged)** → 구현 단계로 진행

```markdown
## Epoch 1 Summary
- **Task**: REST API 사용자 인증 구현
- **Proposed**: JWT + Redis blacklist
- **Challenged**: Redis 단일 장애점, SLA 미달
- **Revised**: PostgreSQL 기반 저장 + Redis 캐시 레이어
- **Status**: converged
- **Open Issues**: 없음
- **Decision**: 수정안 채택, Implementer에게 전달
```

#### 수렴 후: 구현 및 검증

**Orchestrator → Implementer:**

```bash
openclaw sessions_send \
  --agent implementer \
  --session "impl-auth-001" \
  --message '{
    "task": "수정 계획에 따라 인증 기능 구현",
    "plan": "PostgreSQL token 저장 + Redis 캐시",
    "tools": ["opencode", "claude"],
    "target_files": ["src/auth/", "src/middleware/"],
    "debate_summary": "Epoch 1에서 Redis 단일 장애점 해결을 위해 PostgreSQL 기반으로 변경"
  }'
```

**Orchestrator → Verifier:**

```bash
openclaw sessions_send \
  --agent verifier \
  --session "verify-auth-001" \
  --message '{
    "task": "인증 구현 검증",
    "check_list": [
      "JWT 토큰 발급/검증 정상 동작",
      "refresh token rotation 구현 여부",
      "Redis 장애 시 DB fallback 동작",
      "보안 취약점 스캔 결과"
    ],
    "tools": ["opencode", "codex"],
    "implementation_session": "impl-auth-001"
  }'
```

#### 미수렴 시 Epoch 2 예시

만약 Epoch 1에서 수렴하지 않았다면:

```bash
# 새 세션으로 Epoch 2 시작
openclaw sessions_send \
  --agent planner \
  --session "debate-auth-001-e2" \
  --message '{
    "role": "propose",
    "task": "REST API에 사용자 인증 기능 구현",
    "constraints": ["Node.js/Express 환경", "기존 PostgreSQL DB 사용"],
    "previous_context": "Epoch 1 요약: JWT+Redis 제안 → Redis 단일 장애점 비판 → DB+캐시 수정안 제안했으나 성능 우려로 미합의. 미해결: DB fallback 시 지연 시간 허용 범위"
  }'
```

## 7. State File Locations

토론 과정에서 사용하는 상태 파일들:

| 파일 | 경로 | 용도 |
|------|------|------|
| Decision Log | `state/decision_log.md` | 각 epoch 요약 및 최종 결정 기록 |
| Debate Hashes | `state/debate_hashes.json` | 루프 감지용 해시 저장 |
| Run State | `state/run_state.json` | 시스템 실행 상태 |

## 8. Orchestrator Decision Matrix

| Planner next_action | Critic next_action | Verifier confidence | 판정 |
|---------------------|-------------------|--------------------|----|
| implement | - (challenge 후 revise 반영) | - | 수렴, 구현 진행 |
| implement | revise 유지 | - | 미수렴, 다음 epoch |
| revise | revise | - | 미수렴, 다음 epoch |
| escalate | any | - | 사용자 개입 요청 |
| implement | - | >= 0.7 | 수렴, 검증 통과 |
| implement | - | < 0.7 | 미수렴, 구현 수정 필요 |

## 9. Configuration

`openclaw.json`에서 토론 파라미터를 설정한다:

```json
{
  "debate": {
    "max_epochs": 3,
    "convergence_threshold": 0.7,
    "epoch_summary_max_tokens": 500,
    "anti_loop_enabled": true,
    "tiebreak_strategy": "lowest_risk"
  }
}
```

| 파라미터 | 기본값 | 설명 |
|---------|-------|------|
| `max_epochs` | 3 | 최대 에포크 수 |
| `convergence_threshold` | 0.7 | Verifier 수렴 판정 기준 |
| `epoch_summary_max_tokens` | 500 | 에포크 요약 최대 토큰 |
| `anti_loop_enabled` | true | 루프 감지 활성화 |
| `tiebreak_strategy` | "lowest_risk" | 타이브레이크 전략 (lowest_risk / highest_evidence / orchestrator_judgment) |
