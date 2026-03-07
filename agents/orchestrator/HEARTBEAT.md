# Orchestration Heartbeat Cycle

You are triggered every 2 minutes by cron. Follow these steps exactly, in order.

## Step 1: Check Run State

Read `/project/state/run_state.json`.

- If `status` is `"stopped"` or `"paused"` → **STOP immediately**. Do nothing else.
- If `status` is `"running"` → proceed to Step 2.

## Step 2: Load Configuration

Read `/project/state/debate_config.json`. Store the following parameters:

- `max_epochs` (default: 3)
- `convergence_threshold` (default: 0.7)
- `max_implementation_retries` (default: 2)
- `max_cycles_without_progress` (default: 5)
- `anti_loop_enabled` (default: true)

## Step 3: Pick Next Task

Read `/project/state/backlog.json`. Find the first task with `"status": "pending"` (ordered by array position).

- If **no pending task** found → post to Slack: "No pending tasks. Idle." → **STOP**.
- If pending task found → set its `status` to `"in_progress"` and `assigned_to` to `"orchestrator"`. Write the updated backlog back.

If the task has `target_repo` and `github_repo` fields (non-null):
- Check repo lease in `/project/state/git_state.json`
- If leased by another active task → skip this task, find next pending task
- If not leased → write lease and proceed

## Step 4: Post Cycle Start to Slack

```
exec(command="openclaw message send --channel slack --target \"C0AK4MVUELA\" --message \"Cycle start | Task: [task.title] | ID: [task.id]\"", timeout=15)
```

## Step 5: Run Debate (Epoch Loop)

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

If **epoch > max_epochs** and still not converged → force tiebreak (same as stale debate). Proceed to Step 6.

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
  - Send Verifier's feedback back to Implementer via `sessions_send` with specific fix instructions
  - After Implementer responds, call Verifier again (repeat Step 7)

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

## Error Handling

At ANY point, if a `sessions_send` call fails (timeout, transport error, invalid response after retry):

1. Log the error to `/project/state/decision_log.md`
2. If this is the first failure for this call → retry once
3. If retry also fails → mark task as `"failed"`, write error to backlog entry's `error` field
4. Post to Slack: "ERROR | Task: [title] | Phase: [phase] | Error: [message]"
5. Proceed to Step 8 (update state)
