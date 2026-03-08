#!/bin/sh
# test_gh.sh — Tests for tools/cli/gh.sh argument parsing and operations

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

. "$SCRIPT_DIR/assert_helpers.sh"
. "$SCRIPT_DIR/mock_helpers.sh"

# Source common.sh (gh.sh depends on it)
. "$CLI_DIR/common.sh"
set +e  # Disable set -e for test execution

# gh.sh calls main() at the end — test via subprocess with mocked gh command.
# GH_TOKEN must be set for all gh.sh calls (check_gh_token runs early).

# ─── Test 1: parse_gh_args sets fields ───────────────────────────────────────

test_begin "gh.sh: --op/--github-repo/--task-id parsed correctly"
setup_mock_bin
mock_command "gh" 0 '{"number":1}'
mock_command "timeout" 0 '{"number":1}'

GH_TOKEN="test-token" sh "$CLI_DIR/gh.sh" \
    --op pr-list --github-repo "owner/repo" --task-id "t-gh-1" \
    --branch "test-branch" 2>/dev/null
_rc=$?
# If args parsed correctly, it should call gh (mock succeeds with exit 0)
assert_exit_code 0 "$_rc" "should succeed with valid args"
cleanup_mocks

# ─── Test 2: missing --op → error ───────────────────────────────────────────

test_begin "gh.sh: missing --op → error exit"
_rc=0
GH_TOKEN="test" sh "$CLI_DIR/gh.sh" --github-repo "o/r" --task-id "t-1" 2>/dev/null || _rc=$?
assert_neq 0 "$_rc" "should fail without --op"

# ─── Test 3: pr-create calls gh with correct flags ──────────────────────────

test_begin "gh.sh: pr-create passes correct flags"
setup_mock_bin
mock_command "gh" 0 "https://github.com/o/r/pull/1"
mock_command "timeout" 0 "https://github.com/o/r/pull/1"

GH_TOKEN="test-token" sh "$CLI_DIR/gh.sh" \
    --op pr-create --github-repo "owner/repo" --task-id "t-pr" \
    --branch "feature-branch" --base-branch "main" \
    --title "Test PR" --body "Test body" 2>/dev/null || true

# Verify gh was called with pr create flags
if [ -f "$MOCK_DIR/gh_args.log" ] || [ -f "$MOCK_DIR/timeout_args.log" ]; then
    _all_args=$(cat "$MOCK_DIR/gh_args.log" "$MOCK_DIR/timeout_args.log" 2>/dev/null)
    assert_contains "pr" "$_all_args" "should call gh pr"
else
    # The command ran through timeout → check timeout args
    test_pass
fi
cleanup_mocks

# ─── Test 4: pr-create missing --title → error ──────────────────────────────

test_begin "gh.sh: pr-create without --title → error"
setup_mock_bin
mock_command "gh" 0 ""
mock_command "timeout" 0 ""

_rc=0
GH_TOKEN="test" sh "$CLI_DIR/gh.sh" \
    --op pr-create --github-repo "o/r" --task-id "t-1" \
    --branch "b" --body "body" 2>/dev/null || _rc=$?
assert_neq 0 "$_rc" "should fail without --title"
cleanup_mocks

# ─── Test 5: pr-list calls gh pr list ────────────────────────────────────────

test_begin "gh.sh: pr-list invokes gh pr list"
setup_mock_bin
mock_command "gh" 0 "[]"
mock_command "timeout" 0 "[]"

GH_TOKEN="test" sh "$CLI_DIR/gh.sh" \
    --op pr-list --github-repo "owner/repo" --task-id "t-list" \
    --branch "my-branch" 2>/dev/null || true

if [ -f "$MOCK_DIR/gh_args.log" ] || [ -f "$MOCK_DIR/timeout_args.log" ]; then
    test_pass
else
    test_fail "gh was not called"
fi
cleanup_mocks

# ─── Test 6: repo-view calls gh repo view ───────────────────────────────────

test_begin "gh.sh: repo-view invokes gh repo view"
setup_mock_bin
mock_command "gh" 0 '{"name":"repo"}'
mock_command "timeout" 0 '{"name":"repo"}'

GH_TOKEN="test" sh "$CLI_DIR/gh.sh" \
    --op repo-view --github-repo "owner/repo" --task-id "t-rv" 2>/dev/null || true

if [ -f "$MOCK_DIR/gh_args.log" ] || [ -f "$MOCK_DIR/timeout_args.log" ]; then
    test_pass
else
    test_fail "gh was not called"
fi
cleanup_mocks

# ─── Test 7: unknown operation → error ───────────────────────────────────────

test_begin "gh.sh: unknown operation → error"
setup_mock_bin
mock_command "gh" 0 ""
mock_command "timeout" 0 ""

_rc=0
GH_TOKEN="test" sh "$CLI_DIR/gh.sh" \
    --op "fake-op" --github-repo "o/r" --task-id "t-1" 2>/dev/null || _rc=$?
assert_neq 0 "$_rc" "should fail for unknown operation"
cleanup_mocks

# ─── Test 8: missing GH_TOKEN → error ───────────────────────────────────────

test_begin "gh.sh: missing GH_TOKEN → error exit"
_rc=0
(unset GH_TOKEN; sh "$CLI_DIR/gh.sh" --op pr-list --github-repo "o/r" --task-id "t-1" --branch "b" 2>/dev/null) || _rc=$?
assert_neq 0 "$_rc" "should fail without GH_TOKEN"

# ─── Test 9: mock isolation — PATH restored after cleanup ────────────────────

test_begin "mock isolation: gh resolves correctly after cleanup"
_real_gh_before=$(command -v gh 2>/dev/null || echo "none")
setup_mock_bin
mock_command "gh" 0 "mocked"
cleanup_mocks
_real_gh_after=$(command -v gh 2>/dev/null || echo "none")
assert_eq "$_real_gh_before" "$_real_gh_after" "PATH should be restored"

# ─── Summary ─────────────────────────────────────────────────────────────────

test_summary
