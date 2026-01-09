#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
#
# Validate weston-simple-egl runs under a working Wayland session.
# - Wayland env resolution (adopts socket & fixes XDG_RUNTIME_DIR perms)
# - CI-friendly logs and PASS/FAIL/SKIP semantics (0/1/2)
# - Optional FPS parsing (best-effort)

# ---------- Source init_env and functestlib ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_display.sh"

TESTNAME="weston-simple-egl"
RES_FILE="./${TESTNAME}.res"
RUN_LOG="./${TESTNAME}_run.log"

: >"$RES_FILE"
: >"$RUN_LOG"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
DURATION="${DURATION:-30s}"
STOP_GRACE="${STOP_GRACE:-3s}"
EXPECT_FPS="${EXPECT_FPS:-60}"
FPS_TOL_PCT="${FPS_TOL_PCT:-10}"
REQUIRE_FPS="${REQUIRE_FPS:-1}"

BUILD_FLAVOUR="base"
if [ -f /usr/share/glvnd/egl_vendor.d/EGL_adreno.json ]; then
    BUILD_FLAVOUR="overlay"
fi

log_info "Weston log directory: $SCRIPT_DIR"
log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting ${TESTNAME} Testcase --------------------------"

# Optional platform details (helper from functestlib)
if command -v detect_platform >/dev/null 2>&1; then
    detect_platform
fi

if [ "$BUILD_FLAVOUR" = "overlay" ]; then
    log_info "Build flavor: overlay (EGL_adreno.json present)"
else
    log_info "Build flavor: base (no EGL_adreno.json overlay)"
fi

log_info "Config: DURATION=${DURATION} STOP_GRACE=${STOP_GRACE} EXPECT_FPS=${EXPECT_FPS}+/-${FPS_TOL_PCT}% REQUIRE_FPS=${REQUIRE_FPS} BUILD_FLAVOUR=${BUILD_FLAVOUR}"

# ---------------------------------------------------------------------------
# Display snapshot
# ---------------------------------------------------------------------------
if command -v display_debug_snapshot >/dev/null 2>&1; then
    display_debug_snapshot "pre-display-check"
fi
 
# Always print modetest as part of the snapshot (best-effort).
# (Some lib_display.sh variants override display_debug_snapshot without modetest.)
if command -v modetest >/dev/null 2>&1; then
    log_info "----- modetest -M msm -ac (capped at 200 lines) -----"
    modetest -M msm -ac 2>&1 | sed -n '1,200p' | while IFS= read -r l; do
        [ -n "$l" ] && log_info "[modetest] $l"
    done
    log_info "----- End modetest -M msm -ac -----"
else
    log_warn "modetest not found in PATH skipping modetest snapshot."
fi
 
have_connector=0
if command -v display_connected_summary >/dev/null 2>&1; then
    sysfs_summary=$(display_connected_summary)
    if [ -n "$sysfs_summary" ] && [ "$sysfs_summary" != "none" ]; then
        have_connector=1
        log_info "Connected display (sysfs): $sysfs_summary"
    fi
fi
 
if [ "$have_connector" -eq 0 ]; then
    log_warn "No connected DRM display found, skipping ${TESTNAME}."
    echo "${TESTNAME} SKIP" >"$RES_FILE"
    exit 0
fi
# ---------------------------------------------------------------------------
# Wayland / Weston environment (runtime detection, no hardcoded flavour)
# ---------------------------------------------------------------------------
if command -v wayland_debug_snapshot >/dev/null 2>&1; then
    wayland_debug_snapshot "${TESTNAME}: start"
fi

sock=""

# Try to find any existing Wayland socket (base or overlay)
if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
    sock=$(discover_wayland_socket_anywhere | head -n 1 || true)
fi

# If we found a socket, adopt its environment
if [ -n "$sock" ] && command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
    log_info "Found existing Wayland socket: $sock"
    if ! adopt_wayland_env_from_socket "$sock"; then
        log_warn "Failed to adopt env from $sock"
    fi
fi

# If no usable socket yet, try starting a private Weston (overlay-style helper)
if [ -z "$sock" ] && command -v overlay_start_weston_drm >/dev/null 2>&1; then
    log_info "No usable Wayland socket; trying overlay_start_weston_drm helper..."
    if command -v weston_force_primary_1080p60_if_not_60 >/dev/null 2>&1; then
        log_info "Pre-configuring primary output to ~60Hz before starting Weston (best-effort) ..."
        weston_force_primary_1080p60_if_not_60 || true
    fi
    if overlay_start_weston_drm; then
        # Re-scan for a socket after attempting to start Weston
        if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
            sock=$(discover_wayland_socket_anywhere | head -n 1 || true)
        fi
        if [ -n "$sock" ] && command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
            log_info "Overlay Weston created Wayland socket: $sock"
            if ! adopt_wayland_env_from_socket "$sock"; then
                log_warn "Failed to adopt env from $sock"
            fi
        else
            log_warn "overlay_start_weston_drm reported success but no Wayland socket was found."
        fi
    else
        log_warn "overlay_start_weston_drm returned non-zero; private Weston may have failed to start."
    fi
fi

# Final decision: run or SKIP
if [ -z "$sock" ]; then
    log_warn "No Wayland socket found after autodetection; skipping ${TESTNAME}."
    echo "${TESTNAME} SKIP" >"$RES_FILE"
    exit 0
fi

if command -v wayland_connection_ok >/dev/null 2>&1; then
    if ! wayland_connection_ok; then
        log_fail "Wayland connection test failed; cannot run ${TESTNAME}."
        echo "${TESTNAME} SKIP" >"$RES_FILE"
        exit 0
    fi
    log_info "Wayland connection test: OK"
else
    log_warn "wayland_connection_ok helper not found continuing without explicit Wayland probe."
fi

# ---------------------------------------------------------------------------
# Ensure primary output is ~60Hz (best-effort, no churn if already ~60Hz)
# - Must NOT change weston.ini behavior: that remains inside lib_display.sh
# - First checks current mode (modetest path) or config (weston.ini path)
# - Only attempts changes when NOT ~60Hz
# ---------------------------------------------------------------------------
if command -v display_debug_snapshot >/dev/null 2>&1; then
    display_debug_snapshot "${TESTNAME}: before-ensure-60hz"
fi
if command -v wayland_debug_snapshot >/dev/null 2>&1; then
    wayland_debug_snapshot "${TESTNAME}: before-ensure-60hz"
fi

if command -v weston_force_primary_1080p60_if_not_60 >/dev/null 2>&1; then
    log_info "Ensuring primary output is ~60Hz (best-effort) ..."
    if weston_force_primary_1080p60_if_not_60; then
        log_info "Primary output is ~60Hz (or was already ~60Hz)."
    else
        log_warn "Unable to force ~60Hz (continuing; not a hard failure)."
    fi
else
    log_warn "weston_force_primary_1080p60_if_not_60 helper not found; skipping ~60Hz enforcement."
fi

if command -v display_debug_snapshot >/dev/null 2>&1; then
    display_debug_snapshot "${TESTNAME}: after-ensure-60hz"
fi

# --- Skip if only CPU/software renderer is active (GPU HW accel not enabled) ---
if command -v display_is_cpu_renderer >/dev/null 2>&1; then
    if display_is_cpu_renderer auto; then
        log_skip "$TESTNAME SKIP: GPU HW acceleration not enabled (CPU/software renderer detected)"
        echo "${TESTNAME} SKIP" >"$RES_FILE"
        exit 0
    fi
else
    log_warn "display_is_cpu_renderer helper not found and cannot enforce GPU accel gating (continuing)."
fi

# ---------------------------------------------------------------------------
# Binary & EGL vendor override
# ---------------------------------------------------------------------------
if ! check_dependencies weston-simple-egl; then
    log_fail "Required binary weston-simple-egl not found in PATH."
    echo "${TESTNAME} FAIL" >"$RES_FILE"
    exit 0
fi

BIN=$(command -v weston-simple-egl)
log_info "Using weston-simple-egl: $BIN"

if [ "$BUILD_FLAVOUR" = "overlay" ] && [ -f /usr/share/glvnd/egl_vendor.d/EGL_adreno.json ]; then
    export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/EGL_adreno.json
    log_info "EGL vendor override: /usr/share/glvnd/egl_vendor.d/EGL_adreno.json"
fi

# Enable FPS prints in the client
export SIMPLE_EGL_FPS=1
export WESTON_SIMPLE_EGL_FPS=1

# ---------------------------------------------------------------------------
# Run client with timeout
# ---------------------------------------------------------------------------
log_info "Launching ${TESTNAME} for ${DURATION} ..."

start_ts=$(date +%s)

if command -v run_with_timeout >/dev/null 2>&1; then
    log_info "Using helper: run_with_timeout"
    if command -v stdbuf >/dev/null 2>&1; then
        run_with_timeout "$DURATION" stdbuf -oL -eL "$BIN" >>"$RUN_LOG" 2>&1
    else
        log_warn "stdbuf not found running $BIN without output re-buffering."
        run_with_timeout "$DURATION" "$BIN" >>"$RUN_LOG" 2>&1
    fi
    rc=$?
else
    log_warn "run_with_timeout not found using naive sleep+kill fallback."
    "$BIN" >>"$RUN_LOG" 2>&1 &
    cpid=$!
    dur_s=$(printf '%s\n' "$DURATION" | sed -n 's/^\([0-9][0-9]*\)s$/\1/p')
    [ -n "$dur_s" ] || dur_s=30
    sleep "$dur_s"
    kill "$cpid" 2>/dev/null || true
    rc=143
fi

end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))

log_info "Client finished: rc=${rc} elapsed=${elapsed}s"

# ---------------------------------------------------------------------------
# FPS parsing: average / min / max from all intervals
# - Discard FIRST sample as warm-up if we have 2+ samples.
# ---------------------------------------------------------------------------
fps_count=0
fps_avg="-"
fps_min="-"
fps_max="-"

fps_stats=$(
    awk '
    /[0-9]+[[:space:]]+frames in[[:space:]]+[0-9]+[[:space:]]+seconds/ {
        # Example: "151 frames in 5 seconds: 30.200001 fps"
        val = $(NF-1) + 0.0
        all_n++
        all_vals[all_n] = val
    }
    END {
        if (all_n == 0) {
            # No samples
            exit
        }

        if (all_n == 1) {
            # Only one sample: use it as-is
            n = 1
            sum = all_vals[1]
            min = all_vals[1]
            max = all_vals[1]
        } else {
            # Discard first sample as warm-up; average remaining
            n = 0
            sum = 0.0
            for (i = 2; i <= all_n; i++) {
                v = all_vals[i]
                n++
                sum += v
                if (n == 1 || v < min) min = v
                if (n == 1 || v > max) max = v
            }
        }

        if (n > 0) {
            avg = sum / n
            printf "n=%d avg=%f min=%f max=%f\n", n, avg, min, max
        }
    }' "$RUN_LOG" 2>/dev/null || true
)

if [ -n "$fps_stats" ]; then
    fps_count=$(printf '%s\n' "$fps_stats" | awk '{print $1}' | sed 's/^n=//')
    fps_avg=$(printf '%s\n' "$fps_stats" | awk '{print $2}' | sed 's/^avg=//')
    fps_min=$(printf '%s\n' "$fps_stats" | awk '{print $3}' | sed 's/^min=//')
    fps_max=$(printf '%s\n' "$fps_stats" | awk '{print $4}' | sed 's/^max=//')

    log_info "FPS stats from ${RUN_LOG}: samples=${fps_count} avg=${fps_avg} min=${fps_min} max=${fps_max}"
else
    log_warn "No FPS lines detected in ${RUN_LOG} weston-simple-egl may not have emitted FPS stats (or output was truncated)."
fi

fps_for_summary="$fps_avg"
if [ "$fps_count" -eq 0 ]; then
    fps_for_summary="-"
fi

log_info "Result summary: rc=${rc} elapsed=${elapsed}s fps=${fps_for_summary} (expected ~${EXPECT_FPS}+/-${FPS_TOL_PCT}%)"

# ---------------------------------------------------------------------------
# PASS / FAIL decision
# ---------------------------------------------------------------------------
final="PASS"

# Exit code: accept 0 (normal) and 143 (timeout) as non-fatal here
if [ "$rc" -ne 0 ] && [ "$rc" -ne 143 ]; then
    final="FAIL"
fi

# Duration sanity: reject if it bails out immediately
if [ "$elapsed" -le 1 ]; then
    log_fail "Client exited too quickly (elapsed=${elapsed}s) expected ~${DURATION} runtime."
    final="FAIL"
fi

# FPS gating if explicitly required
if [ "$REQUIRE_FPS" -ne 0 ]; then
    if [ "$fps_count" -eq 0 ]; then
        log_fail "FPS gating enabled (REQUIRE_FPS=${REQUIRE_FPS}) but no FPS samples were found treating as FAIL."
        final="FAIL"
    else
        min_ok=$(awk -v f="$EXPECT_FPS" -v tol="$FPS_TOL_PCT" 'BEGIN { printf "%.0f\n", f * (100.0 - tol) / 100.0 }')
        max_ok=$(awk -v f="$EXPECT_FPS" -v tol="$FPS_TOL_PCT" 'BEGIN { printf "%.0f\n", f * (100.0 + tol) / 100.0 }')

        fps_int=$(printf '%s\n' "$fps_avg" | awk 'BEGIN {v=0} {v=$1+0.0} END {printf "%.0f\n", v}')

        if [ "$fps_int" -lt "$min_ok" ] || [ "$fps_int" -gt "$max_ok" ]; then
            log_fail "Average FPS out of range: avg=${fps_avg} (~${fps_int}) not in [${min_ok}, ${max_ok}] (EXPECT_FPS=${EXPECT_FPS}, tol=${FPS_TOL_PCT}%)."
            final="FAIL"
        fi
    fi
else
    if [ "$fps_count" -eq 0 ]; then
        log_warn "REQUIRE_FPS=0 and no FPS samples found skipping FPS gating."
    else
        log_info "REQUIRE_FPS=0 FPS stats recorded but not used for gating."
    fi
fi

log_info "Final decision for ${TESTNAME}: ${final}"

# ---------------------------------------------------------------------------
# Emit result & exit
# ---------------------------------------------------------------------------
echo "${TESTNAME} ${final}" >"$RES_FILE"

if [ "$final" = "PASS" ]; then
    log_pass "${TESTNAME} : PASS"
    exit 0
fi

log_fail "${TESTNAME} : FAIL"
exit 0
