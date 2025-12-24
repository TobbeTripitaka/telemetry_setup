#!/bin/bash

################################################################################
# TELE1 - Main Orchestration Script (updated with credentials loading)
################################################################################

set -euo pipefail

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

DROPBOX_SCRIPT="/home/tele/tele/lib/dropbox_uploader.sh"
PEGASUS_BIN="/opt/PegasusHarvester/pegasus-harvester"

SCRIPT_START_TIME=$(date "+%Y-%m-%d_%H-%M-%S")
LOG_FILE="${LOG_DIR}/tele1_${SCRIPT_START_TIME}.log"
STATE_FILE="${STATE_DIR}/.last_run_state"

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
  echo "FATAL: Email address and password file not found: $CREDENTIALS_FILE" >&2
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

mkdir -p "$DATA_DIR" "$LOG_DIR" "$CONFIG_DIR" "$STATE_DIR"

init_log_file "$LOG_FILE"

trap 'cleanup_on_exit' INT TERM EXIT

log_info "=================================================="
log_info "TELE1 Data Collection System - Starting"
log_info "=================================================="
log_info "Start time: $SCRIPT_START_TIME"
log_info "Log file: $LOG_FILE"
log_info ""

# STAGE 1: System preparation
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

# STAGE 2: Configuration
log_info "STAGE 2: Configuration Loading"
log_info "-------------------------------"

download_config || {
  log_warn "Config download failed, attempting to use local defaults"
  load_default_config
}

parse_and_validate_config || {
  log_error "Configuration validation failed"
  send_failure_notification "CONFIG_INVALID"
  exit $EXIT_CONFIG_FAILED
}

apply_config
display_config

if [[ "$EXECUTE" == "vnc" ]]; then
  log_info "VNC mode enabled - waiting for remote connection"
  handle_vnc_mode "$WAIT_TIME"
  log_info "VNC mode completed - continuing with normal execution"
fi

log_info "Configuration loaded successfully"
log_info ""

# STAGE 3: Network
log_info "STAGE 3: Network Initialisation"
log_info "--------------------------------"

check_network_available || {
  log_warn "Network not available - uploads may fail"
}

log_info "Network initialisation completed"
log_info ""

# STAGE 4: Data Collection
log_info "STAGE 4: Data Collection"
log_info "-------------------------"

collect_starlink_diagnostics || log_warn "Starlink diagnostics collection failed"

log_info "Starting Pegasus Harvester automation..."
HARVEST_SUCCESS=0
HARVEST_ATTEMPTS=0

if run_harvest_with_retry; then
  HARVEST_SUCCESS=1
  log_info "SUCCESS: Data harvested successfully"
  save_state "HARVEST_COMPLETED" "1"
  save_state "HARVEST_TIMESTAMP" "$SCRIPT_START_TIME"
else
  log_error "FAILED: Data harvest failed after all retry attempts"
  save_state "HARVEST_COMPLETED" "0"
fi

log_info "Data collection stage completed"
log_info ""

# STAGE 5: Data Upload
log_info "STAGE 5: Data Upload"
log_info "--------------------"

DATA_UPLOAD_SUCCESS=0
LOG_UPLOAD_SUCCESS=0

if [[ $HARVEST_SUCCESS -eq 1 ]]; then
  log_info "Compressing and uploading harvest data..."
  if upload_harvest_data; then
    DATA_UPLOAD_SUCCESS=1
    log_info "SUCCESS: Harvest data uploaded"
    save_state "DATA_UPLOADED" "1"
  else
    log_error "FAILED: Harvest data upload failed"
    save_state "DATA_UPLOADED" "0"
  fi
else
  log_info "Skipping data upload (no harvest data)"
fi

log_info "Uploading log file..."
if upload_log_file "$LOG_FILE"; then
  LOG_UPLOAD_SUCCESS=1
  log_info "SUCCESS: Log file uploaded"
  save_state "LOG_UPLOADED" "1"
else
  log_error "FAILED: Log file upload failed"
  save_state "LOG_UPLOADED" "0"
fi

log_info "Upload stage completed"
log_info ""

# STAGE 6: Notification
log_info "STAGE 6: Sending Notification"
log_info "------------------------------"

if [[ $HARVEST_SUCCESS -eq 1 ]] && [[ $DATA_UPLOAD_SUCCESS -eq 1 ]] && [[ $LOG_UPLOAD_SUCCESS -eq 1 ]]; then
  OVERALL_STATUS="COMPLETE_SUCCESS"
elif [[ $HARVEST_SUCCESS -eq 1 ]] && [[ $LOG_UPLOAD_SUCCESS -eq 1 ]]; then
  OVERALL_STATUS="PARTIAL_SUCCESS"
elif [[ $HARVEST_SUCCESS -eq 1 ]]; then
  OVERALL_STATUS="HARVEST_SUCCESS_UPLOAD_FAILED"
else
  OVERALL_STATUS="HARVEST_FAILED"
fi

send_status_notification "$OVERALL_STATUS" "$LOG_FILE" || {
  log_error "Failed to send email notification"
}

log_info "Notification sent"
log_info ""

# STAGE 7: Cleanup / Shutdown
log_info "STAGE 7: Cleanup and Shutdown"
log_info "------------------------------"

cleanup_temp_files

log_info "TELE1 execution completed"
exit $EXIT_SUCCESS
