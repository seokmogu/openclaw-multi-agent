# Orchestration Heartbeat Cycle

Follow this file as the control-flow source of truth. Keep it small. Detailed recipes live in:

- `/project/host-repo/docs/orchestrator/SLACK_COMMANDS.md`
- `/project/host-repo/docs/orchestrator/SCHEMAS.md`
- `/project/host-repo/docs/orchestrator/OPERATIONS.md`

## Slash Command Processing (Priority Check)

Before any cycle logic, inspect the incoming message.

- If it is a Slack user message, process slash commands and conversational shortcuts using `/project/host-repo/docs/orchestrator/SLACK_COMMANDS.md`.
- If a handler says **STOP**, clear `cycle_lock` in `/project/state/run_state.json` first.
- If no command or shortcut matches, continue to Step 0.

## Step 0: Safety Pre-Check

- Run `/project/scripts/safety-check.sh --state-dir /project/state`.
- Parse the JSON output from stdout.
- If exit code is `1` (unsafe), read `checks` array for the blocking reason:
  - `consecutive_failure` FAIL → discovery was auto-disabled; skip to idle.
  - `stale_lock` BLOCKED → another cycle is active; stop immediately.
  - `self_referential_block` BLOCKED → self-referential tasks were blocked.
  - `priority_ceiling` CAPPED → auto-generated tasks were capped (informational).
- If exit code is `0`, proceed to Step 0.2.
- The script handles all safety enforcement codified from `/project/host-repo/docs/orchestrator/OPERATIONS.md`.

## Step 0.2: Agent Session Preflight

- Read `/project/openclaw.json` agent definitions.
- Skip agents where `enabled` is `false` — do not preflight or dispatch to disabled agents.
- For each enabled agent, verify planner and implementer session availability.
- If sessions are unavailable, switch the whole cycle to CLI fallback.
- Use the session mapping in `AGENTS.md` and the detailed fallback recipe in `/project/host-repo/docs/orchestrator/OPERATIONS.md`.

## Step 0.5: Cycle Lock Check

- Read `/project/state/run_state.json`.
- If `cycle_lock` exists and is fresh, stop immediately.
- If stale, clear it.
- Acquire a fresh lock before proceeding.

## Step 1: Check Run State

- If `status` is `paused` or `stopped`, clear `cycle_lock` and stop.
- If `status` is `running`, update `last_heartbeat_at` and continue.

## Step 1.5: Deadlock Detection

- Detect stale `in_progress` tasks and expired repo leases.
- Reset or fail stale tasks based on retry budget.
- Use the exact deadlock and lease cleanup recipe in `/project/host-repo/docs/orchestrator/OPERATIONS.md`.

## Step 2: Load Configuration

- Read `/project/state/debate_config.json`.
- Load at minimum:
  - `max_epochs`
  - `convergence_threshold`
  - `max_implementation_retries`
  - `max_cycles_without_progress`
  - `anti_loop_enabled`

## Step 2.5: Running Prompt Evolution

- Run `/project/scripts/learning-sync.sh --state-dir /project/state --mark-applied --max-entries 20`.
- Capture stdout as `running_prompt_text`.
- The script reads unapplied entries from `learning_log.json`, groups by type, builds the prompt, and marks entries as applied.
- If output is empty, skip prompt injection.
- See `/project/host-repo/docs/orchestrator/OPERATIONS.md` for the grouping recipe this script implements.

## Step 2.6: Convergence Auto-Tuning

- Analyze recent metrics and tune debate parameters only within bounded ranges.
- Write tuning changes to `/project/state/debate_config.json` and `/project/state/decision_log.md` when needed.
- Use the exact thresholds and bounds in `/project/host-repo/docs/orchestrator/OPERATIONS.md`.

## Step 2.65: Token Budget Init

- Read `token_efficiency` from `/project/state/debate_config.json`.
- Initialize cycle token counter: `{ context: 0, debate: 0, implementation: 0, verification: 0 }`.
- Use `token_budget_per_cycle` as the soft cap for total token usage.
- Token estimation: 1 token ≈ 4 chars (English) or ≈ 2 chars (Korean).

## Step 3: Pick Next Task

- Read `/project/state/backlog.json`.
- Filter out tasks where `blocked_by` contains IDs of tasks not yet `completed`.
- Rank eligible pending tasks by:
  1. `priority_score` when present
  2. priority bucket
  3. older `created_at`
  4. backlog order
- When `parallel_execution.enabled` is true in `debate_config.json`:
  - Select up to `max_parallel_tasks` independent tasks (no mutual `blocked_by` dependencies).
  - Use `sessions_spawn` for parallel tasks targeting different repos.
  - The primary task follows the normal debate cycle; parallel tasks run in background sessions.
- Mark all selected tasks `in_progress`.

If no pending task exists:

- Run discovery fallback only if enabled and due.
- Generate tasks from configured discovery sources.
- Apply duplicate and safety filters before writing.
- Use the detailed discovery recipe in `/project/host-repo/docs/orchestrator/OPERATIONS.md`.

For git tasks:

- Check repo lease in `/project/state/git_state.json` before proceeding.

## Step 4: Post Cycle Start to Slack

- Record `cycle_start_time`.
- Post cycle start message to Slack.

## Step 4.5: Prepare Debate Context

- Assemble a compact context package:
  - selected task
  - `running_prompt_text`
  - `memory_search` results
  - prior epoch summary if any
  - minimal repo context for repo tasks
- Keep context small and focused.
- Use the exact context recipe from `/project/host-repo/docs/orchestrator/OPERATIONS.md`.

## Step 4.55: Hindsight Injection

- Run `/project/scripts/learning-sync.sh --state-dir /project/state --task-tags <comma-separated learning_tags>`.
- Capture stdout — if it contains a `## 관련 실패 교훈 (Hindsight)` block, insert it into Planner context before the task description.
- The script searches `learning_log.json` for entries with `structured_hindsight` where `applicable_patterns` overlaps with the task's `learning_tags`, takes max 3, and builds the block.
- If output is empty or contains no hindsight section, skip this step (no-op).
- Keep total context within `token_efficiency.context_budget_tokens`.
- See `/project/host-repo/docs/orchestrator/OPERATIONS.md` for the hindsight recipe this script implements.

## Step 5: Run Debate (Epoch Loop)

- Respect `maxPingPongTurns`, session timeout handling, and wall-time budget.
- Debate order per epoch:
  1. Planner propose
  2. Critic challenge
  3. Planner revise
  4. Orchestrator decide
- Parse every response using the JSON contract from `/project/host-repo/docs/orchestrator/SCHEMAS.md`.
- **Severity-based convergence**: After Critic challenge, read `severity_score` (0.0–1.0) from Critic JSON.
  - If `severity_score < debate_config.severity_convergence_threshold` (default 0.3) and verdict is `APPROVE`, auto-converge without further epochs.
  - If `severity_score >= 0.7`, the Critic's issues are considered blocking — require Planner revision.
  - Between 0.3–0.7, proceed with normal convergence logic.
- If convergence is reached, proceed to Step 5.5.
- If debate stalls or exceeds limits, tiebreak using the recipe in `/project/host-repo/docs/orchestrator/OPERATIONS.md`.
- Record debate learning at conclusion.

## Step 5.5: Clone Setup (Git Tasks Only)

- Clone target repo with `git.sh`.
- Store `clone_path` and `branch_name` on the task.

## Step 6: Implement

- Post implementation phase notice to Slack.
- Call Implementer with:
  - approved plan
  - task details
  - repo path and branch when applicable
  - required JSON-only response contract

## Step 7: Verify

- Post verification phase notice to Slack.
- Call Verifier with:
  - original task
  - approved plan
  - implementation artifacts
  - repo path and branch when applicable
- Evaluate PASS/FAIL using `convergence_threshold` and retry budget.
- On retry, send only failed checks back to Implementer.

## Step 7.5: Push and Create PR (Git Tasks Only)

- On PASS for git tasks, verify repo status and create PR.
- Store `pr_number`, `pr_url`, `pr_status = "pending_approval"`.
- Post merge approval request to Slack.

## Step 7.6: Extract Learnings from Verification

- Append verifier-derived learning entries to `/project/state/learning_log.json` using the schema in `/project/host-repo/docs/orchestrator/SCHEMAS.md`.
- Use the PASS/FAIL mapping recipe in `/project/host-repo/docs/orchestrator/OPERATIONS.md`.

## Step 7.65: Structured Hindsight Extraction

- If verification verdict is FAIL:
  - Read Verifier response `checks` and `evidence` arrays.
  - Classify failure into category: `logic-error`, `edge-case`, `integration`, `requirement-mismatch`, `test-gap`.
  - Build `structured_hindsight` object: `{ category, root_cause, recommendation, applicable_patterns }`.
  - Attach to the learning_log entry created in Step 7.6.
  - No separate LLM call — derive from Verifier's existing JSON response.
- If verification verdict is PASS, skip this step.
- Use the detailed recipe from `/project/host-repo/docs/orchestrator/OPERATIONS.md`.

## Step 7.7: Self-Deploy (Self-Referential Tasks Only)

- For PASS on `openclaw-multi-agent`, auto-merge eligible PRs and pull the host repo.
- Log and report deployment.
- If merge fails, keep the PR pending approval and stop self-deploy.

## Step 8: Update State and Report

- Update `/project/state/run_state.json`:
  - increment `total_cycles`
  - set `last_cycle_id`
  - set `last_completed_step`
  - update timestamps
  - reset `idle_cycles`
  - clear `cycle_lock`
- Post final cycle status to Slack.
- Append a structured audit trail entry to `/project/state/decision_log.md`.

## Step 8.5: Record Cycle Metrics

- Append one metrics entry to `/project/state/metrics.json` using the schema in `/project/host-repo/docs/orchestrator/SCHEMAS.md`.
- Enforce FIFO retention.

## Step 8.55: Per-Turn Outcome Scoring

- Score each debate turn retroactively based on cycle outcome.
- Base score: PASS+high confidence → 0.8, PASS+low confidence → 0.6, FAIL → 0.3.
- Apply adjustments: tiebreak penalty (-0.1), fast convergence bonus (+0.1), revision quality bonus (+0.1), FAIL attribution penalty (-0.15).
- Clamp all scores to [0.0, 1.0].
- Store as `turn_scores` array in the metrics entry written in Step 8.5.
- Update `fast_path.stats` with task label success/failure data.
- No LLM call — scoring is purely rule-based.
- Use the detailed recipe from `/project/host-repo/docs/orchestrator/OPERATIONS.md`.

## Step 9: Auto-Pause Check

- If no task has progressed to `completed` for `max_cycles_without_progress`, pause and notify Slack.

## Step 9.5: Clone Cleanup

- Remove the completed/failed task clone.
- Remove matching lease and update active clone tracking.

## Step 9.6: Periodic Clone Sweep

- Every 10th cycle, remove orphaned clones and log the cleanup.

## Step 9.7: Self-Trigger Next Cycle

- If pending tasks remain, self-trigger immediately.
- Otherwise, self-trigger only if discovery is due.
- If neither applies, wait for the watchdog cron.

## Step 9.8: Tool Version Check & Graceful Restart

- Reset restart counter.
- Run tool version check.
- If updates are available, post Slack notice and restart gracefully.

## Error Handling

- Validate all agent JSON responses.
- Retry once on `exec`, `sessions_send`, or JSON parsing failure.
- Pause on unrecoverable state corruption or persistent storage failure.
- Use the exact recovery recipes in `/project/host-repo/docs/orchestrator/OPERATIONS.md`.
