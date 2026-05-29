#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"
INIT_ENV=""
SEARCH="$SCRIPT_DIR"

while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then
        INIT_ENV="$SEARCH/init_env"
        break
    fi
    SEARCH=$(dirname "$SEARCH")
done

if [ -z "$INIT_ENV" ]; then
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="hotplug"

test_path="$(find_test_case_by_name "$TESTNAME")"
if [ -n "$test_path" ]; then
    cd "$test_path" || exit 1
else
    log_warn "Path not found for $TESTNAME test. Falling back to SCRIPT_DIR: $SCRIPT_DIR"
    test_path="$SCRIPT_DIR"
    cd "$test_path" || exit 1
fi

res_file="./$TESTNAME.res"
out_dir="./out"

HOTPLUG_BOOT_SETTLE_SECONDS="${HOTPLUG_BOOT_SETTLE_SECONDS:-10}"
HOTPLUG_RETRIES=3
HOTPLUG_RETRY_DELAY_SECONDS=5
HOTPLUG_RESTORE_DELAY_SECONDS=1

# Optional debug-only override. Empty means runtime-discover all online CPUs.
HOTPLUG_CPU_LIST="${HOTPLUG_CPU_LIST:-}"

mkdir -p "$out_dir"
rm -f "$res_file"
cpu_hotplug_reset_registry

trap 'cpu_hotplug_cleanup_registered' EXIT INT TERM

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="
log_info "Policy, runtime-discovered CPU hotplug validation"
log_info "Config, BOOT_SETTLE=${HOTPLUG_BOOT_SETTLE_SECONDS}s RETRIES=$HOTPLUG_RETRIES RETRY_DELAY=${HOTPLUG_RETRY_DELAY_SECONDS}s RESTORE_DELAY=${HOTPLUG_RESTORE_DELAY_SECONDS}s"

if [ -n "$HOTPLUG_CPU_LIST" ]; then
    log_info "CPU selection override, HOTPLUG_CPU_LIST=$HOTPLUG_CPU_LIST"
else
    log_info "CPU selection, using runtime-discovered online CPUs"
fi

deps_list="cat grep awk sed tr sleep taskset mkdir rm id tail dmesg"

log_info "Checking dependencies: $deps_list"
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies "$deps_list"; then
    log_skip "$TESTNAME SKIP - missing one or more dependencies: $deps_list"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    log_fail "$TESTNAME FAIL - root privilege is required for CPU hotplug validation"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

if [ ! -r /sys/devices/system/cpu/online ]; then
    log_fail "Unable to read /sys/devices/system/cpu/online"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

if ! check_kernel_config "CONFIG_HOTPLUG_CPU"; then
    log_fail "CONFIG_HOTPLUG_CPU is required for CPU hotplug validation"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

log_info "Waiting ${HOTPLUG_BOOT_SETTLE_SECONDS}s for system to settle before CPU hotplug"
sleep "$HOTPLUG_BOOT_SETTLE_SECONDS"

cpu_hotplug_log_topology

online_cpus="$(get_online_cpus)"
online_count="$(printf '%s\n' "$online_cpus" | awk 'NF { count++ } END { print count + 0 }')"

if [ "$online_count" -lt 2 ]; then
    log_skip "$TESTNAME SKIP - fewer than two online CPUs available; cannot offline the last runnable CPU safely"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

if [ -n "$HOTPLUG_CPU_LIST" ]; then
    selected_cpus="$(expand_cpu_list "$HOTPLUG_CPU_LIST")"
else
    selected_cpus="$online_cpus"
fi

if [ -z "$selected_cpus" ]; then
    log_fail "No CPUs selected for hotplug validation"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

selected_count="$(printf '%s\n' "$selected_cpus" | awk 'NF { count++ } END { print count + 0 }')"

log_info "Selected CPUs for hotplug validation:"
printf '%s\n' "$selected_cpus" |
while IFS= read -r cpu_index || [ -n "$cpu_index" ]; do
    [ -n "$cpu_index" ] || continue
    cpu_hotplug_log_cpu_topology_one "$cpu_index"
done

controllable=0
tested=0
passed=0
failed=0
skipped=0

for cpu_index in $selected_cpus; do
    log_info "----- Testing CPU$cpu_index -----"

    if ! cpu_hotplug_in_online_mask "$cpu_index"; then
        log_skip "CPU$cpu_index is not present in the current online CPU mask"
        skipped=$((skipped + 1))
        continue
    fi

    online_file="$(cpu_hotplug_control_file "$cpu_index")"

    if [ ! -e "$online_file" ]; then
        log_skip "CPU$cpu_index has no online control file; not hotplug-controllable on this platform"
        skipped=$((skipped + 1))
        continue
    fi

    if [ ! -w "$online_file" ]; then
        log_skip "CPU$cpu_index online control file is not writable; not hotplug-controllable in this environment"
        skipped=$((skipped + 1))
        continue
    fi

    controllable=$((controllable + 1))

    cpu_is_schedulable "$cpu_index"
    sched_rc=$?

    if [ "$sched_rc" -eq 2 ]; then
        log_fail "taskset is not available during CPU$cpu_index schedulability check"
        failed=$((failed + 1))
        continue
    fi

    if [ "$sched_rc" -ne 0 ]; then
        log_fail "CPU$cpu_index is not schedulable before hotplug"
        failed=$((failed + 1))
        continue
    fi

    cpu_hotplug_try_offline_with_retry "$cpu_index" "$HOTPLUG_RETRIES" "$HOTPLUG_RETRY_DELAY_SECONDS" "$out_dir"
    offline_rc=$?

    if [ "$offline_rc" -ne 0 ]; then
        log_fail "CPU$cpu_index failed to offline after robust retry handling"
        failed=$((failed + 1))
        continue
    fi

    cpu_hotplug_record_offlined_cpu "$cpu_index"
    tested=$((tested + 1))

    sleep "$HOTPLUG_RESTORE_DELAY_SECONDS"

    cpu_state="$(cpu_hotplug_read_state "$cpu_index")"

    if [ "$cpu_state" != "0" ]; then
        log_fail "CPU$cpu_index online state is '${cpu_state:-<empty>}' after offline request, expected 0"
        failed=$((failed + 1))
        cpu_hotplug_restore_best_effort "$cpu_index"
        continue
    fi

    if cpu_hotplug_in_online_mask "$cpu_index"; then
        log_fail "CPU$cpu_index still appears in online mask after offline request"
        failed=$((failed + 1))
        cpu_hotplug_restore_best_effort "$cpu_index"
        continue
    fi

    if cpu_is_schedulable "$cpu_index"; then
        log_fail "CPU$cpu_index is still schedulable after being offlined"
        failed=$((failed + 1))
        cpu_hotplug_restore_best_effort "$cpu_index"
        continue
    fi

    log_pass "CPU$cpu_index successfully offlined"

    log_info "Attempting to online CPU$cpu_index"
    online_output="$(cpu_hotplug_write_state "$cpu_index" 1 "online" "$out_dir" 2>&1)"
    online_rc=$?

    if [ "$online_rc" -ne 0 ]; then
        log_fail "CPU$cpu_index failed to online rc=$online_rc output=${online_output:-<none>}"
        cpu_hotplug_log_dmesg_tail "$cpu_index" "online_error" "$out_dir"
        failed=$((failed + 1))
        continue
    fi

    sleep "$HOTPLUG_RESTORE_DELAY_SECONDS"

    cpu_state="$(cpu_hotplug_read_state "$cpu_index")"

    if [ "$cpu_state" != "1" ]; then
        log_fail "CPU$cpu_index online state is '${cpu_state:-<empty>}' after online request, expected 1"
        failed=$((failed + 1))
        continue
    fi

    if ! cpu_hotplug_in_online_mask "$cpu_index"; then
        log_fail "CPU$cpu_index not present in online mask after online request"
        failed=$((failed + 1))
        continue
    fi

    if ! cpu_is_schedulable "$cpu_index"; then
        log_fail "CPU$cpu_index is not schedulable after online request"
        failed=$((failed + 1))
        continue
    fi

    log_pass "CPU$cpu_index successfully restored online"
    passed=$((passed + 1))
done

cpu_hotplug_log_topology

log_info "=== CPU hotplug Summary ==="
log_info "HOTPLUG_SUMMARY: online=$online_count selected=$selected_count controllable=$controllable tested=$tested passed=$passed failed=$failed skipped=$skipped"

if [ "$failed" -gt 0 ]; then
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

if [ "$tested" -eq 0 ]; then
    log_skip "$TESTNAME SKIP - no runtime-discovered CPU completed hotplug validation"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

log_pass "$TESTNAME : Test Passed"
echo "$TESTNAME PASS" > "$res_file"
exit 0

