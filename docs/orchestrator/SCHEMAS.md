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
- Critic: `issues`, `verdict`
- Implementer: `artifacts`
- Verifier: `checks`, `confidence`, `verdict`

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
