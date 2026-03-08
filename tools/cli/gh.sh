#!/bin/sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

TOOL_NAME="gh"

OPERATION=""
GITHUB_REPO=""
BRANCH_NAME=""
BASE_BRANCH="main"
TITLE=""
BODY=""

usage() {
    cat >&2 <<EOF
Usage: $0 --op OPERATION --github-repo OWNER/REPO --task-id ID [OPTIONS]

Required:
  --op OPERATION          pr-create|pr-list|pr-status|pr-close|pr-view|repo-view
  --github-repo OWNER/REPO
  --task-id ID

Optional:
  --branch BRANCH_NAME    Branch for PR operations
  --base-branch BASE      Base branch for pr-create (default: main)
  --title TITLE           PR title (required for pr-create)
  --body BODY             PR body (required for pr-create)
  --timeout SECS          Timeout in seconds (default: ${DEFAULT_TIMEOUT})

Exit codes:
  0   Success
  1   Error
  124 Timeout
EOF
    exit 1
}

parse_gh_args() {
    CLI_TASK_ID=""
    CLI_TIMEOUT="$DEFAULT_TIMEOUT"

    while [ $# -gt 0 ]; do
        case "$1" in
            --op)
                shift
                OPERATION="$1"
                ;;
            --github-repo)
                shift
                GITHUB_REPO="$1"
                ;;
            --branch)
                shift
                BRANCH_NAME="$1"
                ;;
            --base-branch)
                shift
                BASE_BRANCH="$1"
                ;;
            --title)
                shift
                TITLE="$1"
                ;;
            --body)
                shift
                BODY="$1"
                ;;
            --task-id)
                shift
                CLI_TASK_ID="$1"
                ;;
            --timeout)
                shift
                CLI_TIMEOUT="$1"
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
    if [ -z "$GITHUB_REPO" ]; then
        log_error "Missing required argument: --github-repo"
        return 1
    fi
    if [ -z "$CLI_TASK_ID" ]; then
        log_error "Missing required argument: --task-id"
        return 1
    fi
}

require_value() {
    _name="$1"
    _value="$2"
    if [ -z "$_value" ]; then
        log_error "Missing required argument for ${OPERATION}: ${_name}"
        exit $EXIT_ERROR
    fi
}

run_logged() {
    log_info "Task ${CLI_TASK_ID}: $*"
    run_with_timeout "$CLI_TIMEOUT" "$@"
}

main() {
    if ! parse_gh_args "$@"; then
        usage
    fi

    if ! command -v gh >/dev/null 2>&1; then
        log_error "gh CLI not found in PATH"
        exit $EXIT_ERROR
    fi

    check_gh_token

    case "$OPERATION" in
        pr-create)
            require_value "--branch" "$BRANCH_NAME"
            require_value "--title" "$TITLE"
            require_value "--body" "$BODY"
            run_logged retry_with_backoff gh pr create --repo "$GITHUB_REPO" --head "$BRANCH_NAME" --base "$BASE_BRANCH" --title "$TITLE" --body "$BODY" --draft
            ;;

        pr-list)
            require_value "--branch" "$BRANCH_NAME"
            run_logged retry_with_backoff gh pr list --repo "$GITHUB_REPO" --head "$BRANCH_NAME" --json number,title,state,url
            ;;

        pr-status)
            run_logged retry_with_backoff gh pr status --repo "$GITHUB_REPO"
            ;;

        pr-close)
            require_value "--branch" "$BRANCH_NAME"
            run_logged retry_with_backoff gh pr close --repo "$GITHUB_REPO" "$BRANCH_NAME"
            ;;

        pr-view)
            require_value "--branch" "$BRANCH_NAME"
            run_logged retry_with_backoff gh pr view --repo "$GITHUB_REPO" "$BRANCH_NAME" --json number,title,state,url,isDraft
            ;;

        repo-view)
            run_logged retry_with_backoff gh repo view "$GITHUB_REPO" --json name,defaultBranchRef,description
            ;;

        *)
            log_error "Unsupported operation: ${OPERATION}"
            usage
            ;;
    esac
}

main "$@"
