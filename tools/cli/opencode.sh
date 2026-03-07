#!/bin/sh
# opencode.sh — OpenCode CLI wrapper for OpenClaw agents
#
# KNOWN LIMITATION: `opencode run` is a TUI command that does not support
# piped stdout — it requires a terminal and never exits after responding.
#
# Strategy:
#   1. If OPENCODE_SERVER_URL is set → use HTTP API (opencode serve mode)
#   2. Otherwise → fall back to claude CLI as substitute
#
# To use native opencode: run `opencode serve --port 4096` first,
# then set OPENCODE_SERVER_URL=http://localhost:4096

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

TOOL_NAME="opencode"
DEFAULT_MODEL=""
OPENCODE_SERVER_URL="${OPENCODE_SERVER_URL:-}"

usage() {
    print_usage "$0" "  --server-url URL  OpenCode server URL (from 'opencode serve')"
    exit 1
}

parse_opencode_args() {
    CLI_PROMPT=""
    CLI_MODEL=""
    CLI_TASK_ID=""
    CLI_TIMEOUT="$DEFAULT_TIMEOUT"
    CLI_CWD=""
    CLI_EXTRA_ARGS=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --prompt)      shift; CLI_PROMPT="$1" ;;
            --model)       shift; CLI_MODEL="$1" ;;
            --task-id)     shift; CLI_TASK_ID="$1" ;;
            --timeout)     shift; CLI_TIMEOUT="$1" ;;
            --cwd)         shift; CLI_CWD="$1" ;;
            --server-url)  shift; OPENCODE_SERVER_URL="$1" ;;
            --)            shift; CLI_EXTRA_ARGS="$*"; break ;;
            *)             log_warn "Unknown argument: $1" ;;
        esac
        shift
    done

    if [ -z "$CLI_PROMPT" ]; then
        log_error "Missing required argument: --prompt"
        return 1
    fi
    if [ -z "$CLI_TASK_ID" ]; then
        CLI_TASK_ID="task_$(timestamp_epoch)_$$"
        log_warn "No --task-id provided, generated: ${CLI_TASK_ID}"
    fi
}

try_server_api() {
    if [ -z "$OPENCODE_SERVER_URL" ]; then
        return 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl not found"
        return 1
    fi

    _payload=$(python3 -c "
import json, sys
print(json.dumps({'message': sys.argv[1]}))
" "$CLI_PROMPT" 2>/dev/null) || return 1

    curl -sf -m "$CLI_TIMEOUT" \
        -X POST "${OPENCODE_SERVER_URL}/api/message" \
        -H "Content-Type: application/json" \
        -d "$_payload" 2>/dev/null || return 1
}

main() {
    if ! parse_opencode_args "$@"; then
        usage
    fi

    log_info "Task ${CLI_TASK_ID}: Running opencode"
    log_info "Prompt: $(printf '%.100s' "$CLI_PROMPT")..."

    _outfile="$(mktemp)"
    trap 'rm -f "$_outfile"' EXIT

    _start="$(timestamp_epoch)"

    if try_server_api > "$_outfile" 2>/dev/null; then
        _exit_code=0
        log_info "opencode: Used server API at ${OPENCODE_SERVER_URL}"
    else
        if [ -n "$OPENCODE_SERVER_URL" ]; then
            log_warn "opencode server not reachable at ${OPENCODE_SERVER_URL}"
        fi
        log_warn "Falling back to claude CLI (opencode run does not support piped output)"

        if command -v claude >/dev/null 2>&1; then
            set -- claude --print --model claude-sonnet-4-6 --dangerously-skip-permissions "$CLI_PROMPT"

            if [ -n "$CLI_CWD" ] && [ -d "$CLI_CWD" ]; then
                cd "$CLI_CWD"
            fi

            set +e
            run_with_timeout "$CLI_TIMEOUT" "$@" > "$_outfile" 2>&1
            _exit_code=$?
            set -e
        else
            log_error "No fallback CLI available"
            printf "ERROR: opencode requires 'opencode serve'. Set OPENCODE_SERVER_URL.\n" > "$_outfile"
            _exit_code=$EXIT_ERROR
        fi
    fi

    _end="$(timestamp_epoch)"
    _duration=$((_end - _start))

    truncate_output "$_outfile"
    cat "$_outfile"

    if [ "$_exit_code" -eq $EXIT_TIMEOUT ]; then
        log_error "${TOOL_NAME}: Timed out after $(format_duration "$_duration")"
    elif [ "$_exit_code" -ne 0 ]; then
        log_error "${TOOL_NAME}: Failed with exit code ${_exit_code} after $(format_duration "$_duration")"
    else
        log_info "${TOOL_NAME}: Completed successfully in $(format_duration "$_duration")"
    fi

    exit "$_exit_code"
}

main "$@"
