# Current Goal

## Objective
Add shell script unit tests for OCMA CLI tools (common.sh, git.sh, gh.sh).

## Context
Target repo: seokmogu/openclaw-multi-agent (main branch). CLI tools in /project/tools/cli/. Key functions to test: retry_with_backoff, check_gh_token, run_with_timeout, parse_cli_args, truncate_output, git clone/push ops, gh PR creation. POSIX shell scripts, total ~1243 lines across 7 files.

## Success Criteria
- [ ] Test suite covers core functions in common.sh (retry_with_backoff, check_gh_token, run_with_timeout, parse_cli_args, truncate_output)
- [ ] Test suite covers git.sh operations (clone, branch, push) with mocks
- [ ] Test suite covers gh.sh operations (pr-create, pr-list) with mocks
- [ ] Edge cases handled (empty args, missing env vars, permission denied)
- [ ] Tests runnable without external dependencies (no real git repos or GitHub API)

## Current Phase
propose

## Last Updated
2026-03-08T14:43:30Z
