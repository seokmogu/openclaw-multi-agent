#!/bin/sh
# codex.sh — OpenAI Codex CLI wrapper for OpenClaw agents
# Wraps the `codex` CLI for autonomous coding tasks
# POSIX-compatible (macOS/Linux)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

TOOL_NAME="codex"
DEFAULT_MODEL=""
DEFAULT_APPROVAL_POLICY="on-request"

# ─── Extended Argument Parsing ───────────────────────────────────────────────

APPROVAL_POLICY=""

parse_codex_args() {
    CLI_PROMPT=""
    CLI_MODEL=""
    CLI_TASK_ID=""
    CLI_TIMEOUT="$DEFAULT_TIMEOUT"
    CLI_CWD=""
    CLI_EXTRA_ARGS=""
    APPROVAL_POLICY=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --prompt)           shift; CLI_PROMPT="$1" ;;
            --model)            shift; CLI_MODEL="$1" ;;
            --task-id)          shift; CLI_TASK_ID="$1" ;;
            --timeout)          shift; CLI_TIMEOUT="$1" ;;
            --cwd)              shift; CLI_CWD="$1" ;;
            --approval-policy)  shift; APPROVAL_POLICY="$1" ;;
            --)                 shift; CLI_EXTRA_ARGS="$*"; break ;;
            *)                  log_warn "Unknown argument: $1" ;;
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
    print_usage "$0" "  --approval-policy P  Approval policy: on-request|on-failure|never (default: on-request)"
    exit 1
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    # Parse arguments
    if ! parse_codex_args "$@"; then
        usage
    fi

    # Verify codex is installed
    if ! command -v codex >/dev/null 2>&1; then
        log_error "codex CLI not found in PATH"
        exit $EXIT_ERROR
    fi

    # Use defaults if not specified
    if [ -z "$CLI_MODEL" ]; then
        CLI_MODEL="$DEFAULT_MODEL"
    fi
    if [ -z "$APPROVAL_POLICY" ]; then
        APPROVAL_POLICY="$DEFAULT_APPROVAL_POLICY"
    fi

    # Build command: codex exec [PROMPT] -m model -s sandbox
    # Map approval-policy to sandbox mode for codex exec
    SANDBOX_MODE="workspace-write"
    case "$APPROVAL_POLICY" in
        never)      SANDBOX_MODE="danger-full-access" ;;
        on-request) SANDBOX_MODE="workspace-write" ;;
        on-failure) SANDBOX_MODE="workspace-write" ;;
        *)          SANDBOX_MODE="workspace-write" ;;
    esac

    set -- codex exec "$CLI_PROMPT" \
        -s "$SANDBOX_MODE" \
        --skip-git-repo-check

    if [ -n "$CLI_MODEL" ]; then
        set -- "$@" -m "$CLI_MODEL"
    fi

    log_info "Task ${CLI_TASK_ID}: Running codex (model: ${CLI_MODEL}, policy: ${APPROVAL_POLICY})"
    log_info "Prompt: $(printf '%.100s' "$CLI_PROMPT")..."

    exec_cli_wrapper "$TOOL_NAME" "$@"
    _exit=$?

    exit "$_exit"
}

main "$@"
