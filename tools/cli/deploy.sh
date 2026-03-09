#!/bin/sh
# deploy.sh — Self-deploy and version check utilities for OCMA
# POSIX-compatible

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

TOOL_NAME="deploy"

OPERATION=""
HOST_REPO_PATH="/project/host-repo"
RESTART_STATE_FILE="/project/state/restart_state.json"

usage() {
    cat >&2 <<EOF
Usage: $0 --op OPERATION --task-id ID [OPTIONS]

Operations:
  pull              Git pull latest changes in host repo
  version-check     Check for CLI tool updates (npm outdated)
  restart           Graceful container restart (SIGTERM to PID 1)
  reset-counter     Reset restart counter after successful cycle

Required:
  --op OPERATION
  --task-id ID

Optional:
  --timeout SECS    Timeout in seconds (default: ${DEFAULT_TIMEOUT})
  --reason REASON   Restart reason (default: tool_update)

Exit codes:
  0   Success (or no updates for version-check)
  2   Updates available (version-check only)
  1   Error
  124 Timeout
EOF
    exit 1
}

parse_deploy_args() {
    CLI_TASK_ID=""
    CLI_TIMEOUT="$DEFAULT_TIMEOUT"
    RESTART_REASON="tool_update"

    while [ $# -gt 0 ]; do
        case "$1" in
            --op)
                shift
                OPERATION="$1"
                ;;
            --task-id)
                shift
                CLI_TASK_ID="$1"
                ;;
            --timeout)
                shift
                CLI_TIMEOUT="$1"
                ;;
            --reason)
                shift
                RESTART_REASON="$1"
                ;;
            --help|-h)
                usage
                ;;
            *)
                log_warn "Unknown argument: $1"
                ;;
        esac
        shift
    done

    if [ -z "$OPERATION" ]; then
        log_error "Missing required argument: --op"
        return 1
    fi
    if [ -z "$CLI_TASK_ID" ]; then
        log_error "Missing required argument: --task-id"
        return 1
    fi
}

# ── Operations ───────────────────────────────────────────────────────────────

do_pull() {
    if [ ! -d "$HOST_REPO_PATH/.git" ]; then
        log_error "Host repo not mounted at $HOST_REPO_PATH"
        exit $EXIT_ERROR
    fi

    log_info "Task ${CLI_TASK_ID}: Pulling latest changes in host repo"

    set +e
    run_with_timeout "$CLI_TIMEOUT" git -C "$HOST_REPO_PATH" pull origin main
    _exit=$?
    set -e

    if [ "$_exit" -eq 0 ]; then
        log_info "Task ${CLI_TASK_ID}: Host repo updated successfully"
    else
        log_error "Task ${CLI_TASK_ID}: Git pull failed (exit $_exit)"
    fi
    return "$_exit"
}

do_version_check() {
    log_info "Task ${CLI_TASK_ID}: Checking for CLI tool updates"

    _updates_available=0
    _tmpfile="$(mktemp)"

    # Check npm outdated for CLI tools
    set +e
    npm outdated -g @anthropic-ai/claude-code @openai/codex @google/gemini-cli 2>/dev/null > "$_tmpfile"
    set -e

    if [ -s "$_tmpfile" ]; then
        _updates_available=1
        log_info "Task ${CLI_TASK_ID}: Updates available:"
        cat "$_tmpfile" >&2
    else
        log_info "Task ${CLI_TASK_ID}: All CLI tools are up to date"
    fi

    # Get current openclaw version
    _oc_current="$(openclaw --version 2>/dev/null || echo 'unknown')"
    log_info "Task ${CLI_TASK_ID}: OpenClaw version: $_oc_current"

    # Output version info as JSON
    printf '{"updates_available":%s,"openclaw_version":"%s","checked_at":"%s"}\n' \
        "$([ "$_updates_available" -eq 1 ] && echo 'true' || echo 'false')" \
        "$_oc_current" \
        "$(timestamp_iso)"

    rm -f "$_tmpfile"

    # Exit code 2 signals "updates available"
    if [ "$_updates_available" -eq 1 ]; then
        return 2
    fi
    return 0
}

do_restart() {
    log_info "Task ${CLI_TASK_ID}: Initiating graceful container restart (reason: ${RESTART_REASON})"

    _now="$(timestamp_iso)"

    # Read current restart count
    _count=0
    if [ -f "$RESTART_STATE_FILE" ]; then
        _count="$(python3 -c "import json; print(json.load(open('$RESTART_STATE_FILE')).get('restart_count', 0))" 2>/dev/null || echo 0)"
    fi
    _count=$((_count + 1))

    # Update restart state
    python3 -c "
import json

state = {'restart_count': 0, 'tool_versions': {}}
try:
    with open('$RESTART_STATE_FILE') as f:
        state = json.load(f)
except:
    pass

state['restart_count'] = $_count
state['last_restart_at'] = '$_now'
state['restart_reason'] = '$RESTART_REASON'

with open('$RESTART_STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null || log_warn "Failed to update restart state"

    log_info "Task ${CLI_TASK_ID}: Sending SIGTERM to PID 1 (restart count: $_count)"

    # Send SIGTERM to tini (PID 1), which forwards to the gateway process
    # Container exits -> podman restart: unless-stopped -> entrypoint.sh runs npm update
    kill -SIGTERM 1
}

do_reset_counter() {
    log_info "Task ${CLI_TASK_ID}: Resetting restart counter"

    _now="$(timestamp_iso)"

    if [ -f "$RESTART_STATE_FILE" ]; then
        python3 -c "
import json

with open('$RESTART_STATE_FILE') as f:
    state = json.load(f)

state['restart_count'] = 0
state['last_successful_cycle_at'] = '$_now'

with open('$RESTART_STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null || log_warn "Failed to reset restart counter"
    fi

    log_info "Task ${CLI_TASK_ID}: Restart counter reset"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    if ! parse_deploy_args "$@"; then
        usage
    fi

    case "$OPERATION" in
        pull)
            do_pull
            ;;
        version-check)
            do_version_check
            ;;
        restart)
            do_restart
            ;;
        reset-counter)
            do_reset_counter
            ;;
        *)
            log_error "Unsupported operation: ${OPERATION}"
            usage
            ;;
    esac
}

main "$@"
