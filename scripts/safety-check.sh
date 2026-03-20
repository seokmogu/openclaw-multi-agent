#!/bin/bash
#
# safety-check.sh — OCMA Safety Guard
#
# Codified safety pre-checks that were previously described only in HEARTBEAT.md prose.
# Called by the Orchestrator at Step 0 before any cycle logic.
#
# Checks:
#   1. Consecutive failure detection — auto-disable discovery after N failures
#   2. Stale cycle_lock cleanup — clear locks older than TTL
#   3. Self-referential task blocking — respect discovery_config safety flag
#   4. Priority ceiling enforcement — cap auto-generated priority_score
#
# Exit codes:
#   0 — all checks passed, safe to proceed
#   1 — unsafe condition detected (details in JSON output)
#
# Output: JSON to stdout with check results
#
# Usage:
#   ./scripts/safety-check.sh [--state-dir /path/to/state]
#

set -euo pipefail

# ─────────────────────────────────────────────
# 경로 설정
# ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="${1:+}"

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --state-dir) STATE_DIR="$2"; shift 2 ;;
        *) shift ;;
    esac
done

STATE_DIR="${STATE_DIR:-$PROJECT_DIR/state}"
export STATE_DIR

exec python3 << 'PYEOF'
import json
import sys
import os
from datetime import datetime, timezone

state_dir = os.environ["STATE_DIR"]

BACKLOG_FILE = os.path.join(state_dir, "backlog.json")
RUN_STATE_FILE = os.path.join(state_dir, "run_state.json")
DISCOVERY_CONFIG_FILE = os.path.join(state_dir, "discovery_config.json")
METRICS_FILE = os.path.join(state_dir, "metrics.json")

# ─── Helpers ───

def load_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return default if default is not None else {}

def save_json(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    f.close()

def now_utc():
    return datetime.now(timezone.utc)

def parse_iso(s):
    """Parse ISO 8601 timestamp, tolerating Z suffix."""
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None

# ─── Load state ───

results = {
    "safe": True,
    "checks": [],
    "actions_taken": [],
    "timestamp": now_utc().isoformat(),
}

backlog = load_json(BACKLOG_FILE, {"tasks": []})
run_state = load_json(RUN_STATE_FILE, {})
discovery_config = load_json(DISCOVERY_CONFIG_FILE, {})
metrics = load_json(METRICS_FILE, {"entries": []})

tasks = backlog.get("tasks", [])
safety = discovery_config.get("safety", {})

# ─── Check 1: Consecutive failure detection ───

MAX_CONSECUTIVE_FAILURES = safety.get("max_consecutive_failures_before_disable", 5)

entries = metrics.get("entries", [])
if isinstance(entries, list) and entries:
    # Count consecutive FAILs from the most recent entries
    consecutive_failures = 0
    for entry in reversed(entries):
        verdict = entry.get("verification_verdict", "").upper()
        if verdict == "FAIL":
            consecutive_failures += 1
        else:
            break

    if consecutive_failures >= MAX_CONSECUTIVE_FAILURES:
        results["checks"].append({
            "name": "consecutive_failure",
            "status": "FAIL",
            "detail": f"{consecutive_failures} consecutive failures detected (threshold: {MAX_CONSECUTIVE_FAILURES})",
        })

        # Auto-disable discovery
        if discovery_config.get("enabled", True):
            discovery_config["enabled"] = False
            save_json(DISCOVERY_CONFIG_FILE, discovery_config)
            results["actions_taken"].append("discovery_disabled_due_to_consecutive_failures")

        results["safe"] = False
    else:
        results["checks"].append({
            "name": "consecutive_failure",
            "status": "PASS",
            "detail": f"{consecutive_failures} recent failures (threshold: {MAX_CONSECUTIVE_FAILURES})",
        })
else:
    results["checks"].append({
        "name": "consecutive_failure",
        "status": "PASS",
        "detail": "No metrics entries to evaluate",
    })

# ─── Check 2: Stale cycle_lock cleanup ───

STALE_LOCK_TTL_SEC = 1800  # 30 minutes

cycle_lock = run_state.get("cycle_lock")
if cycle_lock and isinstance(cycle_lock, dict):
    locked_at = parse_iso(cycle_lock.get("locked_at"))
    if locked_at:
        age_sec = (now_utc() - locked_at).total_seconds()
        if age_sec > STALE_LOCK_TTL_SEC:
            # Clear stale lock
            run_state["cycle_lock"] = None
            save_json(RUN_STATE_FILE, run_state)
            results["checks"].append({
                "name": "stale_lock",
                "status": "CLEARED",
                "detail": f"Stale lock cleared (age: {int(age_sec)}s, TTL: {STALE_LOCK_TTL_SEC}s)",
            })
            results["actions_taken"].append(f"stale_cycle_lock_cleared_age_{int(age_sec)}s")
        else:
            # Lock is fresh — another cycle is running
            results["checks"].append({
                "name": "stale_lock",
                "status": "BLOCKED",
                "detail": f"Active cycle lock (age: {int(age_sec)}s, TTL: {STALE_LOCK_TTL_SEC}s)",
            })
            results["safe"] = False
    else:
        # Lock exists but no valid timestamp — clear it
        run_state["cycle_lock"] = None
        save_json(RUN_STATE_FILE, run_state)
        results["checks"].append({
            "name": "stale_lock",
            "status": "CLEARED",
            "detail": "Lock with invalid timestamp cleared",
        })
        results["actions_taken"].append("invalid_cycle_lock_cleared")
else:
    results["checks"].append({
        "name": "stale_lock",
        "status": "PASS",
        "detail": "No cycle lock present",
    })

# ─── Check 3: Self-referential task blocking ───

no_self_ref = safety.get("no_self_referential_tasks", True)
if no_self_ref:
    self_ref_tasks = [
        t for t in tasks
        if t.get("status") == "pending"
        and (t.get("target_repo") or "").endswith("openclaw-multi-agent")
    ]
    if self_ref_tasks:
        for t in self_ref_tasks:
            t["status"] = "blocked"
            t["error"] = "Blocked by safety: no_self_referential_tasks=true"
        save_json(BACKLOG_FILE, backlog)
        results["checks"].append({
            "name": "self_referential_block",
            "status": "BLOCKED",
            "detail": f"{len(self_ref_tasks)} self-referential task(s) blocked",
        })
        results["actions_taken"].append(f"blocked_{len(self_ref_tasks)}_self_referential_tasks")
    else:
        results["checks"].append({
            "name": "self_referential_block",
            "status": "PASS",
            "detail": "No pending self-referential tasks",
        })
else:
    results["checks"].append({
        "name": "self_referential_block",
        "status": "SKIP",
        "detail": "Self-referential blocking disabled",
    })

# ─── Check 4: Priority ceiling enforcement ───

MAX_AUTO_PRIORITY = safety.get("max_auto_priority", 0.9)
capped_count = 0

for t in tasks:
    if t.get("status") != "pending":
        continue
    gen_by = t.get("generated_by", "")
    if gen_by and gen_by.startswith("discovery:"):
        score = t.get("priority_score")
        if isinstance(score, (int, float)) and score > MAX_AUTO_PRIORITY:
            t["priority_score"] = MAX_AUTO_PRIORITY
            capped_count += 1

if capped_count > 0:
    save_json(BACKLOG_FILE, backlog)
    results["checks"].append({
        "name": "priority_ceiling",
        "status": "CAPPED",
        "detail": f"{capped_count} auto-generated task(s) capped to {MAX_AUTO_PRIORITY}",
    })
    results["actions_taken"].append(f"capped_{capped_count}_tasks_to_{MAX_AUTO_PRIORITY}")
else:
    results["checks"].append({
        "name": "priority_ceiling",
        "status": "PASS",
        "detail": f"All auto-generated tasks within ceiling ({MAX_AUTO_PRIORITY})",
    })

# ─── Output ───

print(json.dumps(results, indent=2, ensure_ascii=False))
sys.exit(0 if results["safe"] else 1)
PYEOF
