#!/bin/sh
# assert_helpers.sh — Test assertion functions for POSIX shell tests
# Source this in each test_*.sh file.

_TEST_PASS=0
_TEST_FAIL=0
_TEST_SKIP=0

test_begin() {
    printf "  %-55s " "$1"
}

test_pass() {
    _TEST_PASS=$((_TEST_PASS + 1))
    printf "✓ PASS\n"
    printf "RESULT:PASS\n"
}

test_fail() {
    _TEST_FAIL=$((_TEST_FAIL + 1))
    printf "✗ FAIL: %s\n" "$1"
    printf "RESULT:FAIL\n"
}

test_skip() {
    _TEST_SKIP=$((_TEST_SKIP + 1))
    printf "⊘ SKIP: %s\n" "${1:-}"
    printf "RESULT:SKIP\n"
}

assert_eq() {
    _expected="$1"
    _actual="$2"
    _msg="${3:-values should be equal}"
    if [ "$_expected" = "$_actual" ]; then
        test_pass
    else
        test_fail "$_msg: expected '$_expected', got '$_actual'"
    fi
}

assert_neq() {
    _expected="$1"
    _actual="$2"
    _msg="${3:-values should differ}"
    if [ "$_expected" != "$_actual" ]; then
        test_pass
    else
        test_fail "$_msg: expected NOT '$_expected'"
    fi
}

assert_contains() {
    _needle="$1"
    _haystack="$2"
    _msg="${3:-should contain substring}"
    case "$_haystack" in
        *"$_needle"*)
            test_pass
            ;;
        *)
            test_fail "$_msg: '$_needle' not found"
            ;;
    esac
}

assert_file_exists() {
    _file="$1"
    _msg="${2:-file should exist}"
    if [ -f "$_file" ]; then
        test_pass
    else
        test_fail "$_msg: '$_file' missing"
    fi
}

assert_exit_code() {
    assert_eq "$1" "$2" "${3:-exit code mismatch}"
}

test_summary() {
    printf "  --- %d passed, %d failed, %d skipped ---\n" \
        "$_TEST_PASS" "$_TEST_FAIL" "$_TEST_SKIP"
    if [ "$_TEST_FAIL" -gt 0 ]; then
        return 1
    fi
    return 0
}
