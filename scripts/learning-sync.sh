#!/bin/bash
#
# learning-sync.sh — OCMA Self-Evolution: Learning Injection
#
# Codifies the "Running Prompt Evolution" logic from HEARTBEAT.md Step 2.5.
# Reads learning_log.json, selects unapplied entries, groups by type,
# and outputs a running_prompt_text block for debate context injection.
#
# Also handles hindsight injection (Step 4.55) when --task-tags are provided.
#
# Exit codes:
#   0 — success (running_prompt_text on stdout, may be empty)
#   1 — error reading state files
#
# Usage:
#   ./scripts/learning-sync.sh [--state-dir /path/to/state] [--mark-applied] [--task-tags tag1,tag2] [--max-entries 20]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR=""
MARK_APPLIED="false"
TASK_TAGS=""
MAX_ENTRIES=20

while [[ $# -gt 0 ]]; do
    case "$1" in
        --state-dir) STATE_DIR="$2"; shift 2 ;;
        --mark-applied) MARK_APPLIED="true"; shift ;;
        --task-tags) TASK_TAGS="$2"; shift 2 ;;
        --max-entries) MAX_ENTRIES="$2"; shift 2 ;;
        *) shift ;;
    esac
done

STATE_DIR="${STATE_DIR:-$PROJECT_DIR/state}"

export STATE_DIR MARK_APPLIED TASK_TAGS MAX_ENTRIES

exec python3 << 'PYEOF'
import json
import os
import sys
from collections import defaultdict

state_dir = os.environ["STATE_DIR"]
mark_applied = os.environ["MARK_APPLIED"] == "true"
task_tags_raw = os.environ.get("TASK_TAGS", "")
max_entries = int(os.environ.get("MAX_ENTRIES", "20"))

task_tags = set(t.strip() for t in task_tags_raw.split(",") if t.strip()) if task_tags_raw else set()

LEARNING_LOG_FILE = os.path.join(state_dir, "learning_log.json")

try:
    with open(LEARNING_LOG_FILE) as f:
        log_data = json.load(f)
except FileNotFoundError:
    print("", end="")
    sys.exit(0)
except json.JSONDecodeError:
    print("", file=sys.stderr)
    sys.exit(1)

entries = log_data.get("entries", [])
if not entries:
    print("", end="")
    sys.exit(0)

# ─── Part 1: Running Prompt Evolution (unapplied learnings) ───

unapplied = [e for e in entries if not e.get("applied", False)]
unapplied = unapplied[-max_entries:]  # newest N

TYPE_LABELS = {
    "verifier_failure": "Past failures to avoid",
    "debate_pattern": "Debate patterns observed",
    "critic_insight": "Critic insights",
    "performance_metric": "Performance observations",
}

groups = defaultdict(list)
for entry in unapplied:
    entry_type = entry.get("type", "other")
    content = entry.get("content", "").strip()
    if content:
        groups[entry_type].append(content)

sections = []
for entry_type, label in TYPE_LABELS.items():
    items = groups.get(entry_type, [])
    if items:
        lines = [f"### {label}"]
        for item in items[-5:]:  # max 5 per section
            lines.append(f"- {item}")
        sections.append("\n".join(lines))

other_items = []
for entry_type, items in groups.items():
    if entry_type not in TYPE_LABELS:
        other_items.extend(items[-3:])
if other_items:
    lines = ["### Other learnings"]
    for item in other_items:
        lines.append(f"- {item}")
    sections.append("\n".join(lines))

running_prompt = ""
if sections:
    running_prompt = "## Running Prompt — Accumulated Learnings\n\n" + "\n\n".join(sections)

# ─── Part 2: Hindsight Injection (matching task tags) ───

hindsight_block = ""
if task_tags:
    hindsight_entries = []
    for entry in reversed(entries):
        sh = entry.get("structured_hindsight")
        if not sh:
            continue
        applicable = set(sh.get("applicable_patterns", []))
        if applicable & task_tags:
            hindsight_entries.append(sh)
        if len(hindsight_entries) >= 3:
            break

    if hindsight_entries:
        lines = ["## 관련 실패 교훈 (Hindsight)"]
        for h in hindsight_entries:
            cat = h.get("category", "unknown")
            root = h.get("root_cause", "N/A")
            rec = h.get("recommendation", "N/A")
            lines.append(f"- [{cat}]: {root} → {rec}")
        hindsight_block = "\n".join(lines)

# ─── Combine output ───

output_parts = []
if hindsight_block:
    output_parts.append(hindsight_block)
if running_prompt:
    output_parts.append(running_prompt)

print("\n\n".join(output_parts), end="")

# ─── Mark applied (optional) ───

if mark_applied and unapplied:
    applied_ids = set(e.get("id") for e in unapplied if e.get("id"))
    modified = False
    for entry in entries:
        if entry.get("id") in applied_ids and not entry.get("applied", False):
            entry["applied"] = True
            modified = True
    if modified:
        with open(LEARNING_LOG_FILE, "w") as f:
            json.dump(log_data, f, indent=2, ensure_ascii=False)

sys.exit(0)
PYEOF
