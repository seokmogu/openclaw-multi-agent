# Orchestrator Slack Commands

Use this file for detailed Slack command and conversational routing. Keep `HEARTBEAT.md` focused on control flow.

## Rules

- All Slack replies are in Korean.
- Slash commands are processed before the heartbeat cycle.
- When a command says **STOP**, clear `cycle_lock` in `/project/state/run_state.json` first.

## Supported Commands

| Command | Action |
|---|---|
| `help` | Show OCMA command list |
| `status` | Summarize run state and backlog counts |
| `pause` | Set `run_state.status = "paused"` |
| `resume` | Set `run_state.status = "running"` and trigger `manual-resume` |
| `run` | Trigger `manual-run` immediately |
| `backlog` | Show up to 10 backlog items grouped by status |
| `add <description>` | Append a new manual backlog task |
| `cancel <task-id>` | Cancel a pending or blocked task |
| `logs [N]` | Show the last N cycle metrics entries |
| `health` | Summarize run state, restart state, disk, backlog counts |
| `config [key] [value]` | View or update supported config keys |
| `merge [PR#|all]` | Merge pending approval PRs |
| `restart` | Trigger graceful container restart |

## Command Details

### `help`

- Reply with the OCMA command list.
- Stop.

### `status`

- Read `/project/state/run_state.json` and `/project/state/backlog.json`.
- Count `pending`, `in_progress`, `completed`, `failed`.
- Reply with current state emoji, cycle count, active task, and backlog summary.
- Stop.

### `pause`

- Set `run_state.status = "paused"`.
- Set `pause_reason = "Slack 명령어로 정지"`.
- Reply with pause confirmation.
- Stop.

### `resume`

- Set `run_state.status = "running"`.
- Set `pause_reason = null`.
- Reply with resume confirmation.
- Trigger:

```text
openclaw system event --mode now --text 'manual-resume: triggered via Slack'
```

- Stop.

### `run`

- Reply with manual cycle confirmation.
- Trigger:

```text
openclaw system event --mode now --text 'manual-run: triggered via Slack'
```

- Stop.

### `backlog`

- Read `/project/state/backlog.json`.
- Group tasks by status and show up to 10 entries.
- Append `...외 {N}개` if more entries exist.
- Stop.

### `add <description>`

- Create task id: `manual-{unix_timestamp}`.
- Append a new task with:
  - `status: "pending"`
  - `priority: "medium"`
  - `priority_score: 0.8`
  - `generated_by: "user:slack"`
- Write `/project/state/backlog.json`.
- Reply with task id and title.
- Stop.

### `cancel <task-id>`

- If task not found: reply not found.
- If task is `pending` or `blocked`: set `status = "cancelled"`, write backlog, reply cancelled.
- If task is terminal: reply already finished.
- If task is `in_progress`: reply that active work cannot be cancelled.
- Stop.

### `logs [N]`

- Read `/project/state/metrics.json`.
- Show the last `N` entries, default `5`.
- Format: `#{cycle_id} | {verdict} | {debate_epochs}에포크 | 신뢰도: {confidence} | 소요: {total_cycle_time_sec}초`.
- Stop.

### `health`

- Read `/project/state/run_state.json`.
- Read `/project/state/restart_state.json`.
- Read `/project/state/backlog.json`.
- Run disk usage command for `/project`.
- Reply with status, cycles, restart count, tool versions, disk usage, and backlog summary.
- Stop.

### `config [key] [value]`

- Supported keys:
  - `discovery_enabled` -> `discovery_config.enabled`
  - `discovery_interval` -> `discovery_config.schedule.discovery_interval_cycles`
  - `max_epochs` -> `debate_config.max_epochs`
  - `convergence_threshold` -> `debate_config.convergence_threshold`
- If no key: show current values.
- If key only: show current value.
- If key + value: validate and update the correct file.
- Reply with before/after summary.
- Stop.

### `merge`, `merge <PR#>`, `merge all`

- Read `/project/state/backlog.json`.
- Select tasks with `pr_status == "pending_approval"`.
- If PR number is given, filter to that PR only.
- For each selected PR:
  - Mark ready with `gh.sh --op pr-ready`.
  - Merge with `gh.sh --op pr-merge --merge-method squash`.
  - Update `pr_status` to `"merged"` on success.
  - Reply success or failure per PR.
- Write backlog.
- Stop.

### `restart`

- Reply with restart notice.
- Trigger:

```text
/project/tools/cli/deploy.sh --op restart --reason slack_command --task-id "manual-restart"
```

- Stop.

## Natural Language Shortcuts

If the message is from Slack, did not match a slash command, and is not a system/cron trigger, check these patterns.

### Merge approvals

- Korean: `머지`, `머지해`, `머지해줘`, `합쳐`, `합쳐줘`, `ㅇㅇ`, `응`, `넹`, `해줘`, `고고`, `진행해`, `승인`
- English: `merge`, `approve`, `lgtm`, `go ahead`, `yes`

Action:

- Read backlog.
- If pending approval PRs exist, handle exactly like `merge all`.
- If none exist, reply that there are no merge-pending PRs.
- Stop.

### Merge rejection / defer

- Korean: `아니`, `취소`, `안해`, `보류`, `나중에`
- English: `no`, `cancel`, `later`, `hold`

Action:

- Reply that merge is being held.
- Stop.

### Unrecognized conversational input

- Reply with: unknown request, use `/ocma help`.
- Stop.

## Event Processing

### GitHub via Slack integration

- PR merged -> mark matching task `completed`, optionally queue follow-up code health.
- PR review with requested changes -> create a high-priority fast-path fix task.
- GitHub issue labeled `ocma-task` -> add backlog task with `generated_by: "webhook:github_issue"`.

### Event workflow

1. Parse the event payload.
2. Update `/project/state/backlog.json`.
3. Post confirmation to Slack.
