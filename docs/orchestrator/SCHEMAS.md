# Orchestrator Contracts and Schemas

Use this file for detailed schemas that do not need to live in bootstrap-loaded docs.

## JSON Contract

All agent responses must include:

```json
{
  "claim": "Core assertion, max 200 chars",
  "evidence": ["Specific backing point 1", "Point 2"],
  "risk": ["Risk 1", "Risk 2"],
  "next_action": "implement | revise | escalate | verify"
}
```

Role-specific fields:

- Planner: `options`, `recommended`, `subtasks`
- Critic: `issues`, `verdict`, `severity_score`
- Implementer: `artifacts`
- Verifier: `checks`, `confidence`, `verdict`

### Critic `severity_score`

A float `0.0–1.0` representing the aggregate severity of all issues found. The Critic computes this as the maximum severity weight across issues:

- `critical` = 1.0
- `major` = 0.7
- `minor` = 0.3
- `nitpick` = 0.1

Used by the Orchestrator in Step 5 for threshold-based auto-convergence:

- `severity_score < severity_convergence_threshold` (default 0.3) + `APPROVE` verdict → auto-converge
- `severity_score >= 0.7` → issues are blocking, require Planner revision

## Response Efficiency Rules

- JSON only
- Max 5 `evidence` items
- Max 3 `risk` items
- No prose preamble
- Prefer `file:line` references over pasted code

## State Files

| File | Mode | Purpose |
|---|---|---|
| `/project/state/run_state.json` | R/W | Loop control and cycle lock |
| `/project/state/debate_config.json` | R/W | Debate parameters and tool config |
| `/project/state/goal.md` | R/W | Current objective |
| `/project/state/backlog.json` | R/W | Task queue |
| `/project/state/git_state.json` | R/W | Leases, clones, branches, PRs |
| `/project/state/decision_log.md` | W append | Debate and cycle audit trail |
| `/project/state/debate_hashes.json` | R/W | Anti-loop hashes |
| `/project/state/cron_state.json` | R | Cron job reference |
| `/project/state/learning_log.json` | R/W | Learning accumulation |
| `/project/state/metrics.json` | R/W | Cycle metrics |
| `/project/state/goals.md` | R | High-level evolution goals |
| `/project/state/discovery_config.json` | R/W | Discovery config |
| `/project/state/restart_state.json` | R/W | Restart protection and tool versions |

## `run_state.json`

```json
{
  "status": "running",
  "last_updated": "...",
  "last_heartbeat_at": "...",
  "last_cycle_id": "...",
  "last_completed_step": "...",
  "started_by": "user",
  "stopped_by": null,
  "pause_reason": null,
  "total_cycles": 1,
  "idle_cycles": 0,
  "cycle_lock": null,
  "config": {
    "max_cycles_without_progress": 5,
    "per_tool_timeout_sec": 0,
    "max_retries": 2,
    "max_debate_epochs": 3
  }
}
```

`cycle_lock` semantics:

- `null` -> no active cycle
- object -> `{ "locked_at": "<ISO>", "trigger": "<cron|system-event|manual>" }`
- stale if older than 1800 seconds

## `backlog.json` task schema

Required core fields:

- `id`, `title`, `description`, `status`, `priority`, `created_at`, `updated_at`

Common optional fields:

- `assigned_to`, `started_at`, `dependencies`, `debate_epochs`, `retry_count`, `result`, `error`
- `target_repo`, `github_repo`, `base_branch`, `branch_name`, `clone_path`
- `pr_number`, `pr_url`, `pr_status`
- `fast_path`
- `generated_by`, `source_task_id`, `learning_tags`, `priority_score`
- `blocked_by` (string[], optional): Array of task IDs that must reach `completed` status before this task becomes eligible for picking. Used by Step 3 to enable dependency-based parallel execution. Empty array or omitted means no dependencies.

Auto-discovery conventions:

- `generated_by` values like `user`, `user:slack`, `discovery:goals_md`, `discovery:critic_patterns`, `discovery:verifier_failures`, `discovery:code_health`
- `priority_score` is `0.0-1.0`

## `learning_log.json` entry schema

```json
{
  "id": "learning-<timestamp>",
  "task_id": "...",
  "type": "verifier_failure | debate_pattern | critic_insight | performance_metric",
  "content": "...",
  "tags": ["..."],
  "created_at": "...",
  "applied": false
}
```

### Extended learning_log fields (optional)

Optional fields (backward-compatible, added for RL-inspired learning):

- `structured_hindsight` (object, optional): Structured failure analysis extracted from Verifier FAIL responses
  - `category`: `"logic-error" | "edge-case" | "integration" | "requirement-mismatch" | "test-gap"`
  - `root_cause`: string - what went wrong
  - `recommendation`: string - what should have been done
  - `applicable_patterns`: string[] - task tags this hindsight applies to

## `metrics.json` entry schema

```json
{
  "cycle_id": "...",
  "timestamp": "...",
  "debate_epochs": 1,
  "debate_wall_time_sec": 42,
  "convergence_achieved": true,
  "tiebreak_used": false,
  "verification_verdict": "PASS",
  "verification_confidence": 0.91,
  "retry_count": 0,
  "total_cycle_time_sec": 88
}
```

### Extended metrics fields (optional)

Optional fields (backward-compatible, added for RL-inspired learning):

- `turn_scores` (array, optional): Per-turn quality scores computed AFTER cycle completes (outcome-based, 0 extra LLM calls)
  ```json
  [
    { "agent": "planner", "epoch": 1, "phase": "propose", "score": 0.8 },
    { "agent": "critic", "epoch": 1, "phase": "challenge", "score": 0.9 },
    { "agent": "planner", "epoch": 1, "phase": "revise", "score": 0.7 }
  ]
  ```
- `token_usage` (object, optional): Token consumption tracking per cycle
  ```json
  { "context_tokens": 2000, "debate_tokens": 4500, "implementation_tokens": 3000, "verification_tokens": 2500, "total": 12000 }
  ```
- `agent_performance` (object, optional): Per-agent aggregate from turn_scores (computed in auto-tuning)
  ```json
  { "planner": { "avg_score": 0.75, "trend": "improving" }, "critic": { "avg_score": 0.82, "trend": "stable" } }
  ```

## `token_efficiency` (`debate_config.json`)

Optional fields (backward-compatible defaults apply when omitted):

- `token_budget_per_cycle` (number, optional, default `15000`): Total token budget target per cycle
- `context_budget_tokens` (number, optional, default `4000`): Budget for debate context assembly
- `memory_search_limit_debate` (number, optional, default `2`): Maximum memory search hits injected into debate context
- `progressive_summary` (object, optional): Epoch compression thresholds for carrying debate context forward
  - `enabled` (boolean, optional, default `true`)
  - `epoch_n_minus_2_max_tokens` (number, optional, default `150`)
  - `epoch_n_minus_1_max_tokens` (number, optional, default `300`)
  - `current_epoch_max_tokens` (number, optional, default `500`)
- `debate_skip` (object, optional): Conditions for skipping Critic
  - `enabled` (boolean, optional, default `false`)
  - `conditions` (object, optional)
    - `planner_next_action` (string, optional, default `"implement"`)
    - `no_high_severity_risks` (boolean, optional, default `true`)
    - `matching_success_pattern_count` (number, optional, default `3`)

## `fast_path` extended (`debate_config.json`)

Optional fields (backward-compatible defaults apply when omitted):

- `auto_expansion` (object, optional): Automatic label expansion for consistently successful fast-path tasks
  - `enabled` (boolean, optional, default `true`)
  - `min_success_count` (number, optional, default `5`)
  - `min_confidence` (number, optional, default `0.85`)
  - `max_fail_rate` (number, optional, default `0.2`)
  - `candidate_labels` (string[], optional, default `[]`)
- `stats` (object, optional): Runtime-populated per-label success tracking; empty object by default and safe to omit

## `model_routing` (`debate_config.json`)

Optional fields (backward-compatible defaults apply when omitted):

- `enabled` (boolean, optional, default `false`): Enables heuristic model routing
- `rules` (array, optional, default `[]`): Routing rules with condition/model mappings
  - `condition` (string): Routing condition expression
  - `planner_model` (string): Planner model override when the condition matches
  - `critic_model` (string): Critic model override when the condition matches; may be `"skip"`
  - `comment` (string, optional): Human-readable rationale for the rule
