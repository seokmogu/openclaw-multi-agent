#!/bin/sh
# common.sh — Shared functions for OpenClaw CLI wrappers
# POSIX-compatible (macOS/Linux)

set -e

# ─── Configuration ───────────────────────────────────────────────────────────
PROJECT_ROOT="${PROJECT_ROOT:-/project}"
STATE_DIR="${PROJECT_ROOT}/state"
MAX_OUTPUT="${MAX_OUTPUT:-0}"
DEFAULT_TIMEOUT="${DEFAULT_TIMEOUT:-0}"

# Exit codes
EXIT_SUCCESS=0
EXIT_ERROR=1
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

# ─── Timeout Execution ──────────────────────────────────────────────────────

# Run a command with timeout
# Usage: run_with_timeout TIMEOUT_SECS COMMAND [ARGS...]
# Returns: command exit code, or 124 on timeout
run_with_timeout() {
    _timeout="$1"
    shift

    if [ -z "$_timeout" ]; then
        _timeout="$DEFAULT_TIMEOUT"
    fi

    if [ -n "$_timeout" ] && [ "$_timeout" -le 0 ] 2>/dev/null; then
        log_info "Running without timeout: $1"
        "$@"
        return $?
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

    if [ -z "$_max" ] || [ "$_max" -le 0 ] 2>/dev/null; then
        return 0
    fi

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

retry_with_backoff() {
    _max_retries=3
    _base_delay=2

    if [ $# -gt 0 ]; then
        case "$1" in
            ''|*[!0-9]*)
                ;;
            *)
                _max_retries="$1"
                shift
                ;;
        esac
    fi

    if [ $# -gt 0 ]; then
        case "$1" in
            ''|*[!0-9]*)
                ;;
            *)
                _base_delay="$1"
                shift
                ;;
        esac
    fi

    if [ $# -eq 0 ]; then
        log_error "retry_with_backoff: missing command"
        return "$EXIT_ERROR"
    fi

    _attempt=0
    while :; do
        set +e
        "$@"
        _exit_code=$?
        set -e
        if [ "$_exit_code" -eq 0 ]; then
            return "$EXIT_SUCCESS"
        fi

        if [ "$_attempt" -ge "$_max_retries" ]; then
            return "$_exit_code"
        fi

        _delay="$_base_delay"
        _i=0
        while [ "$_i" -lt "$_attempt" ]; do
            _delay=$((_delay * 2))
            _i=$((_i + 1))
        done

        if [ "$_delay" -gt 30 ]; then
            _delay=30
        fi

        _jitter=0
        if [ -n "${RANDOM:-}" ]; then
            _jitter=$((RANDOM % 2))
        fi

        _total_delay=$((_delay + _jitter))
        _retry_num=$((_attempt + 1))
        log_warn "Command failed (exit ${_exit_code}), retry ${_retry_num}/${_max_retries} in ${_total_delay}s: $*"
        sleep "$_total_delay"

        _attempt=$((_attempt + 1))
    done
}

check_gh_token() {
    if [ -z "${GH_TOKEN:-}" ]; then
        log_error "GH_TOKEN environment variable is required"
        exit "$EXIT_ERROR"
    fi
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
  --task-id ID      Unique task identifier

Optional:
  --model MODEL     Model to use (tool-specific default)
  --timeout SECS    Timeout in seconds (default: ${DEFAULT_TIMEOUT})
  --cwd PATH        Working directory for the CLI tool
${_extra}
Exit codes:
  0   Success
  1   Error
  124 Timeout
EOF
}
