#!/bin/sh
# mock_helpers.sh — PATH-based command mocking for POSIX shell tests
# Source this in test files that need to mock external commands.

MOCK_DIR=""
ORIGINAL_PATH="$PATH"

# Create a temp mock directory and prepend it to PATH.
# Registers trap EXIT for automatic cleanup.
setup_mock_bin() {
    MOCK_DIR="/tmp/ocma_mock_$$"
    mkdir -p "$MOCK_DIR"
    ORIGINAL_PATH="$PATH"
    PATH="$MOCK_DIR:$PATH"
    export PATH
    trap 'cleanup_mocks' EXIT
}

# Create a mock command stub in the mock directory.
# Usage: mock_command NAME EXIT_CODE [STDOUT] [ARGS_LOG_FILE]
mock_command() {
    _name="$1"
    _exit_code="${2:-0}"
    _stdout="${3:-}"
    _args_log="${4:-$MOCK_DIR/${_name}_args.log}"

    cat > "$MOCK_DIR/$_name" <<MOCK_EOF
#!/bin/sh
echo "\$@" >> "$_args_log"
printf '%s' "$_stdout"
exit $_exit_code
MOCK_EOF
    chmod +x "$MOCK_DIR/$_name"
}

# Replace sleep with a no-op that logs calls.
mock_sleep() {
    _sleep_log="$MOCK_DIR/sleep_calls"
    cat > "$MOCK_DIR/sleep" <<MOCK_EOF
#!/bin/sh
echo "\$@" >> "$_sleep_log"
MOCK_EOF
    chmod +x "$MOCK_DIR/sleep"
}

# Remove mock directory and restore PATH.
cleanup_mocks() {
    if [ -n "$MOCK_DIR" ] && [ -d "$MOCK_DIR" ]; then
        rm -rf "$MOCK_DIR"
    fi
    if [ -n "$ORIGINAL_PATH" ]; then
        PATH="$ORIGINAL_PATH"
        export PATH
    fi
    MOCK_DIR=""
}
