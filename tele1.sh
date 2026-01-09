#!/bin/bash

################################################################################
# TELE1 - Main Orchestration Script
# Tobias Stål 2025
################################################################################

set -eo pipefail

################################################################################
# GLOBAL CONFIGURATION
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
JS_DIR="${SCRIPT_DIR}/js"
CONFIG_DIR="${SCRIPT_DIR}/config"
STATE_DIR="${SCRIPT_DIR}/state"

DATA_DIR="/home/tele/tele/data/pegasus"
LOG_DIR="/home/tele/tele/log"

# RCLONE CONFIGURATION
RCLONE_REMOTE="tele1_dropbox"
RCLONE_LOG_PATH="${LOG_DIR}/rclone_errors.log"

PEGASUS_BIN="/opt/PegasusHarvester/pegasus-harvester"

SCRIPT_START_TIME=$(date "+%Y-%m-%dT%H-%M-%S")
LOG_FILE="${LOG_DIR}/tele1_${SCRIPT_START_TIME}.log"



mkdir -p "$STATE_DIR"

STATE_FILE="${STATE_DIR}/.last_run_state"
export STATE_DIR
export STATE_FILE

EXIT_SUCCESS=0
EXIT_CONFIG_FAILED=1
EXIT_HARDWARE_FAILED=2
EXIT_HARVEST_FAILED=3
EXIT_UPLOAD_FAILED=4
EXIT_INTERRUPTED=130

################################################################################
# LOAD CREDENTIALS
################################################################################

CREDENTIALS_FILE="${SCRIPT_DIR}/credentials.txt"

if [[ -f "$CREDENTIALS_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CREDENTIALS_FILE"
else
    echo "FATAL: Credentials file not found: $CREDENTIALS_FILE" >&2
    exit 1
fi

################################################################################
# SOURCE LIBRARY FILES
################################################################################

REQUIRED_LIBS=(
    "common.sh"
    "hardware.sh"
    "config.sh"
    "harvest.sh"
    "upload.sh"
    "notification.sh"
    "camera.sh"
    "remote.sh"
)

for lib in "${REQUIRED_LIBS[@]}"; do
    lib_path="${LIB_DIR}/${lib}"
    if [[ ! -f "$lib_path" ]]; then
        echo "FATAL: Required library file missing: $lib_path" >&2
        exit 1
    fi
done

source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/hardware.sh"
source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/harvest.sh"
source "${LIB_DIR}/upload.sh"
source "${LIB_DIR}/notification.sh"
source "${LIB_DIR}/camera.sh"
source "${LIB_DIR}/remote.sh"

################################################################################
# INITIALISATION
################################################################################

mkdir -p "$DATA_DIR" "$LOG_DIR" "$CONFIG_DIR"

init_log_file "$LOG_FILE"

# trap 'cleanup_on_exit' INT TERM EXIT

log_info "=================================================="
log_info "TELE1 Data Collection System - Starting"
log_info "=================================================="
log_info "Start time: $SCRIPT_START_TIME"
log_info "Log file: $LOG_FILE"
log_info "Rclone remote: $RCLONE_REMOTE"
log_info ""

################################################################################
# STAGE 1: System Preparation
################################################################################

log_info "STAGE 1: System Preparation"
log_info "----------------------------"

check_dependencies || {
    log_error "Required dependencies missing"
    send_failure_notification "DEPENDENCY_CHECK_FAILED"
    exit $EXIT_HARDWARE_FAILED
}

get_system_info

log_info "Checking hardware connectivity..."

if ! check_hardware_presence; then
    log_error "Critical hardware missing - cannot proceed"
    send_failure_notification "HARDWARE_NOT_FOUND"
    exit $EXIT_HARDWARE_FAILED
fi

log_info "System preparation completed successfully"
log_info ""

cleanup_on_exit() {
    local exit_code=$?
    log_info "Cleanup on exit (code: $exit_code)"
    cleanup_temp_files || log_warn "Cleanup failed"

    # Show poweroff prompt for all modes
    echo
    echo "System will power down in 10 seconds."
    echo -n "Confirm power down? (Y/N, default Y in 10s): "

    local answer=""
    if read -r -n1 -t 10 answer; then
        echo  # newline after keypress
        if [[ "$answer" == "Y" || "$answer" == "y" ]]; then
            log_info "Poweroff confirmed by user"
            sudo /sbin/poweroff || log_error "Poweroff failed"
        else
            log_info "Poweroff cancelled by user (answer='$answer')"
        fi
    else
        echo  # newline after timeout
        log_info "No response within 10 seconds, proceeding with poweroff"
        sudo /sbin/poweroff || log_error "Poweroff failed"
    fi
}

trap 'cleanup_on_exit' EXIT






################################################################################
# STAGE 2: Configuration Loading
################################################################################

log_info "STAGE 2: Configuration Loading"
log_info "-------------------------------"

download_config || {
    log_warn "Config download failed, attempting to use local defaults"
    load_default_config
}

parse_and_validate_config || {
    log_warn "Configuration validation had issues, using defaults instead of aborting"
    load_default_config
}

apply_config

display_config

if [[ "${EXECUTE}" == "vnc" ]]; then
    log_info "VNC mode enabled - waiting for remote connection"
    handle_vnc_mode "$WAIT_TIME"
    log_info "VNC mode completed - continuing with normal execution"
fi

log_info "Configuration loaded successfully"
log_info ""

################################################################################
# STAGE 3: Network Initialisation
################################################################################

log_info "STAGE 3: Network Initialisation"
log_info "--------------------------------"

check_network_available || {
    log_warn "Network not available - uploads may fail"
}

log_info "Network initialisation completed"
log_info ""

################################################################################
# STAGE 4: Data Collection
################################################################################

log_info "STAGE 4: Data Collection"
log_info "-------------------------"

collect_starlink_diagnostics || log_warn "Starlink diagnostics collection failed"

log_info "Starting Pegasus Harvester automation..."
HARVEST_SUCCESS=0
HARVEST_ATTEMPTS=0

if run_harvest_with_retry; then
    HARVEST_SUCCESS=1
    log_info "SUCCESS: Data harvest successful"
    save_state "HARVEST_COMPLETED" "1" || log_warn "save_state HARVEST_COMPLETED=1 failed"
    save_state "HARVEST_TIMESTAMP" "$SCRIPT_START_TIME" || log_warn "save_state HARVEST_TIMESTAMP failed"
else
    log_error "FAILED: Data harvest failed after all retry attempts"
    save_state "HARVEST_COMPLETED" "0" || log_warn "save_state HARVEST_COMPLETED=0 failed"
fi

log_info "Data collection stage completed"
log_info ""


################################################################################
# STAGE 5: Data Upload (RCLONE-BASED)
################################################################################

log_info "STAGE 5: Data Upload"
log_info "--------------------"

DATA_UPLOAD_SUCCESS=0

if [[ $HARVEST_SUCCESS -eq 1 ]]; then
    log_info "Compressing harvest data and run log..."
    if compress_harvest_data; then
        log_info "Uploading compressed archive..."
        if upload_harvest_data; then
            DATA_UPLOAD_SUCCESS=1
            log_info "SUCCESS: Harvest archive uploaded"
            save_state "DATA_UPLOADED" "1" 2>/dev/null || log_warn "save_state DATA_UPLOADED=1 failed"
        else
            log_error "FAILED: Harvest archive upload failed"
            save_state "DATA_UPLOADED" "0" 2>/dev/null || log_warn "save_state DATA_UPLOADED=0 failed"
        fi
    else
        log_error "FAILED: Data/log compression failed"
        save_state "DATA_UPLOADED" "0" 2>/dev/null || log_warn "save_state DATA_UPLOADED=0 failed"
    fi
else
    log_info "Skipping data upload (no harvest data)"
    save_state "DATA_UPLOADED" "0" 2>/dev/null || log_warn "save_state DATA_UPLOADED=0 failed"
fi

log_info "Upload stage completed"
log_info ""


################################################################################
# STAGE 5.5: Refresh EXECUTE for final cleanup (only if initial config failed)
################################################################################

# Only try a late config refresh if Stage 2 could not download config
if [[ "${CONFIG_DOWNLOAD_SUCCESS:-0}" -eq 0 ]]; then
    log_info "POST-UPLOAD: Initial config download failed; attempting late refresh for EXECUTE/WAIT_TIME_SSH"

    if download_config; then
        log_info "Post-upload config download succeeded - reloading EXECUTE/WAIT_TIME_SSH for cleanup"

        while IFS='=' read -r key value; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)

            case "${key^^}" in
                EXECUTE)
                    if [[ "$value" =~ ^(auto|ssh|vnc|clear)$ ]]; then
                        EXECUTE="$value"
                        log_info "POST-UPLOAD: EXECUTE overridden to: $EXECUTE"
                    else
                        log_warn "POST-UPLOAD: Ignoring invalid EXECUTE value in config: $value"
                    fi
                    ;;
                WAIT_TIME_SSH)
                    if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                        WAIT_TIME_SSH="$value"
                        log_info "POST-UPLOAD: WAIT_TIME_SSH overridden to: $WAIT_TIME_SSH hour(s)"
                    else
                        log_warn "POST-UPLOAD: Invalid WAIT_TIME_SSH value in config: $value"
                    fi
                    ;;
                *)
                    :
                    ;;
            esac
        done < "${CONFIG_DIR}/config.txt"
    else
        log_warn "POST-UPLOAD: Late config refresh failed – keeping existing EXECUTE=$EXECUTE"
    fi
else
    log_info "POST-UPLOAD: Skipping late config refresh (initial CONFIG_DOWNLOAD_SUCCESS=1)"
fi

log_info ""



################################################################################
# STAGE 6: Notification
################################################################################

log_info "STAGE 6: Sending Notification"
log_info "------------------------------"

log_info "I am feeling very lonely and lost. It's OK, I guess... Doing my best but I miss stable power and some maintenance. Bye for now. Yours tele1."
log_info "Please RTA! tele1."

if [[ $HARVEST_SUCCESS -eq 1 ]] && [[ $DATA_UPLOAD_SUCCESS -eq 1 ]]; then
    OVERALL_STATUS="COMPLETE_SUCCESS"
elif [[ $HARVEST_SUCCESS -eq 1 ]]; then
    OVERALL_STATUS="HARVEST_SUCCESS_UPLOAD_FAILED"
else
    OVERALL_STATUS="HARVEST_FAILED"
fi


# Compute SSH shutdown deadline in UTC if EXECUTE=ssh
SSH_DEADLINE_UTC=""
SSH_TAILSCALE_HINT=""

if [[ "${EXECUTE}" == "ssh" ]]; then
    # WAIT_TIME_SSH is in hours; convert to seconds (integer)
    wait_seconds=$(awk "BEGIN { printf \"%d\", ${WAIT_TIME_SSH:-0} * 3600 }")
    SSH_DEADLINE_UTC=$(date -u -d "+${wait_seconds} seconds" "+%Y-%m-%dT%H:%M:%SZ")
    SSH_TAILSCALE_HINT="You can connect over Tailscale SSH (e.g. ssh tele@<tailscale-ip>) until ${SSH_DEADLINE_UTC} (UTC)."
    export SSH_DEADLINE_UTC SSH_TAILSCALE_HINT
fi

send_status_notification "$OVERALL_STATUS" "$LOG_FILE" || {
    log_error "Failed to send email notification"
}

log_info "Notification sent"
log_info ""


################################################################################
# STAGE 7: Cleanup and Shutdown
################################################################################

log_info "STAGE 7: Cleanup and Shutdown"
log_info "------------------------------"

# Determine SSH wait time based on EXECUTE mode
ssh_wait_time=0

case "${EXECUTE:-auto}" in
    "auto")
        log_info "Cleanup mode: auto (harvest, compress, upload, notify, skip wait, power down)"
        cleanup_temp_files
        ssh_wait_time=0
        ;;
    "clear")
        log_info "Cleanup mode: clear (as auto, plus delete all data and logs)"
        cleanup_temp_files
        delete_all_data_and_logs
        ssh_wait_time=0
        ;;
    "ssh")
        log_info "Cleanup mode: ssh (harvest, compress, upload, notify, wait for SSH, power down)"
        cleanup_temp_files
        ssh_wait_time="${WAIT_TIME_SSH:-0}"
        ;;
    "vnc")
        log_info "Cleanup mode: vnc (harvest, compress, upload, notify, wait for SSH/VNC, power down)"
        cleanup_temp_files
        ssh_wait_time="${WAIT_TIME_SSH:-0}"
        ;;
    *)
        log_warn "Unknown EXECUTE mode: ${EXECUTE:-auto}, defaulting to auto"
        cleanup_temp_files
        ssh_wait_time=0
        ;;
esac

# Apply SSH/VNC wait if configured
if [[ $ssh_wait_time -gt 0 ]]; then
    wait_for_ssh_connection "$ssh_wait_time"
fi

log_info "TELE1 execution completed"

exit $EXIT_SUCCESS
