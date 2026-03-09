#!/bin/sh
# test_runner.sh — Minimal POSIX test runner for OCMA CLI tools
# Usage: sh tools/cli/tests/test_runner.sh
# Discovers and runs all test_*.sh files, counts PASS/FAIL from output.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

printf "╔══════════════════════════════════════════════════════════════╗\n"
printf "║  OCMA CLI Tools — Test Suite                               ║\n"
printf "╚══════════════════════════════════════════════════════════════╝\n\n"

_start_time=$(date +%s)
_total_pass=0
_total_fail=0
_total_skip=0
_any_error=0

_test_files=$(find "$SCRIPT_DIR" -name "test_*.sh" -not -name "test_runner.sh" | sort)

if [ -z "$_test_files" ]; then
    printf "No test files found in %s\n" "$SCRIPT_DIR"
    exit 1
fi

for _test_file in $_test_files; do
    _basename=$(basename "$_test_file")
    printf "━━━ %s ━━━\n" "$_basename"

    _outfile=$(mktemp)

    # Run test file in subshell; capture output; don't let failures kill runner
    set +e
    sh "$_test_file" > "$_outfile" 2>&1
    _rc=$?
    set -e

    grep -v "^RESULT:" "$_outfile" || true

    # Count results from output markers
    _p=$(grep -c "^RESULT:PASS" "$_outfile" 2>/dev/null || true)
    _f=$(grep -c "^RESULT:FAIL" "$_outfile" 2>/dev/null || true)
    _s=$(grep -c "^RESULT:SKIP" "$_outfile" 2>/dev/null || true)
    # Ensure numeric (grep -c returns empty on some shells when no match)
    _p=${_p:-0}; _f=${_f:-0}; _s=${_s:-0}
    case "$_p" in ''|*[!0-9]*) _p=0;; esac
    case "$_f" in ''|*[!0-9]*) _f=0;; esac
    case "$_s" in ''|*[!0-9]*) _s=0;; esac

    _total_pass=$((_total_pass + _p))
    _total_fail=$((_total_fail + _f))
    _total_skip=$((_total_skip + _s))

    rm -f "$_outfile"

    # Belt-and-suspenders: clean up leftover mock dirs
    rm -rf /tmp/ocma_mock_* 2>/dev/null || true

    if [ "$_rc" -ne 0 ]; then
        printf "  [RUNNER] test file exited with code %d\n" "$_rc"
        _any_error=1
    fi
    printf "\n"
done

_end_time=$(date +%s)
_duration=$((_end_time - _start_time))

printf "══════════════════════════════════════════════════════════════\n"
printf "Results: %d passed, %d failed, %d skipped (%ds)\n" \
    "$_total_pass" "$_total_fail" "$_total_skip" "$_duration"
printf "══════════════════════════════════════════════════════════════\n"

if [ "$_total_fail" -gt 0 ] || [ "$_any_error" -ne 0 ]; then
    exit 1
fi
exit 0
