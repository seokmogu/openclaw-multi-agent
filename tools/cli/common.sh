#!/bin/sh
# common.sh — Shared functions for OpenClaw CLI wrappers
# Provides: logging, cost tracking, timeout handling, output truncation, budget checks
# POSIX-compatible (macOS/Linux)

set -e

# ─── Configuration ───────────────────────────────────────────────────────────
PROJECT_ROOT="/Users/seokmogu/project/openclaw-multi-agent"
STATE_DIR="${PROJECT_ROOT}/state"
COST_LEDGER="${STATE_DIR}/cost_ledger.json"
MAX_OUTPUT="${MAX_OUTPUT:-50000}"
DEFAULT_TIMEOUT="${DEFAULT_TIMEOUT:-600}"
HOURLY_BUDGET="${HOURLY_BUDGET:-20}"

# Exit codes
EXIT_SUCCESS=0
EXIT_ERROR=1
EXIT_BUDGET_EXCEEDED=2
EXIT_TIMEOUT=124

# ─── Timestamp Helpers ──────────────────────────────────────────────────────

# ISO 8601 timestamp
timestamp_iso() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Unix epoch seconds
timestamp_epoch() {
    date +%s
}

# Human-readable duration from seconds
format_duration() {
    _secs="$1"
    if [ "$_secs" -ge 3600 ]; then
        printf "%dh%dm%ds" $((_secs / 3600)) $((_secs % 3600 / 60)) $((_secs % 60))
    elif [ "$_secs" -ge 60 ]; then
        printf "%dm%ds" $((_secs / 60)) $((_secs % 60))
    else
        printf "%ds" "$_secs"
    fi
}

# ─── Logging ─────────────────────────────────────────────────────────────────

# Log to stderr so stdout stays clean for CLI output
log_info() {
    printf "[%s] [INFO] %s\n" "$(timestamp_iso)" "$*" >&2
}

log_warn() {
    printf "[%s] [WARN] %s\n" "$(timestamp_iso)" "$*" >&2
}

log_error() {
    printf "[%s] [ERROR] %s\n" "$(timestamp_iso)" "$*" >&2
}

# ─── Cost Ledger ─────────────────────────────────────────────────────────────

# Ensure cost_ledger.json exists with proper structure
init_cost_ledger() {
    mkdir -p "$STATE_DIR"
    if [ ! -f "$COST_LEDGER" ]; then
        printf '{"entries":[]}\n' > "$COST_LEDGER"
    fi
    # Validate it's valid JSON with entries array; recreate if corrupt
    if ! _validate_ledger 2>/dev/null; then
        log_warn "cost_ledger.json corrupt, recreating"
        printf '{"entries":[]}\n' > "$COST_LEDGER"
    fi
}

_validate_ledger() {
    # Check file is valid JSON and has entries array
    # Use python3 as a JSON validator (available on macOS)
    python3 -c "
import json, sys
with open('${COST_LEDGER}') as f:
    d = json.load(f)
    assert isinstance(d.get('entries'), list)
" 2>/dev/null
}

# Append a cost entry to the ledger
# Usage: log_cost TOOL_NAME DURATION_SECS EXIT_CODE TASK_ID [EXTRA_JSON_FIELDS]
log_cost() {
    _tool="$1"
    _duration="$2"
    _exit_code="$3"
    _task_id="$4"
    _extra="${5:-}"

    init_cost_ledger

    _ts="$(timestamp_iso)"
    _epoch="$(timestamp_epoch)"

    # Build the entry JSON
    _entry="{\"timestamp\":\"${_ts}\",\"epoch\":${_epoch},\"tool\":\"${_tool}\",\"duration_secs\":${_duration},\"exit_code\":${_exit_code},\"task_id\":\"${_task_id}\""

    if [ -n "$_extra" ]; then
        _entry="${_entry},${_extra}"
    fi
    _entry="${_entry}}"

    # Atomic append using python3 (available on macOS, handles JSON properly)
    python3 -c "
import json, sys, fcntl

entry = json.loads('${_entry}')
ledger_path = '${COST_LEDGER}'

with open(ledger_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    try:
        data = json.load(f)
        if not isinstance(data.get('entries'), list):
            data = {'entries': []}
        data['entries'].append(entry)
        f.seek(0)
        f.truncate()
        json.dump(data, f, indent=2)
        f.write('\n')
    finally:
        fcntl.flock(f, fcntl.LOCK_UN)
" 2>/dev/null

    if [ $? -ne 0 ]; then
        log_warn "Failed to write cost entry for task ${_task_id}"
    else
        log_info "Cost logged: tool=${_tool} duration=${_duration}s exit=${_exit_code} task=${_task_id}"
    fi
}

# ─── Budget Check ────────────────────────────────────────────────────────────

# Check if we're within the hourly budget
# Returns 0 if within budget, 1 if over budget
# Prints remaining budget info to stderr
check_budget() {
    _budget="${1:-$HOURLY_BUDGET}"

    init_cost_ledger

    _one_hour_ago="$(python3 -c "import time; print(int(time.time()) - 3600)")"

    _result="$(python3 -c "
import json, sys

budget = float('${_budget}')
one_hour_ago = int('${_one_hour_ago}')

with open('${COST_LEDGER}') as f:
    data = json.load(f)

entries = data.get('entries', [])
recent = [e for e in entries if e.get('epoch', 0) >= one_hour_ago]
count = len(recent)
total_duration = sum(e.get('duration_secs', 0) for e in recent)

# Estimate cost: rough heuristic based on duration
# Each tool invocation has a base cost + duration-proportional cost
# Base: \$0.01 per call, Duration: \$0.001 per second
estimated_cost = count * 0.01 + total_duration * 0.001

remaining = budget - estimated_cost
over = 'yes' if estimated_cost >= budget else 'no'

print(f'{estimated_cost:.4f}|{remaining:.4f}|{count}|{over}')
" 2>/dev/null)"

    if [ -z "$_result" ]; then
        log_warn "Budget check failed, allowing execution"
        return 0
    fi

    _spent="$(echo "$_result" | cut -d'|' -f1)"
    _remaining="$(echo "$_result" | cut -d'|' -f2)"
    _call_count="$(echo "$_result" | cut -d'|' -f3)"
    _over="$(echo "$_result" | cut -d'|' -f4)"

    if [ "$_over" = "yes" ]; then
        log_error "Budget exceeded: spent=\$${_spent} budget=\$${_budget}/hr calls=${_call_count} in last hour"
        return 1
    fi

    log_info "Budget OK: spent=\$${_spent} remaining=\$${_remaining} calls=${_call_count}/hr"
    return 0
}

# ─── Timeout Execution ──────────────────────────────────────────────────────

# Run a command with timeout
# Usage: run_with_timeout TIMEOUT_SECS COMMAND [ARGS...]
# Returns: command exit code, or 124 on timeout
run_with_timeout() {
    _timeout="$1"
    shift

    if [ -z "$_timeout" ] || [ "$_timeout" -le 0 ] 2>/dev/null; then
        _timeout="$DEFAULT_TIMEOUT"
    fi

    log_info "Running with ${_timeout}s timeout: $1"

    # macOS has GNU timeout via coreutils (gtimeout) or built-in timeout
    if command -v timeout >/dev/null 2>&1; then
        timeout "$_timeout" "$@"
        return $?
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$_timeout" "$@"
        return $?
    else
        # POSIX fallback using background process + kill
        "$@" &
        _pid=$!
        (
            _elapsed=0
            while [ "$_elapsed" -lt "$_timeout" ]; do
                sleep 1
                _elapsed=$((_elapsed + 1))
                if ! kill -0 "$_pid" 2>/dev/null; then
                    exit 0
                fi
            done
            kill -TERM "$_pid" 2>/dev/null
            sleep 2
            kill -KILL "$_pid" 2>/dev/null
        ) &
        _watchdog=$!

        wait "$_pid" 2>/dev/null
        _exit_code=$?
        kill "$_watchdog" 2>/dev/null
        wait "$_watchdog" 2>/dev/null

        # Check if the process was killed by signal (timeout)
        if [ "$_exit_code" -gt 128 ]; then
            return $EXIT_TIMEOUT
        fi
        return "$_exit_code"
    fi
}

# ─── Output Truncation ──────────────────────────────────────────────────────

# Truncate output to MAX_OUTPUT bytes
# Reads from file, writes truncated version back
# Usage: truncate_output FILE [MAX_BYTES]
truncate_output() {
    _file="$1"
    _max="${2:-$MAX_OUTPUT}"

    if [ ! -f "$_file" ]; then
        return 0
    fi

    _size="$(wc -c < "$_file" | tr -d ' ')"

    if [ "$_size" -gt "$_max" ]; then
        _keep_head=$((_max * 4 / 5))
        _keep_tail=$((_max / 5))
        _skipped=$((_size - _keep_head - _keep_tail))

        _tmpfile="$(mktemp)"
        {
            head -c "$_keep_head" "$_file"
            printf "\n\n--- OUTPUT TRUNCATED: %d bytes skipped (%d total, limit %d) ---\n\n" \
                "$_skipped" "$_size" "$_max"
            tail -c "$_keep_tail" "$_file"
        } > "$_tmpfile"
        mv "$_tmpfile" "$_file"

        log_warn "Output truncated: ${_size} -> ${_max} bytes"
    fi
}

# Truncate string from stdin, write to stdout
truncate_output_stdin() {
    _max="${1:-$MAX_OUTPUT}"
    _tmpfile="$(mktemp)"
    cat > "$_tmpfile"
    truncate_output "$_tmpfile" "$_max"
    cat "$_tmpfile"
    rm -f "$_tmpfile"
}

# ─── Argument Parsing ───────────────────────────────────────────────────────

# Parse standard CLI wrapper arguments
# Sets: CLI_PROMPT, CLI_MODEL, CLI_TASK_ID, CLI_TIMEOUT, CLI_CWD
parse_cli_args() {
    CLI_PROMPT=""
    CLI_MODEL=""
    CLI_TASK_ID=""
    CLI_TIMEOUT="$DEFAULT_TIMEOUT"
    CLI_CWD=""
    CLI_EXTRA_ARGS=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --prompt)
                shift
                CLI_PROMPT="$1"
                ;;
            --model)
                shift
                CLI_MODEL="$1"
                ;;
            --task-id)
                shift
                CLI_TASK_ID="$1"
                ;;
            --timeout)
                shift
                CLI_TIMEOUT="$1"
                ;;
            --cwd)
                shift
                CLI_CWD="$1"
                ;;
            --)
                shift
                CLI_EXTRA_ARGS="$*"
                break
                ;;
            *)
                log_warn "Unknown argument: $1"
                ;;
        esac
        shift
    done

    # Validate required args
    if [ -z "$CLI_PROMPT" ]; then
        log_error "Missing required argument: --prompt"
        return 1
    fi

    if [ -z "$CLI_TASK_ID" ]; then
        CLI_TASK_ID="task_$(timestamp_epoch)_$$"
        log_warn "No --task-id provided, generated: ${CLI_TASK_ID}"
    fi
}

# ─── Wrapper Execution Helper ───────────────────────────────────────────────

# Standard wrapper execution flow
# Usage: exec_cli_wrapper TOOL_NAME COMMAND [ARGS...]
# Assumes parse_cli_args has been called
exec_cli_wrapper() {
    _tool_name="$1"
    shift

    # Check budget
    if ! check_budget; then
        log_error "${_tool_name}: Budget exceeded, aborting"
        exit $EXIT_BUDGET_EXCEEDED
    fi

    # Change to working directory if specified
    if [ -n "$CLI_CWD" ]; then
        if [ -d "$CLI_CWD" ]; then
            cd "$CLI_CWD"
            log_info "Working directory: ${CLI_CWD}"
        else
            log_error "Working directory does not exist: ${CLI_CWD}"
            exit $EXIT_ERROR
        fi
    fi

    # Create temp file for output capture
    _outfile="$(mktemp)"
    trap 'rm -f "$_outfile"' EXIT

    # Record start time
    _start="$(timestamp_epoch)"

    # Run with timeout, capture output
    set +e
    run_with_timeout "$CLI_TIMEOUT" "$@" > "$_outfile" 2>&1
    _exit_code=$?
    set -e

    # Record end time and duration
    _end="$(timestamp_epoch)"
    _duration=$((_end - _start))

    # Truncate output if needed
    truncate_output "$_outfile"

    # Log cost
    log_cost "$_tool_name" "$_duration" "$_exit_code" "$CLI_TASK_ID"

    # Output the result
    cat "$_outfile"

    # Log summary
    if [ "$_exit_code" -eq $EXIT_TIMEOUT ]; then
        log_error "${_tool_name}: Timed out after $(format_duration "$_duration")"
    elif [ "$_exit_code" -ne 0 ]; then
        log_error "${_tool_name}: Failed with exit code ${_exit_code} after $(format_duration "$_duration")"
    else
        log_info "${_tool_name}: Completed successfully in $(format_duration "$_duration")"
    fi

    return "$_exit_code"
}

# ─── Usage Helper ────────────────────────────────────────────────────────────

print_usage() {
    _tool="$1"
    _extra="${2:-}"
    cat >&2 <<EOF
Usage: ${_tool} --prompt "..." --task-id "..." [--model "..."] [--timeout N] [--cwd /path]

Required:
  --prompt TEXT     The prompt/instruction for the CLI tool
  --task-id ID      Unique task identifier for cost tracking

Optional:
  --model MODEL     Model to use (tool-specific default)
  --timeout SECS    Timeout in seconds (default: ${DEFAULT_TIMEOUT})
  --cwd PATH        Working directory for the CLI tool
${_extra}
Exit codes:
  0   Success
  1   Error
  2   Budget exceeded
  124 Timeout
EOF
}
