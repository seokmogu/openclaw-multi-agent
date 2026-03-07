#!/bin/sh
# claude.sh — Claude Code CLI wrapper for OpenClaw agents
# Wraps the `claude` CLI (Anthropic Claude Code)
# POSIX-compatible (macOS/Linux)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

TOOL_NAME="claude"
DEFAULT_MODEL="claude-sonnet-4-6"

# ─── Extended Argument Parsing ───────────────────────────────────────────────

SYSTEM_PROMPT=""

parse_claude_args() {
    CLI_PROMPT=""
    CLI_MODEL=""
    CLI_TASK_ID=""
    CLI_TIMEOUT="$DEFAULT_TIMEOUT"
    CLI_CWD=""
    CLI_EXTRA_ARGS=""
    SYSTEM_PROMPT=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --prompt)     shift; CLI_PROMPT="$1" ;;
            --model)      shift; CLI_MODEL="$1" ;;
            --task-id)    shift; CLI_TASK_ID="$1" ;;
            --timeout)    shift; CLI_TIMEOUT="$1" ;;
            --cwd)        shift; CLI_CWD="$1" ;;
            --system-prompt) shift; SYSTEM_PROMPT="$1" ;;
            --)           shift; CLI_EXTRA_ARGS="$*"; break ;;
            *)            log_warn "Unknown argument: $1" ;;
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

# ─── Usage ───────────────────────────────────────────────────────────────────

usage() {
    print_usage "$0" "  --system-prompt TEXT  Additional system prompt to append"
    exit 1
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    # Parse arguments
    if ! parse_claude_args "$@"; then
        usage
    fi

    # Verify claude is installed
    if ! command -v claude >/dev/null 2>&1; then
        log_error "claude CLI not found in PATH"
        exit $EXIT_ERROR
    fi

    # Use default model if none specified
    if [ -z "$CLI_MODEL" ]; then
        CLI_MODEL="$DEFAULT_MODEL"
    fi

    # Build command
    set -- claude --print --model "$CLI_MODEL" --dangerously-skip-permissions

    # Add system prompt if specified
    if [ -n "$SYSTEM_PROMPT" ]; then
        set -- "$@" --append-system-prompt "$SYSTEM_PROMPT"
    fi

    # Prompt goes last
    set -- "$@" "$CLI_PROMPT"

    log_info "Task ${CLI_TASK_ID}: Running claude (model: ${CLI_MODEL})"
    log_info "Prompt: $(printf '%.100s' "$CLI_PROMPT")..."

    # Execute with standard wrapper flow (budget check, timeout, truncation, cost logging)
    exec_cli_wrapper "$TOOL_NAME" "$@"
    _exit=$?

    exit "$_exit"
}

main "$@"
