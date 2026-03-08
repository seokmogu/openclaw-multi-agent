# Orchestration Heartbeat Cycle

You are triggered every 2 minutes by cron. Follow these steps exactly, in order.

## Step 0: Safety Pre-Check

Read `/project/state/discovery_config.json` and `/project/state/backlog.json`.

- `max_consecutive_failures_before_disable = discovery_config.safety.max_consecutive_failures_before_disable ?? 5`
- `max_auto_priority = discovery_config.safety.max_auto_priority ?? 0.9`

Run this quick pre-flight before Step 1:

1. **Consecutive failure tracking**
   - Count consecutive tasks from the end of `/project/state/backlog.json` where `status == "failed"` until the first non-failed task.
   - If `discovery_config.enabled == true` AND consecutive failures `>= max_consecutive_failures_before_disable`:
     - Set `enabled` to `false` in `/project/state/discovery_config.json`.
     - Post to Slack: `"SAFETY: Auto-disabled discovery after {N} consecutive failures. Manual review required."`
     - Append the same event to `/project/state/decision_log.md`.

2. **Self-referential task check**
   - Inspect the next pending task (`status == "pending"`, first by backlog order).
   - Treat as self-referential if `target_repo == "openclaw-multi-agent"` OR `title`/`description` references OCMA itself (keywords: `"openclaw-multi-agent"`, `"ocma"`, `"orchestrator"`, `"heartbeat"`, `"agent"`).
   - For each self-referential match:
     - Set `status` to `"cancelled"`.
     - Set `error` to `"Safety: self-referential task blocked"`.
     - Post to Slack: `"SAFETY: Blocked self-referential task: {title}"`.
     - Continue scanning for the next pending task.
   - Write updated `/project/state/backlog.json` if any task was cancelled.

3. **Priority ceiling check**
   - On the next pending task selected after safety filtering: if `generated_by` starts with `"discovery:"` AND `priority_score > max_auto_priority`:
     - Cap `priority_score` to `max_auto_priority`.
     - Append to `/project/state/decision_log.md`: `"Priority capped from {original} to {max}"`.
     - Write updated `/project/state/backlog.json`.

## Step 1: Check Run State

Read `/project/state/run_state.json`.

- If `status` is `"stopped"` or `"paused"` → **STOP immediately**. Do nothing else.
- If `status` is `"running"` → proceed to Step 2.
- Write `last_heartbeat_at: <current ISO 8601 timestamp>` to `/project/state/run_state.json`.

## Step 1.5: Deadlock Detection

Define constants:

- `DEADLOCK_STALE_SECONDS = 1800` (30 minutes)
- `DEFAULT_MAX_IMPLEMENTATION_RETRIES = 2`

Load retry limit for deadlock handling:

1. Read `/project/state/debate_config.json`.
2. Set `max_implementation_retries = debate_config.max_implementation_retries ?? DEFAULT_MAX_IMPLEMENTATION_RETRIES`.

Write a heartbeat proof-of-life timestamp:

- Write `last_heartbeat_at` in `/project/state/run_state.json` with current ISO 8601 timestamp.

Check stale in-progress tasks:

1. Read `/project/state/backlog.json`.
2. Scan tasks where `status == "in_progress"` and `started_at` is present.
3. Compare current time vs `started_at`; treat task as stale when elapsed seconds > `DEADLOCK_STALE_SECONDS`.
4. For each stale task:
   - If `retry_count < max_implementation_retries`:
     - Set `status` to `"pending"`
     - Increment `retry_count` by 1
     - Append deadlock reset event to `/project/state/decision_log.md`
     - Post to Slack: `"DEADLOCK detected | Task: [title] | Action: reset"`
   - If `retry_count >= max_implementation_retries`:
     - Set `status` to `"failed"`
     - Set `error` to `"Deadlock: task stuck in_progress for >30min"`
     - Release git lease in `/project/state/git_state.json` if the task holds one
     - Append deadlock failure event to `/project/state/decision_log.md`
     - Post to Slack: `"DEADLOCK detected | Task: [title] | Action: failed"`
5. Write updated `/project/state/backlog.json`.

Clean expired git leases:

1. Read `/project/state/git_state.json`.
2. For each lease in `active_leases`, treat it as expired when `started_at + ttl_seconds < now`.
3. Remove expired leases from `active_leases`.
4. Write updated `/project/state/git_state.json`.

## Step 2: Load Configuration

Read `/project/state/debate_config.json`. Store the following parameters:

- `max_epochs` (default: 3)
- `convergence_threshold` (default: 0.7)
- `max_implementation_retries` (default: 2)
- `max_cycles_without_progress` (default: 5)
- `anti_loop_enabled` (default: true)

## Step 2.5: Running Prompt Evolution

This step prepends accumulated learnings to agent prompts before any debate begins.

1. Read `/project/state/learning_log.json`.
2. Filter entries where `applied == false`.
3. If there are no unapplied learnings, skip this step (no prompt evolution needed).
4. If more than 20 unapplied learnings exist, keep only the most recent 20.
5. Group unapplied learnings by `type`:
   - `verifier_failure` -> `Past failures to avoid`
   - `debate_pattern` -> `Debate patterns observed`
   - `critic_insight` -> `Critic insights`
   - `performance_metric` -> `Performance observations`
6. Format a running appendix block:

   ```text
   === RUNNING PROMPT (auto-generated from past learnings) ===

   ## Past Failures to Avoid
   - {content from verifier_failure entries}

   ## Debate Patterns Observed
   - {content from debate_pattern entries}

   ## Critic Insights
   - {content from critic_insight entries}

   ## Performance Observations
   - {content from performance_metric entries}

   === END RUNNING PROMPT ===
   ```

7. Store this block as `running_prompt_text` for use in Step 4 and Step 5:
   - When calling `sessions_send(agent="planner", ...)` or `sessions_send(agent="critic", ...)`, prepend `running_prompt_text` to the message body.
   - This provides past learnings without modifying any `AGENTS.md` files.
8. Mark all used learnings as `applied: true` and write the updated `/project/state/learning_log.json`.
9. Log: `Running prompt evolved with {N} new learnings ({types})`, where `{types}` lists included types (for example: `verifier_failure, debate_pattern`).

Key design decisions:

- Learnings are prepended to `sessions_send` messages, not baked into `AGENTS.md`.
- Each learning is applied once (marked `applied: true` after use).
- Running prompt is rebuilt fresh each cycle from unapplied learnings.

## Step 2.6: Convergence Auto-Tuning

This step analyzes recent metrics to auto-adjust debate parameters.

1. Read `/project/state/metrics.json`.
2. If fewer than 5 entries exist, skip this step (not enough data for tuning).
3. Take the last 10 entries (or all entries if fewer than 10).
4. Compute:
   - `avg_epochs = mean(debate_epochs)`
   - `convergence_rate = count(convergence_achieved == true) / total`
   - `tiebreak_rate = count(tiebreak_used == true) / total`
   - `avg_confidence = mean(verification_confidence)` excluding `null`
   - `pass_rate = count(verification_verdict == "PASS") / total`
5. Read current values from `/project/state/debate_config.json`, then apply tuning rules:

   - **Rule 1: Increase `max_epochs` if tiebreak frequency is high**
     - If `tiebreak_rate > 0.4` and `max_epochs < 5`, set `max_epochs = max_epochs + 1`.
     - Log: `Auto-tuning: Increased max_epochs to {new_value} (tiebreak_rate={tiebreak_rate})`.

   - **Rule 2: Decrease `max_epochs` if convergence is consistently fast**
     - If `avg_epochs < 1.5` and `convergence_rate > 0.8` and `max_epochs > 2`, set `max_epochs = max_epochs - 1`.
     - Log: `Auto-tuning: Decreased max_epochs to {new_value} (fast convergence)`.

   - **Rule 3: Lower `convergence_threshold` when pass rate is low**
     - If `pass_rate < 0.5` and `convergence_threshold > 0.5`, set `convergence_threshold = convergence_threshold - 0.05`.
     - Log: `Auto-tuning: Lowered convergence_threshold to {new_value} (low pass_rate={pass_rate})`.

   - **Rule 4: Raise `convergence_threshold` when quality is consistently high**
     - If `pass_rate > 0.9` and `avg_confidence > 0.85` and `convergence_threshold < 0.9`, set `convergence_threshold = convergence_threshold + 0.05`.
     - Log: `Auto-tuning: Raised convergence_threshold to {new_value} (high quality)`.

6. If any parameter changed:
   - Write updated `/project/state/debate_config.json`.
   - Post to Slack: `Auto-tuning: adjusted {params_changed}`.
7. If no changes are needed, log: `Auto-tuning: parameters optimal (convergence_rate={rate}, pass_rate={rate})`.

Key design decisions:

- Require at least 5 cycles of metrics data before tuning.
- Only one rule per parameter fires per cycle (first matching rule wins).
- Enforce hard bounds: `max_epochs` in `[2, 5]`, `convergence_threshold` in `[0.5, 0.9]`.
- Append tuning changes to `/project/state/decision_log.md` for audit traceability.

## Step 3: Pick Next Task

Read `/project/state/backlog.json`. Find the first task with `"status": "pending"` (ordered by array position).

- If pending task found:
  - Set `selected_task` to that first pending task.
  - Set `selected_task.status` to `"in_progress"` and `selected_task.assigned_to` to `"orchestrator"`.
  - Write the updated backlog back.
- If **no pending task** found, run discovery fallback:

1. Read `/project/state/discovery_config.json`.
2. If `enabled == false`:
   - Post to Slack: `"No pending tasks. Discovery disabled. Idle."`
   - **STOP**
3. If `enabled == true`:
   - Read `/project/state/run_state.json` and get `total_cycles`.
   - Read `schedule.discovery_interval_cycles` and `schedule.max_auto_tasks_per_discovery`.
   - Run discovery only when `total_cycles % schedule.discovery_interval_cycles == 0`.
   - If it is not a discovery cycle:
     - Compute `cycles_until_discovery = schedule.discovery_interval_cycles - (total_cycles % schedule.discovery_interval_cycles)`.
     - Post to Slack: `"No pending tasks. Next discovery in {cycles_until_discovery} cycles. Idle."`
     - **STOP**

4. Initialize discovery state:
   - `generated_tasks = []`
   - `generated_sources = []`
   - `max_auto_tasks = schedule.max_auto_tasks_per_discovery`
   - `now_iso = <current ISO 8601 timestamp>`
   - Keep using the in-memory `backlog` already read in this step for duplicate checks and source context.

5. Run enabled discovery sources in this order, and stop generating when `generated_tasks.length >= max_auto_tasks`:
   - When a source generates one or more tasks, append its source key (`goals_md`, `critic_patterns`, `verifier_failures`, `code_health`) to `generated_sources` once.

   - **Source 1: goals_md** (if `sources.goals_md.enabled`):
     - Read `/project/state/goals.md`.
     - Extract bullet points under `## Active Goals`.
     - For each goal bullet:
       - Check backlog for a similar task (simple case-insensitive text similarity against task `title` and `description`).
       - If no similar task exists, create a new backlog task with:
         - `id`: `"auto-{unix_timestamp}-goals_md"`
         - `title`: concise task title derived from the goal
         - `description`: implementation-oriented expansion of the goal
         - `status`: `"pending"`
         - `priority`: `"medium"`
         - `assigned_to`: `null`
         - `created_at`: `now_iso`
         - `updated_at`: `now_iso`
         - `started_at`: `null`
         - `retry_count`: `0`
         - `fast_path`: `false`
         - `generated_by`: `"discovery:goals_md"`
         - `source_task_id`: `null`
         - `learning_tags`: `["goals", "auto-discovery"]`
         - `priority_score`: `0.7`

   - **Source 2: critic_patterns** (if `sources.critic_patterns.enabled`):
     - Read `/project/state/learning_log.json`.
     - Select entries where `type == "debate_pattern"` and `tags` contains `"tiebreak"`.
     - Group similar entries by normalized `content` pattern.
     - For each pattern with count `>= 2`, create one hardening task with:
       - `id`: `"auto-{unix_timestamp}-critic_patterns"`
       - `generated_by`: `"discovery:critic_patterns"`
       - `priority_score`: `0.6`
       - `fast_path`: `false`
       - `source_task_id`: source task id from the most recent grouped learning entry (or `null`)
       - `learning_tags`: grouped tags + `"critic-pattern"`

   - **Source 3: verifier_failures** (if `sources.verifier_failures.enabled`):
     - Read `/project/state/learning_log.json`.
     - Select entries where `type == "verifier_failure"` and `applied == false`.
     - Group failures by similar `tags` signatures.
     - For each grouped failure pattern with count `>= 2`, create one fix task with:
       - `id`: `"auto-{unix_timestamp}-verifier_failures"`
       - `generated_by`: `"discovery:verifier_failures"`
       - `priority_score`: `0.8`
       - `fast_path`: `false`
       - `source_task_id`: source task id from the most recent grouped learning entry (or `null`)
       - `learning_tags`: grouped tags + `"recurring-failure"`
     - For learning entries used to generate these tasks, set `applied: true`.
     - Write updated `/project/state/learning_log.json`.

   - **Source 4: code_health** (if `sources.code_health.enabled`):
     - From backlog, collect unique `target_repo` values from tasks where `status == "completed"`.
     - For each repo, create a code health task to run linting/testing with:
       - `id`: `"auto-{unix_timestamp}-code_health"`
       - `generated_by`: `"discovery:code_health"`
       - `priority_score`: `0.5`
       - `fast_path`: `false`
       - `source_task_id`: `null`
       - `learning_tags`: `["code-health", "maintenance", "auto-discovery"]`
       - `target_repo`: completed task repo
       - `github_repo`: corresponding repo if known

6. Apply safety rules before writing any generated task:
   - Apply `safety.max_auto_priority` cap to each `priority_score` (example: `min(priority_score, safety.max_auto_priority)`, with configured cap `0.9`).
   - Apply `safety.duplicate_detection`: skip tasks whose `title`/`description` is similar to any existing backlog entry or already-generated task in this cycle.
   - Apply `safety.no_self_referential_tasks`: skip tasks targeting the OCMA repo itself (for example `target_repo == "openclaw-multi-agent"` or matching `github_repo`).
   - Ensure each accepted generated task includes backlog schema fields, including auto-discovery fields: `generated_by`, `source_task_id`, `learning_tags`, `priority_score`, and `status: "pending"`.

7. Finalize discovery:
   - Set `N = generated_tasks.length`.
   - Set `sources = generated_sources.join(", ")`.
   - Append accepted generated tasks to `/project/state/backlog.json`.
   - Write updated backlog file.
   - Post to Slack: `"Discovery: generated {N} new task(s) from {sources}"`.
   - If `N == 0`: post `"No pending tasks after discovery. Idle."` and **STOP**.

8. Pick discovered task for execution:
   - Select the generated task with highest `priority_score` (tie-break by generation order) and store as `selected_task`.
   - Set `selected_task.status` to `"in_progress"` and `selected_task.assigned_to` to `"orchestrator"`.
   - Write updated `/project/state/backlog.json`.

If the selected task has `target_repo` and `github_repo` fields (non-null):
- Check repo lease in `/project/state/git_state.json`
- If leased by another active task → skip this task, find next pending task
- If not leased → write lease and proceed

## Step 4: Post Cycle Start to Slack

Record `cycle_start_time = <current ISO 8601 timestamp>` for `total_cycle_time_sec` calculation in Step 8.5.

```
exec(command="openclaw message send --channel slack --target \"C0AK4MVUELA\" --message \"Cycle start | Task: [task.title] | ID: [task.id]\"", timeout=15)
```

## Step 4.5: Prepare Debate Context

Before starting the debate, assemble a focused context package to keep token usage efficient:

1. **Task context**: Read the selected task from backlog (already in memory from Step 3).
2. **Running prompt**: If `running_prompt_text` was built in Step 2.5, it will be prepended to debate messages.
3. **Memory search**: Use `memory_search(query="<task title or key terms>", limit=3)` to find relevant past conversations about similar tasks.
4. **Prior epoch summary** (multi-epoch only): If this task already has `debate_epochs > 0`, read the last epoch summary from `/project/state/decision_log.md`. Summarize it in 200 words or less — do NOT pass the full debate history.
5. **Repository context** (repo-targeted tasks only): If the task has `clone_path`, use `read` to get:
   - Project structure (top-level directory listing)
   - Key config files (`package.json`, `pyproject.toml` — first 50 lines only)
   - Files mentioned in the task description

Store all assembled context as `debate_context` for use in Step 5.

**Context budget**: Keep total context under 4000 tokens. Summarize aggressively — agents can use `read` to get details during the debate.

## Step 5: Run Debate (Epoch Loop)

### Session Management

Before each `sessions_send` call in the debate:

1. **maxPingPongTurns limit**: Each session is limited to 5 turns (`maxPingPongTurns: 5` in openclaw.json). Track turn count per session.
   - If approaching the limit (turn 4+), include a summarization prompt: "This is the final turn. Provide your complete analysis in this response."
   - When the limit is reached mid-epoch, start a new session with context from the previous session summary. Do NOT continue the saturated session.

2. **Session timeout handling**: If `sessions_send` times out (600 second `runTimeoutSeconds`):
   - Log: "Session timeout for {agent} on epoch {N}."
   - Retry once with a shorter prompt (summarize context to 50% of original).
   - If retry also times out, force tiebreak for this debate.

3. **Epoch rollover**: When starting a new epoch after an inconclusive previous epoch:
   - Summarize the previous epoch in max 300 words: key points of agreement, key disagreements, and unresolved risks.
   - Pass ONLY this summary (not full transcript) to the new epoch's sessions.
   - This prevents context window overflow across multi-epoch debates.

Record `debate_start_time = <current ISO 8601 timestamp>` when debate begins.

**Wall-Time Timeout**: At the start of each epoch, check if elapsed wall-time exceeds `max_debate_wall_time_sec` from debate_config.json (default: 600 seconds). If exceeded, force tiebreak immediately with tag `[WALL-TIME-EXCEEDED]` and proceed to Step 6.

### Fast-Path Check
If the task has `"fast_path": true`:
1. Skip the entire debate epoch loop
2. Call Planner once for a plan (no challenge/revise):
   ```
   sessions_send(agent="planner", message="Create a plan for: [task]. No debate needed. Respond with JSON.", timeout=120)
   ```
3. Proceed directly to Step 5.5 (Clone Setup)

Initialize: `epoch = 1`, `previous_context = null`

### For each epoch (while epoch <= max_epochs):

#### 5a. PROPOSE — Call Planner

```
sessions_send(agent="planner", message="...", timeout=120)
```

Message must include:
- Role: "propose"
- Task description from backlog entry
- Context from `/project/state/goal.md` (if non-empty)
- Previous epoch summary (if epoch > 1)
- Explicit instruction: "Respond with JSON only. Required fields: claim, evidence, risk, next_action, options, recommended, subtasks."

Parse Planner's response as JSON. If parsing fails, retry once with: "Your response was not valid JSON. Respond with ONLY a JSON object, no markdown fences, no explanation."

#### 5b. CHALLENGE — Call Critic

```
sessions_send(agent="critic", message="...", timeout=120)
```

Message must include:
- Role: "challenge"
- Planner's full JSON proposal
- Explicit instruction: "Review this proposal adversarially. Respond with JSON only. Required fields: claim (start with APPROVE/REVISE/REJECT), evidence, risk, next_action, issues, verdict."

Parse Critic's response as JSON.

#### 5c. REVISE — Call Planner

```
sessions_send(agent="planner", message="...", timeout=120)
```

Message must include:
- Role: "revise"
- Planner's original proposal
- Critic's full feedback
- Explicit instruction: "Address the Critic's concerns. Mark each criticism as accepted or rebutted with reasoning. Respond with JSON only. Required fields: claim, evidence, risk, next_action, options, recommended, subtasks."

Parse Planner's revised response as JSON.

#### 5d. DECIDE — Evaluate Convergence (Internal)

Check convergence:
- **Converged** if: Planner's revised `next_action == "implement"` AND Critic's verdict is not `"REJECT"` AND all Critic's major issues are addressed in the revision.
- **Escalate** if: any agent's `next_action == "escalate"` → post to Slack requesting user input, set task `status` to `"blocked"`, **STOP**.

If **converged** → write epoch summary to `/project/state/decision_log.md`, proceed to Step 6.

If Critic's `verdict == "REJECT"`:
- Check Critic `issues` for at least one item with `severity == "critical"`.
- If at least one critical issue exists:
  - Set task `status` to `"blocked"`
  - Set `block_reason` to Critic's `claim`
  - Write REJECT block decision to `/project/state/decision_log.md`
  - Post to Slack: `"BLOCKED | Task: [task.title] | Critic REJECT: [claim summary]"`
  - **STOP**
- If no critical issue exists: treat this as REVISE (downgrade REJECT to REVISE) and continue to next epoch.

If **not converged**:
1. Write epoch summary to `/project/state/decision_log.md` using the template:

```markdown
## Epoch {N} Summary — {task.id}
- **Task**: {task.title}
- **Proposed**: {Planner claim summary}
- **Challenged**: {Critic claim summary}
- **Revised**: {Revised claim summary}
- **Status**: diverged
- **Open Issues**: {list unresolved issues}
```

2. **Anti-loop check** (if `anti_loop_enabled`):
   - Compute hash: `SHA256(revised.claim + revised.next_action)`
   - Read `/project/state/debate_hashes.json`
   - If hash already exists → **STALE DEBATE**. Force tiebreak: pick the approach with lowest aggregate risk across all epochs. Tag decision as `[TIE-BREAK]`. Proceed to Step 6.
   - If hash is new → add it to the hashes file and continue.

3. Set `previous_context` = epoch summary text. Increment `epoch`. Continue loop.

If **epoch > max_epochs** and still not converged:
- If Critic's final-epoch `verdict == "REJECT"` and Critic `issues` include at least one `severity == "critical"` issue: do NOT tiebreak. Set task `status` to `"blocked"`, set `block_reason` to Critic's `claim`, write to `/project/state/decision_log.md`, post to Slack `"BLOCKED | Task: [task.title] | Critic REJECT: [claim summary]"`, and **STOP**.
- If Critic's final-epoch verdict is `"APPROVE"` or `"REVISE"`, or `"REJECT"` without any critical issue → force tiebreak (same as stale debate). Proceed to Step 6.

#### 5e. RECORD DEBATE LEARNING (after convergence or tiebreak)

This sub-step runs ONLY when the debate is concluding (convergence reached, tiebreak forced, or REJECT block):

1. **If tiebreak was used**: record a learning entry
   - Type: `"debate_pattern"`
   - Content: `"Task {task.id}: Debate required tiebreak after {epoch} epochs. Planner approach: {planner.claim}. Critic concern: {critic.claim}. Resolution: tiebreak on {tiebreak_strategy}"`
   - Tags: task's `learning_tags` + `["tiebreak"]`

2. **If converged in epoch 1**: record a positive learning
   - Type: `"debate_pattern"`
   - Content: `"Task {task.id}: Fast convergence in epoch 1. Planner and Critic aligned on: {revised.claim}"`
   - Tags: task's `learning_tags` + `["fast_convergence"]`

3. **If converged after epoch > 1**: record the evolution pattern
   - Type: `"debate_pattern"`
   - Content: `"Task {task.id}: Convergence after {epoch} epochs. Key Critic insight that improved plan: {critic's most impactful issue}"`
   - Tags: task's `learning_tags` + `["multi_epoch"]`

4. **Store in learning_log.json** using the same read/append/FIFO/write pattern as Step 8.5:
   - Read `/project/state/learning_log.json`
   - Append new entry: `{id: "learning-{timestamp}", task_id: task.id, type: "debate_pattern", content: "...", tags: [...], created_at: <ISO 8601>, applied: false}`
   - If total entries > 200: remove oldest entries (FIFO) until count = 200
   - Write updated file

## Step 5.5: Clone Setup (Git Tasks Only)

If the task has `target_repo` (non-null):

1. Clone the target repository:
   ```
   exec(command="/project/tools/cli/git.sh --op clone --repo \"<task.target_repo>\" --github-repo \"<task.github_repo>\" --task-id \"<task.id>\"", timeout=120)
   ```
2. Store clone_path in the task: `"/project/workspaces/.clones/<task.id>/<task.target_repo>"`
3. Set branch_name: `"ocma/<task.id>"`
4. Update backlog.json with clone_path and branch_name

If the task has NO target_repo → skip this step (non-git task, backward compatible).

## Step 6: Implement

Post to Slack:
```
exec(command="openclaw message send --channel slack --target \"C0AK4MVUELA\" --message \"Task: [task.title] | Phase: IMPLEMENT | Sending to Implementer\"", timeout=15)
```

Call Implementer:
```
sessions_send(agent="implementer", message="...", timeout=120)
```

Message must include:
- Clone path and branch name (if git task): `clone_path`, `branch_name`, `github_repo`
- The Implementer must use `--cwd <clone_path>` for all CLI tool calls
- The approved plan (final Planner JSON or tiebreak decision)
- Task description and target files/paths
- Full debate summary (all epoch summaries)
- Explicit instruction: "Implement the approved plan. Respond with JSON only. Required fields: claim, evidence, risk, next_action, artifacts."

Parse Implementer's response as JSON.

## Step 7: Verify

Post to Slack:
```
exec(command="openclaw message send --channel slack --target \"C0AK4MVUELA\" --message \"Task: [task.title] | Phase: VERIFY | Sending to Verifier\"", timeout=15)
```

Call Verifier:
```
sessions_send(agent="verifier", message="...", timeout=120)
```

Message must include:
- Clone path and branch name (if git task): `clone_path`, `branch_name`
- The Verifier runs all tests inside the clone directory
- Original task description
- Approved plan
- Implementer's response (artifacts, changes made)
- Explicit instruction: "Verify the implementation against requirements. Respond with JSON only. Required fields: claim (PASS or FAIL with summary), evidence, risk, next_action, checks, confidence, verdict."

Parse Verifier's response as JSON.

### Evaluate Verification Result

- If `confidence >= convergence_threshold` AND `verdict == "PASS"`:
  - Mark task `status` to `"completed"` in backlog
  - Write result summary to `/project/state/decision_log.md`
  - Proceed to Step 8

- If `verdict == "FAIL"` AND `task.retry_count < max_implementation_retries`:
  - Increment `task.retry_count` in backlog
  - Extract failed checks from `verifier.checks` where `status != "PASS"` and capture each item's `name`, `status`, and `output`
  - Build a structured feedback payload for Implementer containing:
    - Original task description
    - Failed checks only (`name`, `status`, `output`)
    - Verifier `evidence`
    - Verifier `risk`
    - Explicit instruction: `"Fix ONLY the failed checks. Do NOT refactor or change code that passed verification."`
  - Send this payload to Implementer via:
    ```
    sessions_send(agent="implementer", message="Verification failed. Retry implementation with this feedback: {task_description, failed_checks, verifier_evidence, verifier_risk, instruction}. Respond with JSON only. Required fields: claim, evidence, risk, next_action, artifacts.", timeout=120)
    ```
  - Parse Implementer's retry response as JSON
  - Re-run verification explicitly by calling Verifier again with the same Step 7 input contract (original task description, approved plan, and latest Implementer response) via `sessions_send(agent="verifier", ...)` and re-evaluate Step 7 outcomes

- If `verdict == "FAIL"` AND `task.retry_count >= max_implementation_retries`:
  - Mark task `status` to `"failed"` in backlog
  - Write failure summary to `/project/state/decision_log.md`
  - Proceed to Step 8

## Step 7.5: Push and Create PR (Git Tasks Only)

If the task has `target_repo` AND `verdict == "PASS"`:

1. The Implementer already pushed during implementation. Verify:
   ```
   exec(command="/project/tools/cli/git.sh --op status --repo \"<repo>\" --task-id \"<task.id>\"", timeout=15)
   ```

2. Create a draft PR:
   ```
   exec(command="/project/tools/cli/gh.sh --op pr-create --github-repo \"<task.github_repo>\" --branch \"ocma/<task.id>\" --base-branch \"<task.base_branch>\" --title \"[OCMA] <task.title>\" --body \"## Task\\n<task.description>\\n\\n## Changes\\n<implementer.artifacts summary>\\n\\n## Verification\\n<verifier.checks summary>\\n\\nGenerated by OCMA\" --task-id \"<task.id>\"", timeout=30)
   ```

3. Store PR metadata in backlog: `pr_number`, `pr_url`
4. Post to Slack: "✅ PR created: <pr_url>"

If the task has NO target_repo → skip (non-git task).
If `verdict == "FAIL"` → skip PR creation (proceed to retry or fail).

## Step 7.6: Extract Learnings from Verification

Run after **EVERY** verification result (both PASS and FAIL), before Step 8.

1. Read `/project/state/learning_log.json`.
2. Build learning entries using the Learning Log Entry Schema in `/project/agents/orchestrator/AGENTS.md` (`id`, `task_id`, `type`, `content`, `tags`, `created_at`, `applied`).
3. Extract based on verifier outcome:
   - If `verdict == "FAIL"`: for each failed check in `verifier.checks` where `status != "PASS"`, create:
     - `type`: `"verifier_failure"`
     - `content`: `"Task {task.id}: {check.name} failed — {check.output}"`
     - `tags`: `<task.learning_tags> + ["failure"]`
   - If `verdict == "PASS"` and `confidence < 0.85`, create:
     - `type`: `"performance_metric"`
     - `content`: `"Task {task.id}: Passed with low confidence ({confidence}). Risks: {verifier.risk}"`
     - `tags`: `<task.learning_tags> + ["low_confidence"]`
   - If `verdict == "PASS"` and `confidence >= 0.85`, create:
     - `type`: `"performance_metric"`
     - `content`: `"Task {task.id}: High-confidence pass. Approach: {plan.recommended}"`
     - `tags`: `<task.learning_tags> + ["success"]`
4. For each new entry:
   - `id`: `"learning-{unix_timestamp}"`
   - `task_id`: `task.id`
   - `created_at`: current ISO 8601 timestamp
   - `applied`: `false`
5. Append entry/entries to `entries`.
6. If `entries.length > max_entries`, remove oldest entries first (FIFO) until within limit.
7. Write updated `/project/state/learning_log.json`.

## Step 8: Update State and Report

1. Read `/project/state/run_state.json`
2. Increment `total_cycles` by 1
3. Set `last_cycle_id` to the task ID
4. Set `last_completed_step` to the final phase reached (e.g., "verify-pass", "verify-fail", "debate-escalated")
5. Set `last_updated` to current ISO 8601 timestamp
6. Write updated run_state back

Post final status to Slack:
```
exec(command="openclaw message send --channel slack --target \"C0AK4MVUELA\" --message \"Cycle complete | Task: [task.title] | Result: [completed/failed/escalated] | Total cycles: [N]\"", timeout=15)
```

### Audit Trail

After updating state files, append a structured audit entry to `/project/state/decision_log.md`:

```markdown
### Cycle {total_cycles} — {ISO timestamp}
- **Task**: {task_id} — {task_title}
- **Debate**: {debate_epochs} epochs, convergence={yes/no}, tiebreak={yes/no}
- **Decision**: {brief summary of approved plan, max 50 words}
- **Implementation**: {files_changed} files, {insertions}+ {deletions}-
- **Verification**: {verdict} (confidence: {confidence})
- **Outcome**: {completed/failed/retrying}
- **Duration**: {total_cycle_time_sec}s
```

This structured format enables automated parsing for trend analysis and post-mortems.

## Step 8.5: Record Cycle Metrics

Use the metrics entry schema from Orchestrator `AGENTS.md` (`cycle_id`, `timestamp`, `debate_epochs`, `debate_wall_time_sec`, `convergence_achieved`, `tiebreak_used`, `verification_verdict`, `verification_confidence`, `retry_count`, `total_cycle_time_sec`).

1. Build a new metrics entry for the cycle that just finished:
   - `cycle_id`: `task.id`
   - `timestamp`: current ISO 8601 timestamp
   - `debate_epochs`: debate epoch counter used this cycle
   - `debate_wall_time_sec`: elapsed seconds from `debate_start_time` (recorded in Step 5) to now
   - `convergence_achieved`: `true` if debate converged before `max_epochs`; otherwise `false`
   - `tiebreak_used`: `true` if any forced tiebreak path was used; otherwise `false`
   - `verification_verdict`: `"PASS"`, `"FAIL"`, or `"N/A"` (use `"N/A"` for escalated/blocked tasks)
   - `verification_confidence`: Verifier confidence score, or `null`
   - `retry_count`: `task.retry_count`
   - `total_cycle_time_sec`: elapsed seconds from `cycle_start_time` (recorded in Step 4) to now
2. Read `/project/state/metrics.json`.
3. Append the new metrics entry to `entries`.
4. Enforce FIFO cap using `max_entries = 200`: if `entries.length > max_entries`, remove oldest entries until length is `max_entries`.
5. Write the updated metrics object back to `/project/state/metrics.json`.

## Step 9: Auto-Pause Check

Read `/project/state/run_state.json`.

Count consecutive cycles where no task moved to `"completed"`. If this count >= `max_cycles_without_progress`:

1. Set `status` to `"paused"` in run_state
2. Set `pause_reason` to `"Auto-paused: {N} cycles without progress"`
3. Write updated run_state
4. Post to Slack: "Auto-paused after {N} cycles without progress. Resume manually."

## Step 9.5: Clone Cleanup

For the task just completed:
1. If task has `clone_path` → `exec(command="rm -rf <clone_path>", timeout=15)`
2. Remove lease from `/project/state/git_state.json`
3. Update `active_clones` array in `git_state.json`

### Memory and State Maintenance (every 20th cycle)

If `total_cycles % 20 == 0`:

1. **Decision log pruning**: Read `/project/state/decision_log.md`. If it exceeds 500 lines, keep only the last 300 lines. Write the pruned file.
2. **Debate hash cleanup**: Read `/project/state/debate_hashes.json`. Remove entries older than 7 days (compare against timestamps). Write updated file.
3. **Learning log compaction**: Read `/project/state/learning_log.json`. If entries exceed `max_entries` (200), remove oldest entries until at `max_entries`. All overflow entries should already be `applied: true`; if any are not, log a warning.
4. Log: "Maintenance: pruned decision_log to {lines} lines, cleaned {N} stale hashes, compacted learning_log to {count} entries."

## Step 9.6: Periodic Clone Sweep

**Gate**: Read `total_cycles` from `/project/state/run_state.json`. If `total_cycles % 10 != 0` → skip this step.

If `total_cycles % 10 == 0`:

1. List all directories in `/project/workspaces/.clones/`
2. For each clone directory (task-id):
   - Read `/project/state/backlog.json`
   - Search for a task with `id == task-id` and `status` in `["in_progress", "pending"]`
   - If no matching active task exists → the clone is orphaned
3. For each orphaned clone:
   ```
   exec(command="rm -rf /project/workspaces/.clones/<task-id>", timeout=15)
   ```
4. Count deleted clones. If count > 0:
   - Append to `/project/state/decision_log.md`: `"Periodic sweep (cycle {total_cycles}): removed {count} orphaned clone(s)"`
   - Post to Slack: `"Sweep: removed {count} orphaned clone(s)"`

## Error Handling

### JSON Response Validation

After EVERY `sessions_send` call, validate the agent response:

1. **Parse check**: Attempt to parse the response as JSON.
   - If the response is not valid JSON: extract any JSON block from the response text (look for `{...}` patterns).
   - If no JSON found: retry with explicit instruction: "Respond with ONLY a JSON object. No markdown, no explanatory text."
   - If retry also fails: log raw response to decision_log.md and treat as agent failure.

2. **Schema check**: Validate required fields exist:
   - ALL agents: `claim` (string), `evidence` (array), `risk` (array), `next_action` (string)
   - Planner: additionally `options` (array), `recommended` (string), `subtasks` (array)
   - Critic: additionally `issues` (array), `verdict` (string matching APPROVE|REVISE|REJECT)
   - Implementer: additionally `artifacts` (array)
   - Verifier: additionally `checks` (array), `confidence` (number 0-1), `verdict` (string matching PASS|FAIL)

3. **Value validation**:
   - `next_action` must be one of: `implement`, `revise`, `escalate`, `verify`
   - `confidence` must be between 0.0 and 1.0
   - `verdict` must match expected enum values
   - Arrays must not be empty

4. **On validation failure**: Log which field failed, retry once with field-specific correction prompt. If still fails, use default values: `confidence: 0.3`, `verdict: "FAIL"`, `next_action: "escalate"`.

### Step Failure Recovery

If any heartbeat step fails:

1. **exec failure** (non-zero exit): Retry once with same parameters. If still fails:
   - Log error details to `/project/state/decision_log.md`
   - Set task status to `"failed"` with error message in backlog
   - Post error to Slack with step number and error summary
   - Skip to Step 9 (cleanup)

2. **sessions_send failure** (timeout or transport error): Retry once. If still fails:
   - Same recovery as exec failure above

3. **State file corruption**: If any state file fails to parse as JSON:
   - Log the corruption event
   - Attempt to read the file as raw text and extract valid JSON
   - If unrecoverable: post CRITICAL alert to Slack, set run_state to "paused"
   - Do NOT continue the cycle with corrupt state

4. **Out of disk space**: If write operations fail:
   - Run emergency cleanup: delete all clones in `/project/workspaces/.clones/` for completed/failed tasks
   - Retry the write
   - If still fails: pause and alert
