#!/bin/bash

################################################################################
# TELE1 - Main Orchestration Script
# Automated data collection, compression, and upload system
#
# Description: Coordinates all data collection operations including:
#   - Pegasus Harvester data logging
#   - Starlink diagnostics
#   - Future: Timelapse camera, USB relay control, LED status indicators
#
# Architecture: Modular design with separate library files for each function
# Author: Toby
# Version: 2.0
# Last Modified: 2025-11-18
################################################################################

# Strict error handling
set -euo pipefail

################################################################################
# GLOBAL CONFIGURATION
################################################################################

# Base directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
JS_DIR="${SCRIPT_DIR}/js"
CONFIG_DIR="${SCRIPT_DIR}/config"
STATE_DIR="${SCRIPT_DIR}/state"
DATA_DIR="/home/tele/tele/data/pegasus"
LOG_DIR="/home/tele/tele/log/computer"

# External scripts
DROPBOX_SCRIPT="/home/tele/tele/lib/dropbox_uploader.sh"
PEGASUS_BIN="/opt/PegasusHarvester/pegasus-harvester"

# Runtime variables
SCRIPT_START_TIME=$(date "+%Y-%m-%d_%H-%M-%S")
LOG_FILE="${LOG_DIR}/tele1_${SCRIPT_START_TIME}.log"
STATE_FILE="${STATE_DIR}/.last_run_state"

# Exit codes
EXIT_SUCCESS=0
EXIT_CONFIG_FAILED=1
EXIT_HARDWARE_FAILED=2
EXIT_HARVEST_FAILED=3
EXIT_UPLOAD_FAILED=4
EXIT_INTERRUPTED=130

################################################################################
# SOURCE LIBRARY FILES
################################################################################

# Check that all required library files exist
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
        echo "FATAL: Required library file missing: $lib_path"
        exit 1
    fi
done

# Source all library files in correct order
source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/hardware.sh"
source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/harvest.sh"
source "${LIB_DIR}/upload.sh"
source "${LIB_DIR}/notification.sh"
source "${LIB_DIR}/camera.sh"
source "${LIB_DIR}/remote.sh"

################################################################################
# INITIALIZATION
################################################################################

# Create necessary directories
mkdir -p "$DATA_DIR" "$LOG_DIR" "$CONFIG_DIR" "$STATE_DIR"

# Initialize log file
init_log_file "$LOG_FILE"

# Set up signal handling
trap 'cleanup_on_exit' INT TERM EXIT

log_info "=================================================="
log_info "TELE1 Data Collection System - Starting"
log_info "=================================================="
log_info "Script version: 2.0"
log_info "Start time: $SCRIPT_START_TIME"
log_info "Log file: $LOG_FILE"
log_info ""

################################################################################
# STAGE 1: SYSTEM PREPARATION
################################################################################

log_info "STAGE 1: System Preparation"
log_info "----------------------------"

# FUTURE: Set LED to YELLOW (initializing)
# led_set_status "YELLOW_SOLID"

# Check system dependencies
check_dependencies || {
    log_error "Required dependencies missing"
    send_failure_notification "DEPENDENCY_CHECK_FAILED"
    exit $EXIT_HARDWARE_FAILED
}

# Log system information
get_system_info

# Check hardware presence
log_info "Checking hardware connectivity..."
if ! check_hardware_presence; then
    log_error "Critical hardware missing - cannot proceed"
    send_failure_notification "HARDWARE_NOT_FOUND"
    exit $EXIT_HARDWARE_FAILED
fi

log_info "System preparation completed successfully"
log_info ""

################################################################################
# STAGE 2: CONFIGURATION
################################################################################

log_info "STAGE 2: Configuration Loading"
log_info "-------------------------------"

# Download configuration from Dropbox
download_config || {
    log_warn "Config download failed, attempting to use local defaults"
    load_default_config
}

# Parse and validate configuration
parse_and_validate_config || {
    log_error "Configuration validation failed"
    send_failure_notification "CONFIG_INVALID"
    exit $EXIT_CONFIG_FAILED
}

# Apply configuration settings
apply_config


# Display final configuration
display_config

# Handle VNC mode if enabled
if [[ "$EXECUTE" == "vnc" ]]; then
    log_info "VNC mode enabled - waiting for remote connection"
    handle_vnc_mode "$WAIT_TIME"
    log_info "VNC mode completed - continuing with normal execution"
fi


# FUTURE: Handle VNC mode if enabled
# if [[ "$EXECUTE" == "vnc" ]]; then
#     log_info "VNC mode enabled - waiting for remote connection"
#     handle_vnc_mode "$WAIT_TIME"
# fi

log_info "Configuration loaded successfully"
log_info ""

################################################################################
# STAGE 3: NETWORK INITIALIZATION
################################################################################

log_info "STAGE 3: Network Initialization"
log_info "--------------------------------"

# FUTURE: Power on Starlink via USB relay
# log_info "Powering on Starlink via USB relay..."
# relay_on "starlink" || log_warn "Failed to control Starlink relay"
# log_info "Waiting for network connection..."
# wait_for_network_connection 60

# For now, just check network is available
check_network_available || {
    log_warn "Network not available - uploads may fail"
}

log_info "Network initialization completed"
log_info ""

################################################################################
# STAGE 4: DATA COLLECTION
################################################################################

log_info "STAGE 4: Data Collection"
log_info "-------------------------"

# FUTURE: Set LED to BLUE FLASHING (harvesting data)
# led_set_status "BLUE_FLASHING"

# Collect Starlink diagnostics
collect_starlink_diagnostics || log_warn "Starlink diagnostics collection failed"

# Run Pegasus harvest with retry logic
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

# FUTURE: Download timelapse camera files
# log_info "Downloading timelapse camera files..."
# if download_timelapse_files; then
#     log_info "Timelapse files downloaded successfully"
#     save_state "CAMERA_DOWNLOADED" "1"
# else
#     log_warn "Timelapse download failed"
#     save_state "CAMERA_DOWNLOADED" "0"
# fi

log_info "Data collection stage completed"
log_info ""

################################################################################
# STAGE 5: DATA UPLOAD
################################################################################

log_info "STAGE 5: Data Upload"
log_info "--------------------"

# FUTURE: Set LED to GREEN FLASHING (uploading)
# led_set_status "GREEN_FLASHING"

DATA_UPLOAD_SUCCESS=0
LOG_UPLOAD_SUCCESS=0

# Upload harvest data if successful
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

# FUTURE: Upload timelapse camera files
# if [[ $(get_state "CAMERA_DOWNLOADED") == "1" ]]; then
#     log_info "Uploading timelapse files..."
#     if upload_camera_files; then
#         log_info "SUCCESS: Camera files uploaded"
#         save_state "CAMERA_UPLOADED" "1"
#     else
#         log_warn "FAILED: Camera upload failed"
#         save_state "CAMERA_UPLOADED" "0"
#     fi
# fi

# Always upload log file
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

################################################################################
# STAGE 6: NOTIFICATION
################################################################################

log_info "STAGE 6: Sending Notification"
log_info "------------------------------"

# Determine overall status
if [[ $HARVEST_SUCCESS -eq 1 ]] && [[ $DATA_UPLOAD_SUCCESS -eq 1 ]] && [[ $LOG_UPLOAD_SUCCESS -eq 1 ]]; then
    OVERALL_STATUS="COMPLETE_SUCCESS"
elif [[ $HARVEST_SUCCESS -eq 1 ]] && [[ $LOG_UPLOAD_SUCCESS -eq 1 ]]; then
    OVERALL_STATUS="PARTIAL_SUCCESS"
elif [[ $HARVEST_SUCCESS -eq 1 ]]; then
    OVERALL_STATUS="HARVEST_SUCCESS_UPLOAD_FAILED"
else
    OVERALL_STATUS="HARVEST_FAILED"
fi

# Send email notification
send_status_notification "$OVERALL_STATUS" "$LOG_FILE" || {
    log_error "Failed to send email notification"
}

log_info "Notification sent"
log_info ""

################################################################################
# STAGE 7: CLEANUP AND SHUTDOWN
################################################################################

log_info "STAGE 7: Cleanup and Shutdown"
log_info "------------------------------"

# FUTURE: Power off Starlink via USB relay
# log_info "Powering off Starlink via USB relay..."
# relay_off "starlink" || log_warn "Failed to control Starlink relay"

# FUTURE: Set LED to GREEN SOLID (completed successfully)
# if [[ "$OVERALL_STATUS" == "COMPLETE_SUCCESS" ]]; then
#     led_set_status "GREEN_SOLID"
# else
#     led_set_status "RED_SOLID"
# fi

# Clean up temporary files
cleanup_temp_files

# Display final summary
log_info ""
log_info "=================================================="
log_info "TELE1 Execution Summary"
log_info "=================================================="
log_info "Overall Status: $OVERALL_STATUS"
log_info "Harvest Success: $([ $HARVEST_SUCCESS -eq 1 ] && echo 'YES' || echo 'NO')"
log_info "Data Upload Success: $([ $DATA_UPLOAD_SUCCESS -eq 1 ] && echo 'YES' || echo 'NO')"
log_info "Log Upload Success: $([ $LOG_UPLOAD_SUCCESS -eq 1 ] && echo 'YES' || echo 'NO')"
log_info "Execution time: $(($(date +%s) - $(date -d "$SCRIPT_START_TIME" +%s 2>/dev/null || echo 0))) seconds"
log_info "=================================================="
log_info ""

# Prompt for shutdown (or auto-shutdown based on config)
# Check if VNC mode was used - if so, auto-shutdown
if [[ "$(get_state VNC_MODE_COMPLETED)" != "" ]]; then
    prompt_for_shutdown true  # Auto-shutdown after VNC mode
else
    prompt_for_shutdown false  # Interactive prompt for manual runs
fi

# Script should not reach here (shutdown or user stays in terminal)
log_info "TELE1 execution completed"
exit $EXIT_SUCCESS
