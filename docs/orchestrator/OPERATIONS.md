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

## Hindsight extraction

When verification verdict is FAIL:

- Read Verifier response `checks` and `evidence` arrays
- Classify failure into category: `logic-error`, `edge-case`, `integration`, `requirement-mismatch`, `test-gap`
  - `logic-error`: code logic was incorrect (test assertions failed on expected behavior)
  - `edge-case`: nominal case passed but boundary/error case was not handled
  - `integration`: individual components work but integration between them fails
  - `requirement-mismatch`: code does not match the original task description
  - `test-gap`: no test infrastructure to verify, low confidence due to missing tests
- Build `structured_hindsight` object:
  - `category`: one of the above
  - `root_cause`: synthesize from failed `checks[].output` (max 200 chars)
  - `recommendation`: "what should have been done" derived from the gap between plan and reality (max 200 chars)
  - `applicable_patterns`: extract from task `learning_tags` + failure category
- Append to learning_log entry alongside existing `content` field
- No separate LLM call - derive entirely from Verifier's existing JSON response

## Hindsight injection

During context assembly (Step 4.5):

- Read `/project/state/learning_log.json`
- Filter entries where `structured_hindsight` exists and `structured_hindsight.applicable_patterns` overlaps with current task's `learning_tags`
- Sort by recency, take max 3 matching entries
- Build injection block:
  ```
  ## 관련 실패 교훈 (Hindsight)
  - [category]: [root_cause] -> [recommendation]
  ```
- Insert into Planner context BEFORE the task description
- This replaces the generic running_prompt for matching hindsight entries
- Keep total context under `token_efficiency.context_budget_tokens` (default 4000)

## Per-turn outcome scoring

After cycle completes (Step 8.55), score each debate turn retroactively:

- Base score derived from cycle outcome:
  - PASS + confidence >= 0.8: base = 0.8
  - PASS + confidence < 0.8: base = 0.6
  - FAIL: base = 0.3
- Adjustments:
  - If tiebreak was used: all turns -0.1
  - If convergence achieved in epoch 1: planner_propose +0.1, critic_challenge +0.1
  - If planner revised after critic challenge AND revision led to convergence: critic +0.1, planner_revise +0.1
  - FAIL attribution: if verifier `checks` identify specific failing area, penalize the turn that introduced that aspect (-0.15)
- Clamp all scores to [0.0, 1.0]
- Store as `turn_scores` array in the metrics entry
- No LLM call - scoring is purely rule-based from existing cycle data

## Fast-path auto-expansion

During auto-tuning (Step 2.6):

- Read `fast_path.stats` from debate_config.json
- For each task that completed this cycle:
  - Extract task `learning_tags` as potential fast-path labels
  - Update `fast_path.stats[label]`: increment pass_count or fail_count, update avg_confidence
- Expansion check:
  - For each label in stats where `pass_count >= auto_expansion.min_success_count`:
    - If `avg_confidence >= auto_expansion.min_confidence` AND `fail_count / total <= auto_expansion.max_fail_rate`:
      - Add label to `fast_path.labels` if not already present
      - Add label to `auto_expansion.candidate_labels` for tracking
      - Log expansion to decision_log.md
- Shrink-back check:
  - For each label in `auto_expansion.candidate_labels`:
    - If `fail_count / total > auto_expansion.max_fail_rate`:
      - Remove label from `fast_path.labels`
      - Remove from `candidate_labels`
      - Log shrink-back to decision_log.md with reason

## Token budget tracking

At cycle start (Step 2.65):

- Read `token_efficiency.token_budget_per_cycle` from debate_config.json
- Initialize cycle token counter: `{ context: 0, debate: 0, implementation: 0, verification: 0 }`

During each phase:

- Estimate tokens from message length (1 token ~= 4 chars for English, ~= 2 chars for Korean)
- Context assembly: count characters in assembled context package, convert to tokens
- Debate: count characters in each sessions_send message and response
- Implementation: count characters in Implementer prompt and response
- Verification: count characters in Verifier prompt and response

At cycle end (Step 8.5):

- Store `token_usage` object in metrics entry
- If total exceeds `token_budget_per_cycle`, log warning to decision_log.md
- Token data used by auto-tuning to identify cost trends

## Model routing

At debate start (Step 5), when `model_routing.enabled` is true:

- Evaluate task against routing rules in order:
  - `fast_path == true`: use cheaper model for planner, skip critic
  - `priority_score >= 0.9`: use most capable models
  - Default: use debate_config.tools defaults
- Override `tools.planner.model` and `tools.critic.model` for this cycle only
- Log routing decision to decision_log.md
- Routing is heuristic-only - no LLM classification call
- Disabled by default. Enable after validating cost impact over 20+ cycles.
