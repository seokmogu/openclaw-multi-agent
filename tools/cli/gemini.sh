#!/bin/sh
# gemini.sh — Google Gemini CLI wrapper for OpenClaw agents
# Wraps the `gemini` CLI for AI-assisted coding
# POSIX-compatible (macOS/Linux)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

TOOL_NAME="gemini"
DEFAULT_MODEL="gemini-2.5-pro"

# ─── Extended Argument Parsing ───────────────────────────────────────────────

SANDBOX_MODE=""

parse_gemini_args() {
    CLI_PROMPT=""
    CLI_MODEL=""
    CLI_TASK_ID=""
    CLI_TIMEOUT="$DEFAULT_TIMEOUT"
    CLI_CWD=""
    CLI_EXTRA_ARGS=""
    SANDBOX_MODE=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --prompt)   shift; CLI_PROMPT="$1" ;;
            --model)    shift; CLI_MODEL="$1" ;;
            --task-id)  shift; CLI_TASK_ID="$1" ;;
            --timeout)  shift; CLI_TIMEOUT="$1" ;;
            --cwd)      shift; CLI_CWD="$1" ;;
            --sandbox)  shift; SANDBOX_MODE="$1" ;;
            --)         shift; CLI_EXTRA_ARGS="$*"; break ;;
            *)          log_warn "Unknown argument: $1" ;;
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
    print_usage "$0" "  --sandbox MODE       Sandbox mode for gemini (e.g., none, basic)"
    exit 1
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    # Parse arguments
    if ! parse_gemini_args "$@"; then
        usage
    fi

    # Verify gemini is installed
    if ! command -v gemini >/dev/null 2>&1; then
        log_error "gemini CLI not found in PATH"
        exit $EXIT_ERROR
    fi

    # Use default model if none specified
    if [ -z "$CLI_MODEL" ]; then
        CLI_MODEL="$DEFAULT_MODEL"
    fi

    # Build command: gemini [query..] -m model -o text
    # Use positional prompt (--prompt is deprecated)
    set -- gemini -m "$CLI_MODEL" -o text "$CLI_PROMPT"

    # Add sandbox mode if specified (--yolo for full auto)
    if [ -n "$SANDBOX_MODE" ] && [ "$SANDBOX_MODE" = "yolo" ]; then
        set -- "$@" -y
    fi

    log_info "Task ${CLI_TASK_ID}: Running gemini (model: ${CLI_MODEL})"
    log_info "Prompt: $(printf '%.100s' "$CLI_PROMPT")..."

    # Execute with standard wrapper flow (budget check, timeout, truncation, cost logging)
    exec_cli_wrapper "$TOOL_NAME" "$@"
    _exit=$?

    exit "$_exit"
}

main "$@"
