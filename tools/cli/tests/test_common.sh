#!/bin/sh
# test_common.sh — Tests for tools/cli/common.sh functions

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

. "$SCRIPT_DIR/assert_helpers.sh"
. "$SCRIPT_DIR/mock_helpers.sh"

# Source common.sh (sets set -e, defines functions)
. "$CLI_DIR/common.sh"

# Disable set -e for test execution — we handle errors explicitly
set +e

# ─── Test 1: timestamp_iso format ────────────────────────────────────────────

test_begin "timestamp_iso returns valid ISO 8601 format"
_ts=$(timestamp_iso)
case "$_ts" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
        test_pass
        ;;
    *)
        test_fail "got: $_ts"
        ;;
esac

# ─── Test 2: format_duration ─────────────────────────────────────────────────

test_begin "format_duration converts seconds correctly"
_d1=$(format_duration 5)
_d2=$(format_duration 65)
_d3=$(format_duration 3661)
if [ "$_d1" = "5s" ] && [ "$_d2" = "1m5s" ] && [ "$_d3" = "1h1m1s" ]; then
    test_pass
else
    test_fail "got: $_d1, $_d2, $_d3"
fi

# ─── Test 3: log_info writes to stderr ───────────────────────────────────────

test_begin "log_info writes [INFO] to stderr"
_out=$(log_info "test message" 2>&1)
assert_contains "[INFO]" "$_out" "should contain [INFO]"

# ─── Test 4: log_warn writes to stderr ───────────────────────────────────────

test_begin "log_warn writes [WARN] to stderr"
_out=$(log_warn "warning msg" 2>&1)
assert_contains "[WARN]" "$_out" "should contain [WARN]"

# ─── Test 5: log_error writes to stderr ──────────────────────────────────────

test_begin "log_error writes [ERROR] to stderr"
_out=$(log_error "error msg" 2>&1)
assert_contains "[ERROR]" "$_out" "should contain [ERROR]"

# ─── Test 6: retry_with_backoff succeeds first attempt ───────────────────────

test_begin "retry_with_backoff: success on first attempt"
setup_mock_bin
mock_sleep
retry_with_backoff true 2>/dev/null
assert_exit_code 0 $?

# Verify sleep was NOT called (no retries needed)
if [ -f "$MOCK_DIR/sleep_calls" ]; then
    test_begin "  (no sleep calls on success)"
    test_fail "sleep was called"
fi
cleanup_mocks

# ─── Test 7: retry_with_backoff retries then succeeds ────────────────────────

test_begin "retry_with_backoff: fails 2x then succeeds"
setup_mock_bin
mock_sleep

# Create a counter file — command fails twice then succeeds
_counter_file=$(mktemp)
echo "0" > "$_counter_file"

# Create a test command that fails twice then succeeds
cat > "$MOCK_DIR/flaky_cmd" <<EOF
#!/bin/sh
_count=\$(cat "$_counter_file")
_count=\$((_count + 1))
echo "\$_count" > "$_counter_file"
if [ "\$_count" -le 2 ]; then
    exit 1
fi
exit 0
EOF
chmod +x "$MOCK_DIR/flaky_cmd"

retry_with_backoff 3 2 flaky_cmd 2>/dev/null
_rc=$?
assert_exit_code 0 $_rc "should succeed after retries"

# Verify sleep was called (retries happened)
test_begin "  sleep called during retries"
if [ -f "$MOCK_DIR/sleep_calls" ]; then
    test_pass
else
    test_fail "sleep was not called"
fi

rm -f "$_counter_file"
cleanup_mocks

# ─── Test 8: retry_with_backoff exhausts retries ─────────────────────────────

test_begin "retry_with_backoff: always fails → non-zero exit"
setup_mock_bin
mock_sleep

# Must use subshell — retry_with_backoff re-enables set -e internally
_rc=0
(retry_with_backoff 2 1 false 2>/dev/null) || _rc=$?
assert_neq 0 "$_rc" "should return non-zero after exhausting retries"
cleanup_mocks

# ─── Test 9: retry_with_backoff no args ──────────────────────────────────────

test_begin "retry_with_backoff: no args → EXIT_ERROR"
_rc=0
(retry_with_backoff 2>/dev/null) || _rc=$?
assert_exit_code "$EXIT_ERROR" "$_rc" "missing command should return EXIT_ERROR"

# ─── Test 10: check_gh_token with token set ──────────────────────────────────

test_begin "check_gh_token: GH_TOKEN set → exit 0"
_rc=0
(GH_TOKEN="test-token" check_gh_token 2>/dev/null) || _rc=$?
assert_exit_code 0 "$_rc"

# ─── Test 11: check_gh_token without token ───────────────────────────────────

test_begin "check_gh_token: unset → exit non-zero"
_rc=0
(unset GH_TOKEN; check_gh_token 2>/dev/null) || _rc=$?
assert_neq 0 "$_rc" "should exit non-zero without GH_TOKEN"

# ─── Test 12: parse_cli_args sets fields ─────────────────────────────────────

test_begin "parse_cli_args: sets CLI_PROMPT and CLI_TASK_ID"
parse_cli_args --prompt "test prompt" --task-id "t-001" 2>/dev/null
if [ "$CLI_PROMPT" = "test prompt" ] && [ "$CLI_TASK_ID" = "t-001" ]; then
    test_pass
else
    test_fail "CLI_PROMPT='$CLI_PROMPT', CLI_TASK_ID='$CLI_TASK_ID'"
fi

# ─── Test 13: parse_cli_args missing --prompt ────────────────────────────────

test_begin "parse_cli_args: missing --prompt → returns 1"
_rc=0
parse_cli_args --task-id "t-002" 2>/dev/null || _rc=$?
assert_exit_code 1 "$_rc"

# ─── Test 14: parse_cli_args auto-generates task-id ──────────────────────────

test_begin "parse_cli_args: auto-generates task-id when missing"
CLI_TASK_ID=""
parse_cli_args --prompt "test" 2>/dev/null
assert_neq "" "$CLI_TASK_ID" "should auto-generate task ID"

# ─── Test 15: truncate_output truncates large file ───────────────────────────

test_begin "truncate_output: truncates file > MAX_OUTPUT"
_trunc_test_file=$(mktemp)
# Create a 60KB file (exceeds default MAX_OUTPUT of 50000)
dd if=/dev/zero bs=1024 count=60 2>/dev/null | tr '\0' 'A' > "$_trunc_test_file"
MAX_OUTPUT=1000 truncate_output "$_trunc_test_file" 1000
# Re-read the path since truncate_output uses _tmpfile internally (global scope clash)
_size=$(wc -c < "$_trunc_test_file" | tr -d ' ')
if [ "$_size" -le 1100 ]; then
    test_pass
else
    test_fail "file size $_size exceeds expected max"
fi
rm -f "$_trunc_test_file"

# ─── Test 16: truncate_output leaves small file ─────────────────────────────

test_begin "truncate_output: small file unchanged"
_small_test_file=$(mktemp)
echo "small content" > "$_small_test_file"
_before=$(wc -c < "$_small_test_file" | tr -d ' ')
truncate_output "$_small_test_file"
_after=$(wc -c < "$_small_test_file" | tr -d ' ')
assert_eq "$_before" "$_after" "file size should not change"
rm -f "$_small_test_file"

# ─── Test 17: run_with_timeout known bug ─────────────────────────────────────

test_begin "KNOWN BUG: run_with_timeout + shell function"
# run_with_timeout uses the `timeout` command which cannot execute
# shell functions (only external commands). This is a known limitation.
# When timeout tries to exec a function, it fails with "Permission denied"
# or "No such file or directory" (exit 126 or 127).
_rc=0
_my_func() { echo "hello"; }
run_with_timeout 5 _my_func 2>/dev/null || _rc=$?
if [ "$_rc" -eq 126 ] || [ "$_rc" -eq 127 ] || [ "$_rc" -eq 1 ]; then
    test_pass
else
    # If timeout command is not available, POSIX fallback may work
    test_skip "run_with_timeout may use POSIX fallback (exit=$_rc)"
fi

# ─── Test 18: sourcing common.sh twice is idempotent ─────────────────────────

test_begin "common.sh: sourcing twice is idempotent"
_es_before="$EXIT_SUCCESS"
_ee_before="$EXIT_ERROR"
. "$CLI_DIR/common.sh"
set +e  # Re-disable after sourcing (common.sh sets set -e)
if [ "$EXIT_SUCCESS" = "$_es_before" ] && [ "$EXIT_ERROR" = "$_ee_before" ]; then
    # Also verify functions still work
    _ts=$(timestamp_iso)
    case "$_ts" in
        [0-9][0-9][0-9][0-9]-*)
            test_pass
            ;;
        *)
            test_fail "timestamp_iso broken after re-source"
            ;;
    esac
else
    test_fail "variables changed after re-source"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

test_summary
