#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Validate weston-simple-shm through an existing Weston runtime.
# SHM validation does not require EGL, GLES, or GPU-renderer gating.

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
    echo "[ERROR] Could not find init_env, starting at $SCRIPT_DIR" >&2
    exit 1
fi

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1090,SC1091
. "$TOOLS/lib_display.sh"

if [ -r "$TOOLS/lib_pkg_provider.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$TOOLS/lib_pkg_provider.sh"
fi

if [ -r "$TOOLS/lib_module_reload.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$TOOLS/lib_module_reload.sh"
fi

TESTNAME="weston-simple-shm"
DURATION="${DURATION:-15s}"
WAIT_SECS="${WAIT_SECS:-10}"
ALLOW_RELAUNCH="${ALLOW_RELAUNCH:-0}"
REQUESTED_GRAPHICS_MODE="default"
GPU_MODULE="${GPU_MODULE:-msm_kgsl}"
GPU_OVERLAY_DEVICE="${GPU_OVERLAY_DEVICE:-/dev/kgsl-3d0}"
GPU_OVERLAY_GBM_PACKAGE="${GPU_OVERLAY_GBM_PACKAGE:-libgbm-msm1}"
CLIENT_PID=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --base|--no-overlay)
            REQUESTED_GRAPHICS_MODE="base"
            ;;
        --overlay|--qcom-overlay|--enable-overlay)
            REQUESTED_GRAPHICS_MODE="overlay"
            ;;
        --auto)
            REQUESTED_GRAPHICS_MODE="auto"
            ;;
        --allow-relaunch)
            ALLOW_RELAUNCH=1
            ;;
        --no-allow-relaunch)
            ALLOW_RELAUNCH=0
            ;;
        --duration=*)
            DURATION=${1#*=}
            ;;
        --wait-secs=*)
            WAIT_SECS=${1#*=}
            ;;
        -h|--help)
            cat <<EOF_USAGE
Usage: $0 [--base|--overlay|--auto]
          [--allow-relaunch|--no-allow-relaunch]
          [--duration=SECONDSs] [--wait-secs=SECONDS]
EOF_USAGE
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown option: $1" >&2
            exit 1
            ;;
    esac
    shift
done

case "$WAIT_SECS" in
    ''|*[!0-9]*)
        echo "[ERROR] WAIT_SECS must be a positive integer: $WAIT_SECS" >&2
        exit 1
        ;;
esac

case "$ALLOW_RELAUNCH" in
    0|1) ;;
    *)
        echo "[ERROR] ALLOW_RELAUNCH must be 0 or 1" >&2
        exit 1
        ;;
esac

test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || true)"
if [ -z "$test_path" ] || [ ! -d "$test_path" ]; then
    log_fail "$TESTNAME FAIL - test directory not found"
    echo "$TESTNAME FAIL" >"./${TESTNAME}.res"
    exit 1
fi
cd "$test_path" || exit 1

RES_FILE="./${TESTNAME}.res"
RUN_LOG="./${TESTNAME}_run.log"
: >"$RES_FILE"
: >"$RUN_LOG"

cleanup_client() {
    if [ -n "${CLIENT_PID:-}" ] && kill -0 "$CLIENT_PID" 2>/dev/null; then
        kill -TERM "$CLIENT_PID" 2>/dev/null || true
        sleep 1
        if kill -0 "$CLIENT_PID" 2>/dev/null; then
            kill -KILL "$CLIENT_PID" 2>/dev/null || true
        fi
        wait "$CLIENT_PID" 2>/dev/null || true
    fi
    CLIENT_PID=""
}

trap 'cleanup_client' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

OS_ID="unknown"
if command -v pkg_detect_os_id >/dev/null 2>&1; then
    OS_ID="$(pkg_detect_os_id 2>/dev/null || true)"
elif [ -r /etc/os-release ]; then
    OS_ID="$(
        sed -n 's/^ID=//p' /etc/os-release |
            head -n 1 |
            tr -d '"' |
            tr '[:upper:]' '[:lower:]'
    )"
fi
[ -n "$OS_ID" ] || OS_ID="unknown"

DISTRO_GPU_HANDLING_SUPPORTED=0
case "$OS_ID" in
    debian|ubuntu|centos|rhel|fedora)
        DISTRO_GPU_HANDLING_SUPPORTED=1
        [ "$REQUESTED_GRAPHICS_MODE" = "default" ] && REQUESTED_GRAPHICS_MODE="base"
        ;;
    *)
        [ "$REQUESTED_GRAPHICS_MODE" = "default" ] && REQUESTED_GRAPHICS_MODE="auto"
        ;;
esac

log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase --------------------------"
log_info "Detected OS, $OS_ID"
log_info "Config, REQUESTED_GRAPHICS_MODE=$REQUESTED_GRAPHICS_MODE DURATION=$DURATION WAIT_SECS=$WAIT_SECS ALLOW_RELAUNCH=$ALLOW_RELAUNCH"

for required_helper in \
    display_ensure_weston_test_dependencies \
    display_detect_build_flavour \
    display_log_snapshot_and_require_connector; do
    if ! command -v "$required_helper" >/dev/null 2>&1; then
        log_fail "$TESTNAME FAIL - required helper is unavailable: $required_helper"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
    fi
done

if ! display_ensure_weston_test_dependencies "$TESTNAME"; then
    log_skip "$TESTNAME SKIP - Weston SHM client dependencies are unavailable"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

if [ "$DISTRO_GPU_HANDLING_SUPPORTED" -eq 1 ]; then
    if ! command -v display_prepare_desktop_graphics_stack >/dev/null 2>&1; then
        log_fail "$TESTNAME FAIL - display_prepare_desktop_graphics_stack helper is unavailable"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
    fi

    display_prepare_desktop_graphics_stack \
        "$TESTNAME" \
        "$REQUESTED_GRAPHICS_MODE" \
        "$GPU_MODULE" \
        "$GPU_OVERLAY_DEVICE" \
        "$GPU_OVERLAY_GBM_PACKAGE"
    stack_rc=$?

    case "$stack_rc" in
        0) ;;
        2)
            echo "$TESTNAME SKIP" >"$RES_FILE"
            exit 0
            ;;
        *)
            echo "$TESTNAME FAIL" >"$RES_FILE"
            exit 0
            ;;
    esac
else
    log_info "Graphics package-stack and GPU boot-mode handling skipped for os=$OS_ID"
fi

display_detect_build_flavour

if ! display_log_snapshot_and_require_connector "$TESTNAME" 200; then
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

case "$OS_ID" in
    debian|ubuntu|centos|rhel|fedora)
        if ! command -v weston_prepare_runtime >/dev/null 2>&1; then
            log_fail "$TESTNAME FAIL - weston_prepare_runtime helper is unavailable"
            echo "$TESTNAME FAIL" >"$RES_FILE"
            exit 0
        fi

        if ! weston_prepare_runtime \
            "$TESTNAME" \
            "$WAIT_SECS" \
            client \
            "$ALLOW_RELAUNCH"; then
            log_fail "$TESTNAME FAIL - no usable managed Weston runtime is available for SHM clients"
            echo "$TESTNAME FAIL" >"$RES_FILE"
            exit 0
        fi
        ;;
    *)
        if ! display_prepare_image_weston_runtime \
            "$TESTNAME" \
            "$WAIT_SECS" \
            "$DISPLAY_BUILD_FLAVOUR"; then
            echo "$TESTNAME FAIL" >"$RES_FILE"
            exit 0
        fi
        ;;
esac

BIN="$(command -v "$TESTNAME" 2>/dev/null || true)"
if [ -z "$BIN" ]; then
    log_skip "$TESTNAME SKIP - required binary is unavailable"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

log_info "Using client binary, $BIN"
log_info "Wayland socket, ${DISPLAY_WAYLAND_SOCKET:-<unknown>}"
log_info "Launching $TESTNAME for $DURATION"

start_ts="$(date +%s)"
if command -v run_with_timeout >/dev/null 2>&1; then
    if command -v stdbuf >/dev/null 2>&1; then
        run_with_timeout "$DURATION" stdbuf -oL -eL "$BIN" >>"$RUN_LOG" 2>&1
    else
        run_with_timeout "$DURATION" "$BIN" >>"$RUN_LOG" 2>&1
    fi
    rc=$?
else
    duration_secs="$(printf '%s\n' "$DURATION" | sed -n 's/^\([0-9][0-9]*\)s$/\1/p')"
    [ -n "$duration_secs" ] || duration_secs=15
    "$BIN" >>"$RUN_LOG" 2>&1 &
    CLIENT_PID=$!
    sleep "$duration_secs"
    if kill -0 "$CLIENT_PID" 2>/dev/null; then
        kill -TERM "$CLIENT_PID" 2>/dev/null || true
        wait "$CLIENT_PID" 2>/dev/null || true
        rc=143
    else
        wait "$CLIENT_PID"
        rc=$?
    fi
    CLIENT_PID=""
fi
end_ts="$(date +%s)"
elapsed=$((end_ts - start_ts))

final="PASS"
case "$rc" in
    0|124|143) ;;
    *)
        log_fail "$TESTNAME execution failed, rc=$rc"
        final="FAIL"
        ;;
esac

if [ "$elapsed" -le 1 ]; then
    log_fail "$TESTNAME exited too quickly, elapsed=${elapsed}s"
    final="FAIL"
fi

if command -v wayland_connection_ok >/dev/null 2>&1 && ! wayland_connection_ok; then
    log_fail "$TESTNAME runtime became unusable after client execution"
    final="FAIL"
fi

if [ "$final" = "FAIL" ]; then
    log_info "----- Last 200 client log lines -----"
    tail -n 200 "$RUN_LOG" 2>/dev/null |
        while IFS= read -r line; do
            log_info "[client] $line"
        done
    log_info "----- End client log -----"
fi

{
    printf 'requested_graphics_mode=%s\n' "$REQUESTED_GRAPHICS_MODE"
    printf 'detected_graphics_mode=%s\n' "${DISPLAY_BUILD_FLAVOUR:-unknown}"
    printf 'os_id=%s\n' "$OS_ID"
    printf 'runtime_model=%s\n' "${DISPLAY_RUNTIME_MODEL:-unknown}"
    printf 'wayland_socket=%s\n' "${DISPLAY_WAYLAND_SOCKET:-unknown}"
    printf 'client_rc=%s\n' "$rc"
    printf 'elapsed_seconds=%s\n' "$elapsed"
    printf 'result=%s\n' "$final"
} >>"$RUN_LOG"

echo "$TESTNAME $final" >"$RES_FILE"

# Call cleanup directly so static analyzers can see that the trap handler is
# reachable. Clearing the traps avoids a second cleanup call during exit.
trap - EXIT HUP INT TERM
cleanup_client

if [ "$final" = "PASS" ]; then
    log_pass "$TESTNAME : PASS"
else
    log_fail "$TESTNAME : FAIL"
fi
exit 0
