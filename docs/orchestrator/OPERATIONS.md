# Orchestrator Operations Manual

Detailed recipes live here so the bootstrap-loaded docs can stay small.

## Session preflight and fallback

- Required config: `tools.sessions.visibility = "all"`
- Preflight with planner + implementer `PING`
- If either returns forbidden, error, or timeout -> `debate_mode = "cli"`
- CLI fallback mapping:
  - Planner -> `/project/tools/cli/claude.sh`
  - Critic -> `/project/tools/cli/codex.sh`
  - Implementer -> `/project/tools/cli/claude.sh`
  - Verifier -> `/project/tools/cli/gemini.sh`

## Running prompt evolution

- Read `/project/state/learning_log.json`
- Select unapplied entries, newest 20 max
- Group by type into sections:
  - Past failures to avoid
  - Debate patterns observed
  - Critic insights
  - Performance observations
- Build `running_prompt_text`
- Prepend it to debate messages
- Mark used entries `applied: true`

## Convergence auto-tuning

- Read last 10 metrics entries when at least 5 exist
- Compute `avg_epochs`, `convergence_rate`, `tiebreak_rate`, `avg_confidence`, `pass_rate`
- Adjust only within bounds:
  - `max_epochs` in `[2,5]`
  - `convergence_threshold` in `[0.5,0.9]`
- Log tuning changes to `decision_log.md`

## Discovery fallback

When no pending task exists and discovery is enabled:

- Increment `idle_cycles`
- Run discovery only when `idle_cycles % discovery_interval_cycles == 0`
- Sources:
  - `goals_md`
  - `critic_patterns`
  - `verifier_failures`
  - `code_health`
- Apply safety rules before writing tasks:
  - max auto priority cap
  - duplicate detection
  - no self-referential tasks when blocked
- Pick the best discovered task and mark it `in_progress`

## Debate protocol details

### Context assembly

- Selected task
- `running_prompt_text` when present
- `memory_search(query="<task title or terms>", limit=3)`
- Prior epoch summary if any
- Repo structure/config snippets if repo-targeted
- Keep the package under ~4000 tokens

### Debate loop

For each epoch:

1. Planner propose
2. Critic challenge
3. Planner revise
4. Orchestrator decide

Session rules:

- Respect `maxPingPongTurns`
- If nearing turn limit, request a final summary
- If `sessions_send` times out, retry once with a shorter prompt
- If wall time exceeds `max_debate_wall_time_sec`, force tiebreak

Convergence rules:

- Converged if revised `next_action == "implement"`, critic is not blocking, and major issues are addressed
- Critical REJECT -> block task
- Non-critical divergence -> continue or tiebreak

### Debate learning

At debate conclusion, append one `debate_pattern` learning entry for:

- tiebreak
- epoch-1 fast convergence
- multi-epoch convergence

## Implementation and verification

- Clone before implementation for git tasks
- Implementer gets approved plan, task details, repo path, and required JSON contract
- Verifier gets original task, plan, implementation artifacts, and runs tests in clone dir
- PASS -> complete
- FAIL with retries left -> send only failed checks back to implementer, then re-verify
- FAIL with no retries left -> fail task

## PR flow

- On PASS for git task:
  - verify push status
  - create PR
  - store `pr_number`, `pr_url`, `pr_status = "pending_approval"`
  - post Slack approval request

## Verification learnings

- FAIL -> create `verifier_failure` entries from failed checks
- PASS low confidence -> create `performance_metric` entry with low-confidence tag
- PASS high confidence -> create `performance_metric` success entry

## Self-deploy

For `target_repo == "openclaw-multi-agent"` and PASS:

- auto-merge PR
- pull host repo via `deploy.sh --op pull`
- log deployment and post Slack confirmation
- if merge fails, keep PR pending approval and stop self-deploy

## Metrics and maintenance

- Record one metrics entry per cycle in `/project/state/metrics.json`
- Auto-pause if `max_cycles_without_progress` is exceeded
- Cleanup current clone and expired leases
- Every 20th cycle: prune decision log, debate hashes, learning log
- Every 10th cycle: sweep orphaned clones
- Self-trigger next cycle only when pending work or due discovery exists
- After each cycle, run tool version check and restart when updates are available

## Failure recovery

### JSON validation

- Parse JSON response
- Extract JSON block if wrapped in prose
- Retry once on invalid JSON
- Validate required fields and enum values
- On persistent failure, degrade to safe defaults and escalate/fail

### Step failure handling

- `exec` failure -> retry once, then fail task and report
- `sessions_send` failure -> retry once, then fail task and report
- corrupt state file -> attempt recovery, otherwise pause and alert
- disk full -> emergency clone cleanup, retry write, otherwise pause and alert

### Edge cases

- stale `cycle_lock` -> clear and continue
- stale `in_progress` task -> reset or fail based on retry count
- dependency pre-check timeout -> skip task and post tool availability warning
