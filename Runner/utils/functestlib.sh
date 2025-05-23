#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Resolve the directory of this script
# shellcheck disable=SC2037
UTILS_DIR=$(CDPATH=cd -- "$(dirname "$0")" >/dev/null 2>&1 && pwd)

# Safely source init_env if present
if [ -f "$UTILS_DIR/init_env" ]; then
    # shellcheck disable=SC1090
    . "$UTILS_DIR/init_env"
fi

# Import platform script if available
if [ -f "${TOOLS}/platform.sh" ]; then
    # shellcheck disable=SC1090
    . "${TOOLS}/platform.sh"
fi

# Set common directories (fallback if init_env not sourced)
__RUNNER_SUITES_DIR="${__RUNNER_SUITES_DIR:-${ROOT_DIR}/suites}"
#__RUNNER_UTILS_BIN_DIR="${__RUNNER_UTILS_BIN_DIR:-${ROOT_DIR}/common}"

# Logging function
log() {
    local level="$1"
    shift
    echo "[$level] $(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a /var/test_output.log
}

# Logging levels
log_info() { log "INFO" "$@"; }
log_pass() { log "PASS" "$@"; }
log_fail() { log "FAIL" "$@"; }
log_error() { log "ERROR" "$@"; }

# Dependency check
check_dependencies() {
    local missing=0
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "ERROR: Required command '$cmd' not found in PATH."
            missing=1
        fi
    done
    if [ "$missing" -ne 0 ]; then
        log_error "Exiting due to missing dependencies."
        exit 1
    else
        log_pass "Test related dependencies are present."
    fi
}

# Test case path search functions
find_test_case_by_name() {
    local test_name="$1"
    find "$__RUNNER_SUITES_DIR" -type d -iname "$test_name" 2>/dev/null
}

find_test_case_bin_by_name() {
    local test_name="$1"
    find "$__RUNNER_UTILS_BIN_DIR" -type f -iname "$test_name" 2>/dev/null
}

find_test_case_script_by_name() {
    local test_name="$1"
    find "$__RUNNER_UTILS_BIN_DIR" -type d -iname "$test_name" 2>/dev/null
}

# Documentation printer
FUNCTIONS="\
log_info \
log_pass \
log_fail \
log_error \
find_test_case_by_name \
find_test_case_bin_by_name \
find_test_case_script_by_name \
log \
"

functestlibdoc() {
    echo "functestlib.sh"
    echo ""
    echo "Functions:"
    for fn in $FUNCTIONS; do
        echo "$fn"
        eval "$fn""_doc"
        echo ""
    done
    echo "Note: These functions may not behave as expected on systems with >=32 CPUs"
}
