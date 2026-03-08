#!/bin/sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

TOOL_NAME="git"

OPERATION=""
REPO_NAME=""
GITHUB_REPO=""
BRANCH_NAME=""
MESSAGE=""
BASE_BRANCH="main"

usage() {
    cat >&2 <<EOF
Usage: $0 --op OPERATION --repo REPO --task-id ID [OPTIONS]

Required:
  --op OPERATION         clone|branch-create|checkout|commit|push|status|diff|log|rebase|worktree-prune|remote-url
  --repo REPO            Repository name (e.g., agent-recruitment-platform)
  --task-id ID           Task identifier (used for clone path)

Optional:
  --github-repo OWNER/REPO  Full GitHub repository (required for clone)
  --branch BRANCH_NAME      Branch for branch-create/checkout/push
  --message MESSAGE         Commit message for commit operation
  --base-branch BASE        Base branch (default: main)
  --timeout SECS            Timeout in seconds (default: ${DEFAULT_TIMEOUT})

Exit codes:
  0   Success
  1   Error
  124 Timeout
EOF
    exit 1
}

parse_git_args() {
    CLI_TASK_ID=""
    CLI_TIMEOUT="$DEFAULT_TIMEOUT"

    while [ $# -gt 0 ]; do
        case "$1" in
            --op)
                shift
                OPERATION="$1"
                ;;
            --repo)
                shift
                REPO_NAME="$1"
                ;;
            --github-repo)
                shift
                GITHUB_REPO="$1"
                ;;
            --branch)
                shift
                BRANCH_NAME="$1"
                ;;
            --message)
                shift
                MESSAGE="$1"
                ;;
            --base-branch)
                shift
                BASE_BRANCH="$1"
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
    if [ -z "$REPO_NAME" ]; then
        log_error "Missing required argument: --repo"
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

validate_name() {
    _label="$1"
    _value="$2"
    case "$_value" in
        ""|-*)
            log_error "Invalid ${_label}: ${_value}"
            exit $EXIT_ERROR
            ;;
    esac
}

clone_path() {
    printf "%s/workspaces/.clones/%s/%s" "$PROJECT_ROOT" "$CLI_TASK_ID" "$REPO_NAME"
}

bare_repo_path() {
    printf "%s/workspaces/.repos/%s.git" "$PROJECT_ROOT" "$REPO_NAME"
}

run_logged() {
    log_info "Task ${CLI_TASK_ID}: $*"
    run_with_timeout "$CLI_TIMEOUT" "$@"
}

main() {
    if ! parse_git_args "$@"; then
        usage
    fi

    if ! command -v git >/dev/null 2>&1; then
        log_error "git CLI not found in PATH"
        exit $EXIT_ERROR
    fi

    validate_name "repo" "$REPO_NAME"

    CLONE_PATH="$(clone_path)"
    BARE_PATH="$(bare_repo_path)"

    if [ "$OPERATION" != "clone" ] && [ ! -d "$CLONE_PATH" ]; then
        log_error "Clone path does not exist: ${CLONE_PATH}. Run --op clone first."
        exit $EXIT_ERROR
    fi

    case "$OPERATION" in
        clone)
            require_value "--github-repo" "$GITHUB_REPO"

            run_logged mkdir -p "${PROJECT_ROOT}/workspaces/.repos"
            run_logged mkdir -p "${PROJECT_ROOT}/workspaces/.clones/${CLI_TASK_ID}"

            if [ ! -d "$BARE_PATH" ]; then
                log_info "Task ${CLI_TASK_ID}: creating bare cache at ${BARE_PATH}"
                run_logged retry_with_backoff git clone --bare "https://github.com/${GITHUB_REPO}.git" "$BARE_PATH"
            else
                # Check if bare cache is stale (older than 24 hours = 1440 minutes)
                # Use POSIX-compatible find with -mmin for portability
                _cache_file="$BARE_PATH/FETCH_HEAD"
                if [ ! -f "$_cache_file" ]; then
                    _cache_file="$BARE_PATH/HEAD"
                fi
                
                if [ -f "$_cache_file" ] && [ -n "$(find "$_cache_file" -mmin +1440 2>/dev/null)" ]; then
                    # Cache is stale, refresh it
                    log_info "Task ${CLI_TASK_ID}: refreshing stale bare cache at ${BARE_PATH}"
                    run_logged retry_with_backoff git -C "$BARE_PATH" fetch --prune origin
                else
                    log_info "Task ${CLI_TASK_ID}: using fresh bare cache at ${BARE_PATH}"
                fi
            fi

            if [ -d "$CLONE_PATH" ]; then
                log_warn "Clone path already exists, reusing: ${CLONE_PATH}"
            else
                run_logged git clone "$BARE_PATH" "$CLONE_PATH"
            fi

            run_logged git -C "$CLONE_PATH" remote set-url origin "https://github.com/${GITHUB_REPO}.git"
            run_logged retry_with_backoff git -C "$CLONE_PATH" fetch origin

            printf "%s\n" "$CLONE_PATH"
            ;;

        branch-create)
            require_value "--branch" "$BRANCH_NAME"
            validate_name "branch" "$BRANCH_NAME"
            run_logged git -C "$CLONE_PATH" checkout -b "$BRANCH_NAME" "$BASE_BRANCH"
            printf "%s\n" "$BRANCH_NAME"
            ;;

        checkout)
            require_value "--branch" "$BRANCH_NAME"
            validate_name "branch" "$BRANCH_NAME"
            run_logged git -C "$CLONE_PATH" checkout "$BRANCH_NAME"
            ;;

        commit)
            require_value "--message" "$MESSAGE"
            run_logged git -C "$CLONE_PATH" add -A

            if run_with_timeout "$CLI_TIMEOUT" git -C "$CLONE_PATH" diff --cached --quiet; then
                log_warn "No staged changes to commit"
                exit $EXIT_SUCCESS
            fi

            run_logged git -C "$CLONE_PATH" commit -m "$MESSAGE"
            ;;

        push)
            require_value "--branch" "$BRANCH_NAME"
            validate_name "branch" "$BRANCH_NAME"
            case "$BRANCH_NAME" in
                main|master)
                    log_error "Refusing to push protected branch: ${BRANCH_NAME}"
                    exit $EXIT_ERROR
                    ;;
                *--force*|-f)
                    log_error "Refusing force push"
                    exit $EXIT_ERROR
                    ;;
            esac
            run_logged retry_with_backoff git -C "$CLONE_PATH" push -u origin "$BRANCH_NAME"
            ;;

        status)
            run_logged git -C "$CLONE_PATH" status --porcelain
            ;;

        diff)
            run_logged git -C "$CLONE_PATH" diff --stat
            ;;

        log)
            run_logged git -C "$CLONE_PATH" log --oneline -10
            ;;

        rebase)
            run_logged retry_with_backoff git -C "$CLONE_PATH" fetch origin
            if ! run_with_timeout "$CLI_TIMEOUT" git -C "$CLONE_PATH" rebase "origin/${BASE_BRANCH}"; then
                log_error "Rebase failed (likely conflict), aborting rebase"
                run_with_timeout "$CLI_TIMEOUT" git -C "$CLONE_PATH" rebase --abort >/dev/null 2>&1 || true
                exit $EXIT_ERROR
            fi
            ;;

        worktree-prune)
            run_logged git -C "$CLONE_PATH" worktree prune
            ;;

        remote-url)
            run_logged git -C "$CLONE_PATH" remote get-url origin
            ;;

        *)
            log_error "Unsupported operation: ${OPERATION}"
            usage
            ;;
    esac
}

main "$@"
