#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Validate Weston and Wayland runtime health before Weston client tests.
# This runner never creates users, services, TTY sessions, udev rules, seatd
# instances, or standalone Weston processes.

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

TESTNAME="Weston_Runtime_Preflight"
WAIT_SECS="${WAIT_SECS:-10}"
VALIDATE_EGLINFO="${VALIDATE_EGLINFO:-1}"
ALLOW_RELAUNCH="${ALLOW_RELAUNCH:-0}"
REQUESTED_GRAPHICS_MODE="default"
GPU_MODULE="${GPU_MODULE:-msm_kgsl}"
GPU_OVERLAY_DEVICE="${GPU_OVERLAY_DEVICE:-/dev/kgsl-3d0}"
GPU_OVERLAY_GBM_PACKAGE="${GPU_OVERLAY_GBM_PACKAGE:-libgbm-msm1}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --base|--no-overlay) REQUESTED_GRAPHICS_MODE="base" ;;
        --overlay|--qcom-overlay|--enable-overlay) REQUESTED_GRAPHICS_MODE="overlay" ;;
        --auto) REQUESTED_GRAPHICS_MODE="auto" ;;
        --wait-secs=*) WAIT_SECS=${1#*=} ;;
        --validate-eglinfo) VALIDATE_EGLINFO=1 ;;
        --no-validate-eglinfo) VALIDATE_EGLINFO=0 ;;
        --allow-relaunch) ALLOW_RELAUNCH=1 ;;
        --no-allow-relaunch) ALLOW_RELAUNCH=0 ;;
        -h|--help)
            cat <<EOF_USAGE
Usage: $0 [--base|--overlay|--auto]
          [--wait-secs=N] [--validate-eglinfo|--no-validate-eglinfo]
          [--allow-relaunch|--no-allow-relaunch]
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

case "$VALIDATE_EGLINFO:$ALLOW_RELAUNCH" in
    0:0|0:1|1:0|1:1) ;;
    *)
        echo "[ERROR] VALIDATE_EGLINFO and ALLOW_RELAUNCH must be 0 or 1" >&2
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

log_info "Weston log directory, $SCRIPT_DIR"
log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase --------------------------"
log_info "Detected OS, $OS_ID"
log_info "Config, REQUESTED_GRAPHICS_MODE=$REQUESTED_GRAPHICS_MODE WAIT_SECS=$WAIT_SECS VALIDATE_EGLINFO=$VALIDATE_EGLINFO ALLOW_RELAUNCH=$ALLOW_RELAUNCH"

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

if ! display_ensure_weston_test_dependencies weston-simple-shm; then
    log_skip "$TESTNAME SKIP - minimal Weston runtime dependencies are unavailable"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

if [ "$DISTRO_GPU_HANDLING_SUPPORTED" -eq 1 ]; then
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
        if ! command -v display_prepare_desktop_weston_runtime >/dev/null 2>&1; then
            log_fail "$TESTNAME FAIL - desktop Weston runtime helper is unavailable"
            echo "$TESTNAME FAIL" >"$RES_FILE"
            exit 0
        fi

        if ! display_prepare_desktop_weston_runtime \
            "$TESTNAME" \
            "$WAIT_SECS"; then
            log_fail "$TESTNAME FAIL - no usable desktop Weston runtime is available"
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

if [ "$VALIDATE_EGLINFO" -ne 0 ] &&
   command -v eglinfo >/dev/null 2>&1 &&
   command -v display_print_eglinfo_pipeline >/dev/null 2>&1; then
    log_info "Collecting EGL pipeline diagnostics"
    display_print_eglinfo_pipeline auto ||
        log_warn "EGL pipeline diagnostics did not complete cleanly"
fi

if command -v display_select_primary_connector >/dev/null 2>&1; then
    primary_connector="$(display_select_primary_connector 2>/dev/null || true)"
    [ -n "$primary_connector" ] && log_info "Primary connector, $primary_connector"
fi

log_info "Final decision for $TESTNAME, PASS"
echo "$TESTNAME PASS" >"$RES_FILE"
log_pass "$TESTNAME : PASS"
exit 0
