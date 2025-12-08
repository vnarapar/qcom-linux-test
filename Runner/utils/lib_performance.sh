#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Common performance-related helpers for KPI-style tests.

# ---------------------------------------------------------------------------
# Logging fallback (avoid repeated command -v checks)
# If functestlib.sh is sourced, these are already defined and we do nothing.
# ---------------------------------------------------------------------------
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"
: "${log_fail:=:}"
: "${log_skip:=:}"
: "${log_pass:=:}"

# ---------------------------------------------------------------------------
# Generic timestamp + escaping
# ---------------------------------------------------------------------------

nowstamp() {
    date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s
}

# Basic JSON string escaper (used by KPI tests)
esc() {
    # Escape backslash and double-quote
    printf '%s' "$1" | sed 's/\\/\\\\/g;s/"/\\"/g'
}

# ---------------------------------------------------------------------------
# CPU governor helpers
# ---------------------------------------------------------------------------

# Put all CPUs into performance governor, saving previous governor for restore.
# Uses SAVED_GOV_FILE (auto set if not provided).
set_performance_governor() {
    SAVED_GOV_FILE="${SAVED_GOV_FILE:-/tmp/perf_saved_governors.$$}"
    : >"$SAVED_GOV_FILE" 2>/dev/null || return 0

    for c in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "$c" ] || continue
        gov_file="$c/cpufreq/scaling_governor"
        [ -f "$gov_file" ] || continue

        cur_gov=$(cat "$gov_file" 2>/dev/null || echo "")
        # Record current governor
        printf '%s:%s\n' "$gov_file" "$cur_gov" >>"$SAVED_GOV_FILE" 2>/dev/null || true

        # Try to set performance, but do not fail test if it does not exist
        echo performance >"$gov_file" 2>/dev/null || true
    done

    log_info "CPU governors set to performance (saved in $SAVED_GOV_FILE)"
}

# Restore governors from the temp file created by set_performance_governor()
restore_governor() {
    if [ -z "${SAVED_GOV_FILE:-}" ]; then
        return 0
    fi
    if [ ! -f "$SAVED_GOV_FILE" ]; then
        return 0
    fi

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        gov_file=${line%%:*}
        old_gov=${line#*:}
        [ -f "$gov_file" ] || continue
        [ -n "$old_gov" ] || continue
        echo "$old_gov" >"$gov_file" 2>/dev/null || true
    done <"$SAVED_GOV_FILE"

    rm -f "$SAVED_GOV_FILE" 2>/dev/null || true

    log_info "Restored original CPU governors from saved state"
}

# ---------------------------------------------------------------------------
# Clocksource
# ---------------------------------------------------------------------------

# Capture the current clocksource into a text file.
# Usage: capture_clocksource /path/to/file
capture_clocksource() {
    out_file=$1
    [ -n "$out_file" ] || out_file="./clocksource.txt"

    if [ -r /sys/devices/system/clocksource/clocksource0/current_clocksource ]; then
        cs=$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource 2>/dev/null || echo "unknown")
        {
            echo "timestamp=$(nowstamp)"
            echo "clocksource=$cs"
        } >"$out_file" 2>/dev/null || true

        log_info "Clocksource: $cs → $out_file"
    else
        log_warn "current_clocksource not available; skipping clocksource capture"
    fi
}

# ---------------------------------------------------------------------------
# Boot type tag
# ---------------------------------------------------------------------------

# Capture boot type tag (cold/warm/unknown) into a text file.
# Usage: capture_boot_type <tag> <file>
capture_boot_type() {
    tag=$1
    out_file=$2

    [ -n "$tag" ] || tag="unknown"
    [ -n "$out_file" ] || out_file="./boot_type.txt"

    {
        echo "timestamp=$(nowstamp)"
        echo "boot_type=$tag"
    } >"$out_file" 2>/dev/null || true

    log_info "Boot type tagged as '$tag' → $out_file"
}

# ---------------------------------------------------------------------------
# System services / “heavy” log producers
# ---------------------------------------------------------------------------

# Optionally disable heavy services for KPI runs.
# Usage: disable_heavy_services_if_requested <disable_getty_flag> <disable_sshd_flag>
# Flags are "1" to disable, anything else to leave alone.
disable_heavy_services_if_requested() {
    disable_getty=$1
    disable_sshd=$2

    if ! command -v systemctl >/dev/null 2>&1; then
        log_warn "systemctl not found; cannot apply getty/sshd KPI tweaks"
        return 0
    fi

    if [ "$disable_getty" = "1" ]; then
        systemctl disable serial-getty@ttyS0.service >/dev/null 2>&1 || true
        systemctl stop serial-getty@ttyS0.service >/dev/null 2>&1 || true
        log_info "Disabled serial-getty@ttyS0.service for KPI run"
    fi

    if [ "$disable_sshd" = "1" ]; then
        systemctl disable sshd.service >/dev/null 2>&1 || true
        systemctl stop sshd.service >/dev/null 2>&1 || true
        log_info "Disabled sshd.service for KPI run"
    fi
}

# ---------------------------------------------------------------------------
# Bootchart
# ---------------------------------------------------------------------------

# Check if systemd-bootchart is enabled via kernel cmdline.
# Returns 0 if init=/lib/systemd/systemd-bootchart is present.
bootchart_enabled() {
    if [ -r /proc/cmdline ]; then
        grep -qw 'init=/lib/systemd/systemd-bootchart' /proc/cmdline 2>/dev/null
        return $?
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Boot KPI helpers: systemd-analyze time parsing + UEFI loader times + networkd
# ---------------------------------------------------------------------------

# Convert a single duration token like "3.801s", "174ms", "2min" to seconds.
perf_time_token_to_sec() {
  token="$1"
  [ -n "$token" ] || { echo ""; return 0; }

  printf '%s\n' "$token" | awk '
    {
      v = $1
      if (v ~ /min/) {
        gsub(/[^0-9.]/, "", v)
        if (v == "") { print ""; exit }
        s = v * 60
      } else if (v ~ /ms$/) {
        gsub(/[^0-9.]/, "", v)
        if (v == "") { print ""; exit }
        s = v / 1000.0
      } else if (v ~ /s$/) {
        gsub(/[^0-9.]/, "", v)
        if (v == "") { print ""; exit }
        s = v
      } else {
        s = 0
      }
    }
    END {
      if (s > 0) {
        printf("%.3f\n", s)
      }
    }'
}

# Convert a segment like "2min 7.045s" or "187ms" to seconds.
perf_time_segment_to_sec() {
  seg="$1"
  [ -n "$seg" ] || { echo ""; return 0; }

  printf '%s\n' "$seg" | awk '
    {
      sec = 0
      for (i = 1; i <= NF; i++) {
        v = $i
        if (v ~ /min/) {
          gsub(/[^0-9.]/, "", v)
          if (v != "") sec += v * 60
        } else if (v ~ /ms$/) {
          gsub(/[^0-9.]/, "", v)
          if (v != "") sec += v / 1000.0
        } else if (v ~ /s$/) {
          gsub(/[^0-9.]/, "", v)
          if (v != "") sec += v
        }
      }
    }
    END {
      if (sec > 0) {
        printf("%.3f\n", sec)
      }
    }'
}

# Read UEFI loader times from efivars (if present)
# Sets:
# PERF_UEFI_INIT_SEC, PERF_UEFI_EXEC_SEC, PERF_UEFI_TOTAL_SEC
perf_read_uefi_loader_times() {
  base="/sys/firmware/efi/efivars"
  init_var="$base/LoaderTimeInitUSec-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
  exec_var="$base/LoaderTimeExecUSec-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"

  PERF_UEFI_INIT_SEC=""
  PERF_UEFI_EXEC_SEC=""
  PERF_UEFI_TOTAL_SEC=""

  if [ ! -r "$init_var" ] || [ ! -r "$exec_var" ]; then
    export PERF_UEFI_INIT_SEC PERF_UEFI_EXEC_SEC PERF_UEFI_TOTAL_SEC
    return 0
  fi

  init_us=$(tail -c 8 "$init_var" 2>/dev/null | od -An -t u8 2>/dev/null | awk '{print $1}')
  exec_us=$(tail -c 8 "$exec_var" 2>/dev/null | od -An -t u8 2>/dev/null | awk '{print $1}')

  if [ -n "$init_us" ] && [ -n "$exec_us" ]; then
    PERF_UEFI_INIT_SEC=$(printf '%s\n' "$init_us" | awk '{printf("%.3f", $1/1000000)}')
    PERF_UEFI_EXEC_SEC=$(printf '%s\n' "$exec_us" | awk '{printf("%.3f", $1/1000000)}')
    PERF_UEFI_TOTAL_SEC=$(printf '%s %s\n' "$PERF_UEFI_INIT_SEC" "$PERF_UEFI_EXEC_SEC" \
      | awk '{printf("%.3f", $1 + $2)}')
  fi

  export PERF_UEFI_INIT_SEC PERF_UEFI_EXEC_SEC PERF_UEFI_TOTAL_SEC
}

# Parse systemd-analyze time output + blame, and optionally exclude services.
#
# perf_parse_boot_times <analyze_time.txt> <blame.txt> <exclude_networkd_flag> <exclude_services_list>
#
# Sets:
# PERF_FIRMWARE_SEC
# PERF_LOADER_SEC
# PERF_KERNEL_SEC
# PERF_USERSPACE_SEC
# PERF_TOTAL_SEC
# PERF_NETWORKD_WAIT_ONLINE_SEC
# PERF_EXCLUDED_SERVICES_LIST
# PERF_EXCLUDED_SERVICES_SEC
# PERF_EXCLUDED_TOTAL_SEC
# PERF_USERSPACE_EFFECTIVE_SEC
# PERF_TOTAL_EFFECTIVE_SEC
perf_parse_boot_times() {
  at_file="$1"
  blame_file="$2"
  exclude_networkd="$3"
  exclude_services_raw="$4"

  PERF_FIRMWARE_SEC=""
  PERF_LOADER_SEC=""
  PERF_KERNEL_SEC=""
  PERF_USERSPACE_SEC=""
  PERF_TOTAL_SEC=""
  PERF_NETWORKD_WAIT_ONLINE_SEC=""
  PERF_EXCLUDED_SERVICES_LIST=""
  PERF_EXCLUDED_SERVICES_SEC=""
  PERF_EXCLUDED_TOTAL_SEC=""
  PERF_USERSPACE_EFFECTIVE_SEC=""
  PERF_TOTAL_EFFECTIVE_SEC=""

  if [ ! -f "$at_file" ]; then
    export PERF_FIRMWARE_SEC PERF_LOADER_SEC PERF_KERNEL_SEC PERF_USERSPACE_SEC PERF_TOTAL_SEC \
           PERF_NETWORKD_WAIT_ONLINE_SEC PERF_EXCLUDED_SERVICES_LIST PERF_EXCLUDED_SERVICES_SEC \
           PERF_EXCLUDED_TOTAL_SEC PERF_USERSPACE_EFFECTIVE_SEC PERF_TOTAL_EFFECTIVE_SEC
    return 0
  fi

  line=$(grep -m1 'Startup finished in' "$at_file" 2>/dev/null || true)
  if [ -z "$line" ]; then
    export PERF_FIRMWARE_SEC PERF_LOADER_SEC PERF_KERNEL_SEC PERF_USERSPACE_SEC PERF_TOTAL_SEC \
           PERF_NETWORKD_WAIT_ONLINE_SEC PERF_EXCLUDED_SERVICES_LIST PERF_EXCLUDED_SERVICES_SEC \
           PERF_EXCLUDED_TOTAL_SEC PERF_USERSPACE_EFFECTIVE_SEC PERF_TOTAL_EFFECTIVE_SEC
    return 0
  fi

  firmware_tok=$(printf '%s\n' "$line" \
    | sed -n 's/.*Startup finished in \([^ ]*\) (firmware).*/\1/p')
  loader_tok=$(printf '%s\n' "$line" \
    | sed -n 's/.*(firmware) + \([^ ]*\) (loader).*/\1/p')
  kernel_tok=$(printf '%s\n' "$line" \
    | sed -n 's/.*(loader) + \([^ ]*\) (kernel).*/\1/p')
  userspace_seg=$(printf '%s\n' "$line" \
    | sed -n 's/.*(kernel) + \(.*\) (userspace) =.*/\1/p')
  total_seg=$(printf '%s\n' "$line" \
    | sed -n 's/.*= \(.*\)$/\1/p')

  PERF_FIRMWARE_SEC=$(perf_time_token_to_sec "$firmware_tok")
  PERF_LOADER_SEC=$(perf_time_token_to_sec "$loader_tok")
  PERF_KERNEL_SEC=$(perf_time_token_to_sec "$kernel_tok")
  PERF_USERSPACE_SEC=$(perf_time_segment_to_sec "$userspace_seg")
  PERF_TOTAL_SEC=$(perf_time_segment_to_sec "$total_seg")

  # --- systemd-networkd-wait-online.service contribution ---
  if [ "$exclude_networkd" = "1" ] && [ -f "$blame_file" ]; then
    net_seg=$(grep 'systemd-networkd-wait-online.service' "$blame_file" 2>/dev/null \
      | head -n 1 | awk '{print $1, $2}')
    PERF_NETWORKD_WAIT_ONLINE_SEC=$(perf_time_segment_to_sec "$net_seg")
  fi

  # --- Generic exclude-services list (comma or space separated) ---
  EX_SVC_LIST=""
  EX_SVC_TOTAL_SEC=""
  if [ -n "$exclude_services_raw" ] && [ -f "$blame_file" ]; then
    services=$(printf '%s\n' "$exclude_services_raw" | tr ',' ' ')
    for svc in $services; do
      [ -n "$svc" ] || continue

      # Avoid double-counting networkd if user also passed it in the list.
      if [ "$exclude_networkd" = "1" ] && [ "$svc" = "systemd-networkd-wait-online.service" ]; then
        continue
      fi

      line_svc=$(grep " $svc\$" "$blame_file" 2>/dev/null | head -n 1)
      [ -n "$line_svc" ] || continue

      seg_svc=$(printf '%s\n' "$line_svc" | awk '{print $1, $2}')
      sec_svc=$(perf_time_segment_to_sec "$seg_svc")
      [ -n "$sec_svc" ] || continue

      if [ -n "$EX_SVC_LIST" ]; then
        EX_SVC_LIST="$EX_SVC_LIST,$svc"
      else
        EX_SVC_LIST="$svc"
      fi

      if [ -n "$EX_SVC_TOTAL_SEC" ]; then
        EX_SVC_TOTAL_SEC=$(printf '%s %s\n' "$EX_SVC_TOTAL_SEC" "$sec_svc" \
          | awk '{printf("%.3f", $1 + $2)}')
      else
        EX_SVC_TOTAL_SEC="$sec_svc"
      fi
    done
  fi

  PERF_EXCLUDED_SERVICES_LIST="$EX_SVC_LIST"
  PERF_EXCLUDED_SERVICES_SEC="$EX_SVC_TOTAL_SEC"

  # --- Aggregate excluded total (networkd + generic services) ---
  EXCL_TOTAL=""
  if [ "$exclude_networkd" = "1" ] && [ -n "$PERF_NETWORKD_WAIT_ONLINE_SEC" ]; then
    EXCL_TOTAL="$PERF_NETWORKD_WAIT_ONLINE_SEC"
  fi
  if [ -n "$PERF_EXCLUDED_SERVICES_SEC" ]; then
    if [ -n "$EXCL_TOTAL" ]; then
      EXCL_TOTAL=$(printf '%s %s\n' "$EXCL_TOTAL" "$PERF_EXCLUDED_SERVICES_SEC" \
        | awk '{printf("%.3f", $1 + $2)}')
    else
      EXCL_TOTAL="$PERF_EXCLUDED_SERVICES_SEC"
    fi
  fi
  PERF_EXCLUDED_TOTAL_SEC="$EXCL_TOTAL"

  PERF_USERSPACE_EFFECTIVE_SEC="$PERF_USERSPACE_SEC"
  PERF_TOTAL_EFFECTIVE_SEC="$PERF_TOTAL_SEC"

  if [ -n "$EXCL_TOTAL" ] && [ -n "$PERF_USERSPACE_SEC" ] && [ -n "$PERF_TOTAL_SEC" ]; then
    PERF_USERSPACE_EFFECTIVE_SEC=$(printf '%s %s\n' "$PERF_USERSPACE_SEC" "$EXCL_TOTAL" \
      | awk '{d = $1 - $2; if (d < 0) d = 0; printf("%.3f\n", d)}')
    PERF_TOTAL_EFFECTIVE_SEC=$(printf '%s %s\n' "$PERF_TOTAL_SEC" "$EXCL_TOTAL" \
      | awk '{d = $1 - $2; if (d < 0) d = 0; printf("%.3f\n", d)}')
  fi

  export PERF_FIRMWARE_SEC PERF_LOADER_SEC PERF_KERNEL_SEC PERF_USERSPACE_SEC PERF_TOTAL_SEC \
         PERF_NETWORKD_WAIT_ONLINE_SEC PERF_EXCLUDED_SERVICES_LIST PERF_EXCLUDED_SERVICES_SEC \
         PERF_EXCLUDED_TOTAL_SEC PERF_USERSPACE_EFFECTIVE_SEC PERF_TOTAL_EFFECTIVE_SEC
}

# ---------------------------------------------------------------------------
# Boot-complete detection (multi-user.target)
# ---------------------------------------------------------------------------

# Wait for multi-user.target up to <timeout> seconds.
# Usage: wait_for_multi_user_target <timeout_seconds>
wait_for_multi_user_target() {
    timeout="$1"

    if ! command -v systemctl >/dev/null 2>&1; then
        log_warn "systemctl not found; cannot verify multi-user.target boot-complete state"
        return 0
    fi

    i=0
    while [ "$i" -lt "$timeout" ]; do
        if systemctl is-active --quiet multi-user.target; then
            log_info "Boot complete: multi-user.target is active"
            return 0
        fi
        sleep 1
        i=$((i+1))
    done

    if systemctl is-active --quiet multi-user.target; then
        log_info "Boot complete: multi-user.target became active after timeout window"
    else
        log_warn "multi-user.target not active after ${timeout}s; continuing KPI collection anyway"
    fi
}

# ---------------------------------------------------------------------------
# Boot KPI loop helpers: state + systemd hook + KPI CSV / averages
# ---------------------------------------------------------------------------

# Internal helper for safe double-quote escaping
perf_kpi_escape_dq() {
    printf '%s' "$1" | sed 's/\\/\\\\/g;s/"/\\"/g'
}

# Write/refresh KPI loop state file.
perf_kpi_write_loop_state() {
    state_file=$1
    iter_total=$2
    iter_done=$3
    boot_type=$4
    disable_getty=$5
    disable_sshd=$6
    exclude_networkd=$7
    exclude_services=$8
    kpi_script=$9
    kpi_out_dir=${10}

    dir=$(dirname "$state_file")
    mkdir -p "$dir" 2>/dev/null || true

    {
        echo "KPI_LOOP_ITERATIONS_TOTAL=$iter_total"
        echo "KPI_LOOP_ITERATIONS_DONE=$iter_done"
        echo "KPI_LOOP_BOOT_TYPE=\"$(perf_kpi_escape_dq "$boot_type")\""
        echo "KPI_LOOP_DISABLE_GETTY=$disable_getty"
        echo "KPI_LOOP_DISABLE_SSHD=$disable_sshd"
        echo "KPI_LOOP_EXCLUDE_NETWORKD=$exclude_networkd"
        echo "KPI_LOOP_EXCLUDE_SERVICES=\"$(perf_kpi_escape_dq "$exclude_services")\""
        echo "KPI_LOOP_KPI_SCRIPT=\"$(perf_kpi_escape_dq "$kpi_script")\""
        echo "KPI_LOOP_KPI_OUT_DIR=\"$(perf_kpi_escape_dq "$kpi_out_dir")\""
    } >"$state_file" 2>/dev/null || true

    log_info "KPI loop state written to $state_file (done=$iter_done, total=$iter_total)"
}

# Load KPI loop state; exports KPI_LOOP_* vars if present.
perf_kpi_load_loop_state() {
    state_file=$1
    if [ ! -f "$state_file" ]; then
        return 1
    fi

    # shellcheck disable=SC1090
    . "$state_file"

    export KPI_LOOP_ITERATIONS_TOTAL KPI_LOOP_ITERATIONS_DONE KPI_LOOP_BOOT_TYPE \
           KPI_LOOP_DISABLE_GETTY KPI_LOOP_DISABLE_SSHD KPI_LOOP_EXCLUDE_NETWORKD \
           KPI_LOOP_EXCLUDE_SERVICES KPI_LOOP_KPI_SCRIPT KPI_LOOP_KPI_OUT_DIR

    log_info "Loaded KPI loop state from $state_file (done=${KPI_LOOP_ITERATIONS_DONE:-0}, total=${KPI_LOOP_ITERATIONS_TOTAL:-1})"
    return 0
}

# Install a systemd hook to run the KPI loop script at each boot.
perf_install_kpi_systemd_hook() {
    kpi_script=$1
    svc_name=$2

    if [ -z "$kpi_script" ] || [ -z "$svc_name" ]; then
        log_error "perf_install_kpi_systemd_hook: missing script or service name"
        return 1
    fi

    case "$svc_name" in
        *.service) svc_name=${svc_name%.service} ;;
        *.timer) svc_name=${svc_name%.timer} ;;
    esac

    script_dir=$(dirname "$kpi_script")
    unit_dir=/etc/systemd/system

    service_unit="$unit_dir/$svc_name.service"
    timer_unit="$unit_dir/$svc_name.timer"

    log_info "Installing KPI loop systemd units: $service_unit + $timer_unit"

    cat >"$service_unit" <<EOF
[Unit]
Description=Perf KPI auto-reboot loop
After=multi-user.target
Wants=multi-user.target

[Service]
Type=oneshot
ExecStart=$kpi_script
WorkingDirectory=$script_dir
User=root

# The script's own state file controls:
# - whether AUTO_REBOOT is active
# - when to stop the loop and remove hooks
EOF

    cat >"$timer_unit" <<EOF
[Unit]
Description=Run Perf KPI auto-reboot loop after boot has settled

[Timer]
OnBootSec=30s
Unit=$svc_name.service
Persistent=true

[Install]
WantedBy=timers.target
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload || true
        systemctl enable --now "$svc_name.timer" || true
    else
        log_warn "systemctl not found, KPI loop units created but not enabled"
    fi

    return 0
}

# Remove systemd hook and reload daemon.
perf_remove_kpi_systemd_hook() {
    svc_name=$1

    if [ -z "$svc_name" ]; then
        log_error "perf_remove_kpi_systemd_hook: missing service name"
        return 1
    fi

    case "$svc_name" in
        *.service) svc_name=${svc_name%.service} ;;
        *.timer) svc_name=${svc_name%.timer} ;;
    esac

    unit_dir=/etc/systemd/system
    service_unit="$unit_dir/$svc_name.service"
    timer_unit="$unit_dir/$svc_name.timer"

    log_info "Removing KPI loop systemd units: $service_unit + $timer_unit"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "$svc_name.timer" 2>/dev/null || true
        systemctl disable "$svc_name.service" 2>/dev/null || true
    fi

    rm -f "$timer_unit" "$service_unit" 2>/dev/null || true

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload || true
    fi

    return 0
}

# Wait for systemd-analyze time to report a finished boot
wait_analyze_ready() {
    out_file=$1
    jobs_file=$2
    max_wait=${3:-180}
    interval=${4:-5}

    [ -z "$max_wait" ] && max_wait=180
    [ -z "$interval" ] && interval=5

    elapsed=0

    while :; do
        if systemd-analyze time >"$out_file" 2>&1; then
            if grep -q "Bootup is not yet finished" "$out_file"; then
                log_warn "systemd-analyze: boot not finished yet (elapsed=${elapsed}s); capturing systemctl list-jobs → $jobs_file"
                systemctl list-jobs >"$jobs_file" 2>&1 || true

                if [ "$elapsed" -ge "$max_wait" ]; then
                    log_warn "systemd-analyze: boot STILL not finished after ${elapsed}s; keeping analyze_time.txt as-is (KPI times may be 'unknown')."
                    return 1
                fi
            else
                log_info "systemd-analyze: boot finished; analyze_time.txt captured after ${elapsed}s."
                return 0
            fi
        else
            rc=$?
            log_warn "systemd-analyze time failed with rc=$rc; see $out_file for details."
            return 2
        fi

        sleep "$interval" || break
        elapsed=$((elapsed + interval))
    done

    log_warn "systemd-analyze: exited wait loop without finished-boot output; see $out_file / $jobs_file."
    return 1
}

# ---------------------------------------------------------------------------
# KPI file parsing + CSV append + averaging
# ---------------------------------------------------------------------------

kpi_get_line_val() {
    key=$1
    file=$2
    sed -n "s/^ ${key} : //p" "$file" 2>/dev/null | head -n 1
}

kpi_get_num_from_line() {
    key=$1
    file=$2
    val=$(kpi_get_line_val "$key" "$file")
    printf '%s\n' "$val" | awk '{print $1}'
}

perf_kpi_extract_from_file() {
    file=$1

    PERF_KPI_BOOT_TYPE=$(kpi_get_line_val "boot_type" "$file")
    PERF_KPI_ITERATIONS_HINT=$(kpi_get_line_val "iterations" "$file")
    PERF_KPI_CLOCKSOURCE=$(kpi_get_line_val "clocksource" "$file")

    PERF_KPI_UEFI_TIME_SEC=$(kpi_get_num_from_line "uefi_time_sec" "$file")
    PERF_KPI_FIRMWARE_SEC=$(kpi_get_num_from_line "firmware_time_sec" "$file")
    PERF_KPI_BOOTLOADER_SEC=$(kpi_get_num_from_line "bootloader_time_sec" "$file")
    PERF_KPI_KERNEL_SEC=$(kpi_get_num_from_line "kernel_time_sec" "$file")
    PERF_KPI_USERSPACE_SEC=$(kpi_get_num_from_line "userspace_time_sec" "$file")
    PERF_KPI_USERSPACE_EFFECTIVE_SEC=$(kpi_get_num_from_line "userspace_effective_time_sec" "$file")
    PERF_KPI_BOOT_TOTAL_SEC=$(kpi_get_num_from_line "boot_total_sec" "$file")
    PERF_KPI_BOOT_TOTAL_EFFECTIVE_SEC=$(kpi_get_num_from_line "boot_total_effective_sec" "$file")

    export PERF_KPI_BOOT_TYPE PERF_KPI_ITERATIONS_HINT PERF_KPI_CLOCKSOURCE \
           PERF_KPI_UEFI_TIME_SEC PERF_KPI_FIRMWARE_SEC PERF_KPI_BOOTLOADER_SEC \
           PERF_KPI_KERNEL_SEC PERF_KPI_USERSPACE_SEC PERF_KPI_USERSPACE_EFFECTIVE_SEC \
           PERF_KPI_BOOT_TOTAL_SEC PERF_KPI_BOOT_TOTAL_EFFECTIVE_SEC
}

perf_kpi_append_csv_row() {
    csv=$1
    override_bt=$2

    bt=$override_bt
    [ -n "$bt" ] || bt=$PERF_KPI_BOOT_TYPE

    if [ ! -f "$csv" ]; then
        echo "timestamp,boot_type,iterations_hint,clocksource,uefi_time_sec,firmware_time_sec,bootloader_time_sec,kernel_time_sec,userspace_time_sec,userspace_effective_time_sec,boot_total_sec,boot_total_effective_sec" >"$csv"
    fi

    ts=$(nowstamp)
    echo "$ts,$bt,$PERF_KPI_ITERATIONS_HINT,$PERF_KPI_CLOCKSOURCE,$PERF_KPI_UEFI_TIME_SEC,$PERF_KPI_FIRMWARE_SEC,$PERF_KPI_BOOTLOADER_SEC,$PERF_KPI_KERNEL_SEC,$PERF_KPI_USERSPACE_SEC,$PERF_KPI_USERSPACE_EFFECTIVE_SEC,$PERF_KPI_BOOT_TOTAL_SEC,$PERF_KPI_BOOT_TOTAL_EFFECTIVE_SEC" >>"$csv" 2>/dev/null || true

    log_info "Appended KPI row to $csv (boot_type=$bt, total_sec=${PERF_KPI_BOOT_TOTAL_SEC:-unknown}, total_eff_sec=${PERF_KPI_BOOT_TOTAL_EFFECTIVE_SEC:-unknown})"
}

perf_kpi_compute_average() {
    csv=$1
    bt=$2
    window=$3
    summary_file=$4

    if [ ! -f "$csv" ]; then
        log_warn "perf_kpi_compute_average: CSV not found: $csv"
        return 1
    fi

    tmp_filtered="${csv}.filtered.$$"
    tmp_last="${csv}.last.$$"

    awk -F',' -v bt="$bt" '
        NR == 1 { next }
        $2 == bt { print }
    ' "$csv" >"$tmp_filtered" 2>/dev/null || true

    tail -n "$window" "$tmp_filtered" >"$tmp_last" 2>/dev/null || true

    if [ ! -s "$tmp_last" ]; then
        rm -f "$tmp_filtered" "$tmp_last" 2>/dev/null || true
        log_warn "perf_kpi_compute_average: no entries for boot_type=$bt"
        return 1
    fi

    awk -F',' -v bt="$bt" -v target="$window" '
      {
        n++;
        if ($5 ~ /^[0-9.]+$/) { uefi_sum += $5; uefi_n++ }
        if ($6 ~ /^[0-9.]+$/) { fw_sum += $6; fw_n++ }
        if ($7 ~ /^[0-9.]+$/) { bl_sum += $7; bl_n++ }
        if ($8 ~ /^[0-9.]+$/) { k_sum += $8; k_n++ }
        if ($9 ~ /^[0-9.]+$/) { us_sum += $9; us_n++ }
        if ($10 ~ /^[0-9.]+$/) { use_sum += $10; use_n++ }
        if ($11 ~ /^[0-9.]+$/) { tot_sum += $11; tot_n++ }
        if ($12 ~ /^[0-9.]+$/) { tote_sum += $12; tote_n++ }
      }
      END {
        if (n == 0) { exit 0 }

        if (uefi_n > 0) uefi_avg = uefi_sum / uefi_n; else uefi_avg = -1;
        if (fw_n > 0) fw_avg = fw_sum / fw_n; else fw_avg = -1;
        if (bl_n > 0) bl_avg = bl_sum / bl_n; else bl_avg = -1;
        if (k_n > 0) k_avg = k_sum / k_n; else k_avg = -1;
        if (us_n > 0) us_avg = us_sum / us_n; else us_avg = -1;
        if (use_n > 0) use_avg = use_sum / use_n; else use_avg = -1;
        if (tot_n > 0) tot_avg = tot_sum / tot_n; else tot_avg = -1;
        if (tote_n > 0) tote_avg = tote_sum / tote_n; else tote_avg = -1;

        out = summary_file
        printf("Boot KPI summary (last %d %s boot(s))\n", n, bt) > out
        printf(" entries_used : %d\n", n) >> out
        printf(" target_iterations : %d\n", target) >> out
        printf(" boot_type : %s\n", bt) >> out

        if (uefi_avg >= 0)
          printf(" avg_uefi_time_sec : %.3f\n", uefi_avg) >> out
        if (fw_avg >= 0)
          printf(" avg_firmware_time_sec : %.3f\n", fw_avg) >> out
        if (bl_avg >= 0)
          printf(" avg_bootloader_time_sec : %.3f\n", bl_avg) >> out
        if (k_avg >= 0)
          printf(" avg_kernel_time_sec : %.3f\n", k_avg) >> out
        if (us_avg >= 0)
          printf(" avg_userspace_time_sec : %.3f\n", us_avg) >> out
        if (use_avg >= 0)
          printf(" avg_userspace_effective_time_sec : %.3f\n", use_avg) >> out
        if (tot_avg >= 0)
          printf(" avg_boot_total_sec : %.3f\n", tot_avg) >> out
        if (tote_avg >= 0)
          printf(" avg_boot_total_effective_sec : %.3f\n", tote_avg) >> out
      }
    ' summary_file="$summary_file" "$tmp_last"

    rm -f "$tmp_filtered" "$tmp_last" 2>/dev/null || true

    if [ -f "$summary_file" ]; then
        log_info "perf_kpi_compute_average: summary written to $summary_file"
    fi
}

# ---------------------------------------------------------------------------
# Boot identity + reboot tracking helpers for KPI loops
# ---------------------------------------------------------------------------

perf_kpi_get_boot_identity() {
    PERF_KPI_BOOT_ID="unknown"
    PERF_KPI_UPTIME_SEC=""

    if [ -r /proc/sys/kernel/random/boot_id ]; then
        PERF_KPI_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown")
    fi

    if [ -r /proc/uptime ]; then
        PERF_KPI_UPTIME_SEC=$(awk '{printf("%.3f\n", $1)}' /proc/uptime 2>/dev/null || echo "")
    fi

    export PERF_KPI_BOOT_ID PERF_KPI_UPTIME_SEC
}

perf_kpi_reboot_state_load() {
    state_file=$1

    PERF_KPI_STATE_BOOT_ID=""
    PERF_KPI_STATE_UPTIME=""
    PERF_KPI_STATE_PENDING="0"
    PERF_KPI_STATE_ITER_DONE=""

    if [ -f "$state_file" ]; then
        while IFS='=' read -r k v; do
            case "$k" in
                boot_id) PERF_KPI_STATE_BOOT_ID=$v ;;
                uptime_sec) PERF_KPI_STATE_UPTIME=$v ;;
                pending_reboot) PERF_KPI_STATE_PENDING=$v ;;
                iterations_done) PERF_KPI_STATE_ITER_DONE=$v ;;
            esac
        done <"$state_file"
    fi

    export PERF_KPI_STATE_BOOT_ID PERF_KPI_STATE_UPTIME \
           PERF_KPI_STATE_PENDING PERF_KPI_STATE_ITER_DONE
}

perf_kpi_reboot_state_save() {
    state_file=$1
    boot_id=$2
    uptime=$3
    pending=$4
    iter_done=$5

    {
        echo "boot_id=$boot_id"
        echo "uptime_sec=$uptime"
        echo "pending_reboot=$pending"
        echo "iterations_done=$iter_done"
    } >"$state_file" 2>/dev/null || true
}

perf_kpi_request_reboot() {
    msg=$1

    log_info "Requesting reboot: $msg"

    sync || true

    if command -v systemctl >/dev/null 2>&1; then
        systemctl reboot || reboot || shutdown -r now || :
    else
        reboot || shutdown -r now || :
    fi

    sleep 5
    if command -v systemctl >/dev/null 2>&1; then
        systemctl reboot || reboot || shutdown -r now || :
    else
        reboot || shutdown -r now || :
    fi
}

perf_kpi_check_previous_reboot() {
    state_file=$1

    perf_kpi_reboot_state_load "$state_file"
    perf_kpi_get_boot_identity

    if [ "$PERF_KPI_STATE_PENDING" != "1" ] || [ -z "$PERF_KPI_STATE_BOOT_ID" ]; then
        return 0
    fi

    if [ "$PERF_KPI_STATE_BOOT_ID" = "$PERF_KPI_BOOT_ID" ]; then
        log_warn "Previous reboot request did NOT change boot-id; re-issuing reboot now."
        log_warn "Previous boot_id=$PERF_KPI_STATE_BOOT_ID uptime=${PERF_KPI_STATE_UPTIME:-unknown}s; current uptime=${PERF_KPI_UPTIME_SEC:-unknown}s"
        perf_kpi_request_reboot "Retrying failed reboot for KPI loop"
        return 0
    fi

    log_info "Detected new boot after KPI reboot: old_boot_id=$PERF_KPI_STATE_BOOT_ID, new_boot_id=$PERF_KPI_BOOT_ID"
    log_info "Previous uptime at reboot request=${PERF_KPI_STATE_UPTIME:-unknown}s, current uptime=${PERF_KPI_UPTIME_SEC:-unknown}s"

    perf_kpi_reboot_state_save "$state_file" "$PERF_KPI_BOOT_ID" "$PERF_KPI_UPTIME_SEC" "0" "$PERF_KPI_STATE_ITER_DONE"
}
