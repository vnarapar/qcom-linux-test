#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Exit on any command failure (optional for stricter CI)
#set -e

# shellcheck disable=SC1007,SC2037
SCRIPT_DIR="$(CDPATH=cd -- "$(dirname "$0")" >/dev/null 2>&1 && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/init_env"
# shellcheck source=/dev/null
. "${TOOLS}/functestlib.sh"

# Store results
RESULTS_PASS=""
RESULTS_FAIL=""

# Execute a test case
execute_test_case() {
    local test_path="$1"
    local test_name
    test_name=$(basename "$test_path")

    if [ -d "$test_path" ]; then
        run_script="$test_path/run.sh"
        if [ -f "$run_script" ]; then
            log "Executing test case: $test_name"
            if (cd "$test_path" && sh "./run.sh"); then
                log_pass "$test_name passed"
                RESULTS_PASS=$(printf "%s\n%s" "$RESULTS_PASS" "$test_name")
            else
                log_fail "$test_name failed"
                RESULTS_FAIL=$(printf "%s\n%s" "$RESULTS_FAIL" "$test_name")
            fi
        else
            log_error "No run.sh found in $test_path"
            RESULTS_FAIL=$(printf "%s\n%s" "$RESULTS_FAIL" "$test_name (missing run.sh)")
        fi
    else
        log_error "Test case directory not found: $test_path"
        RESULTS_FAIL=$(printf "%s\n%s" "$RESULTS_FAIL" "$test_name (directory not found)")
    fi
}

# Run test by name
run_specific_test_by_name() {
    local test_name="$1"
    local test_path
    test_path=$(find_test_case_by_name "$test_name")
    if [ -z "$test_path" ]; then
        log_error "Test case with name $test_name not found."
        RESULTS_FAIL=$(printf "%s\n%s" "$RESULTS_FAIL" "$test_name (not found)")
    else
        execute_test_case "$test_path"
    fi
}

# Run all test cases
run_all_tests() {
    find "${__RUNNER_SUITES_DIR}" -type d -name '[A-Za-z]*' -maxdepth 3 | while IFS= read -r test_dir; do
        if [ -f "$test_dir/run.sh" ]; then
            execute_test_case "$test_dir"
        fi
    done
}

# Print final summary
print_summary() {
    echo
    log_info "========== Test Summary =========="
    echo "PASSED:"
    [ -n "$RESULTS_PASS" ] && printf "%s\n" "$RESULTS_PASS" || echo " None"
    echo
    echo "FAILED:"
    [ -n "$RESULTS_FAIL" ] && printf "%s\n" "$RESULTS_FAIL" || echo " None"
    log_info "=================================="
}

# Main
if [ "$#" -eq 0 ]; then
    log "Usage: $0 [all | <testcase_name>]"
    exit 1
fi

if [ "$1" = "all" ]; then
    run_all_tests
else
    run_specific_test_by_name "$1"
fi

print_summary
