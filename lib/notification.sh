#!/bin/bash

################################################################################
# Notification Library
# Functions for sending email notifications and collecting diagnostics
# Tobias Staal 2025
################################################################################

# Prevent multiple sourcing
[[ -n "${_NOTIFICATION_LIB_LOADED:-}" ]] && return 0
readonly _NOTIFICATION_LIB_LOADED=1

################################################################################
# EMAIL CONFIGURATION
################################################################################

EMAIL_TO="to_email@gmail.com"
EMAIL_FROM="my_gmail@gmail.com"
EMAIL_PASSWORD="my_password"
EMAIL_TIMEOUT=120

################################################################################
# STARLINK DIAGNOSTICS
################################################################################

# Collect Starlink network diagnostics
collect_starlink_diagnostics() {
    log_info "Collecting Starlink diagnostics..."
    
    local starlink_script="${JS_DIR}/starlink_get_json.js"
    
    if [[ ! -f "$starlink_script" ]]; then
        log_warn "Starlink diagnostics script not found: $starlink_script"
        return 1
    fi
    
    # Run Starlink diagnostics script with timeout
    local json_output
    if json_output=$(timeout 30 node "$starlink_script" 2>&1); then
        log_info "Starlink diagnostics collected successfully"
        
        # Log to file (formatted if jq available)
        {
            echo ""
            echo "========================================"
            echo "STARLINK DIAGNOSTIC DATA"
            echo "========================================"
            if command -v jq &>/dev/null; then
                echo "$json_output" | jq . 2>/dev/null || echo "$json_output"
            else
                echo "$json_output"
            fi
            echo "========================================"
            echo ""
        } >> "$LOG_FILE"
        
        save_state "STARLINK_DIAGNOSTICS" "collected"
        return 0
    else
        log_warn "Failed to collect Starlink diagnostics"
        save_state "STARLINK_DIAGNOSTICS" "failed"
        return 1
    fi
}

################################################################################
# STATUS REPORT BUILDING
################################################################################

# Build comprehensive status report
build_status_report() {
    local status="$1"
    
    # Collect state information
    local harvest_success
    harvest_success=$(get_state "HARVEST_COMPLETED" "0")
    
    local harvest_attempts
    harvest_attempts=$(get_state "HARVEST_ATTEMPTS" "0")
    
    local harvest_file_count
    harvest_file_count=$(get_state "HARVEST_FILE_COUNT" "0")
    
    local harvest_size
    harvest_size=$(get_state "HARVEST_SIZE" "N/A")
    
    local data_uploaded
    data_uploaded=$(get_state "DATA_UPLOADED" "0")
    
    local log_uploaded
    log_uploaded=$(get_state "LOG_UPLOADED" "0")
    
    local config_downloaded
    config_downloaded="$CONFIG_DOWNLOAD_SUCCESS"
    
    local harvest_dir
    harvest_dir=$(get_state "LAST_HARVEST_DIR" "N/A")
    
    local timestamp
    timestamp=$(get_state "HARVEST_TIMESTAMP" "N/A")
    
    # Build system status section
    local cpu_temp="N/A"
    if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
        cpu_temp="$(($(cat /sys/class/thermal/thermal_zone0/temp) / 1000))°C"
    fi
    
    local mem_available="N/A"
    if [[ -f /proc/meminfo ]]; then
        mem_available="$(grep MemAvailable /proc/meminfo | awk '{print int($2/1024)}')MB"
    fi
    
    local disk_space="N/A"
    disk_space=$(df -h "$DATA_DIR" 2>/dev/null | tail -1 | awk '{print $4}' || echo "N/A")
    
    # Build configuration section
    local config_section="Configuration Used:
- EXECUTE: $EXECUTE
- WAIT_TIME: $WAIT_TIME hours
- AFTER_WAIT: $AFTER_WAIT
- HARVEST_MODE: $HARVEST_MODE
- FROM_DATE: $FROM_DATE
- TO_DATE: $TO_DATE"
    
    # Build system status section
    local system_section="System Status:
- Hostname: $(hostname)
- Uptime: $(uptime -p 2>/dev/null || uptime)
- CPU Temperature: $cpu_temp
- Available Memory: $mem_available
- Disk Space Available: $disk_space
- Network: $(check_network_available &>/dev/null && echo 'Connected' || echo 'Disconnected')"
    
    # Build harvest results section
    local harvest_section="Harvest Results:
- Status: $([ "$harvest_success" == "1" ] && echo "SUCCESS after $harvest_attempts attempts" || echo "FAILED after $harvest_attempts attempts")
- Files collected: $harvest_file_count
- Data size: $harvest_size
- Harvest directory: $harvest_dir"
    
    # Build upload results section
    local upload_section="Upload Results:
- Data upload: $([ "$data_uploaded" == "1" ] && echo 'SUCCESS' || echo 'FAILED')
- Log upload: $([ "$log_uploaded" == "1" ] && echo 'SUCCESS' || echo 'FAILED')
- Config download: $([ "$config_downloaded" == "1" ] && echo 'SUCCESS' || echo 'FAILED')
- Dropbox folder: /$timestamp"
    
    # Combine all sections
    cat <<EOF
$harvest_section

$upload_section

$config_section

$system_section
EOF
}

################################################################################
# EMAIL FORMATTING
################################################################################

# Format email subject based on status
format_email_subject() {
    local status="$1"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M")
    
    case "$status" in
        "COMPLETE_SUCCESS")
            echo "TELE1: COMPLETE SUCCESS - $timestamp"
            ;;
        "PARTIAL_SUCCESS")
            echo "TELE1: PARTIAL SUCCESS - Upload Issues - $timestamp"
            ;;
        "HARVEST_SUCCESS_UPLOAD_FAILED")
            echo "TELE1: HARVEST SUCCESS, UPLOAD FAILED - $timestamp"
            ;;
        "HARVEST_FAILED")
            echo "TELE1: HARVEST FAILED - $timestamp"
            ;;
        *)
            echo "TELE1: STATUS UNKNOWN - $timestamp"
            ;;
    esac
}

# Format email body based on status
format_email_body() {
    local status="$1"
    local status_report="$2"
    
    local header=""
    
    case "$status" in
        "COMPLETE_SUCCESS")
            header="COMPLETE SUCCESS: All operations completed successfully."
            ;;
        "PARTIAL_SUCCESS")
            header="PARTIAL SUCCESS: Harvest succeeded but some uploads failed."
            ;;
        "HARVEST_SUCCESS_UPLOAD_FAILED")
            header="Harvest successful but all uploads failed. Manual intervention required."
            ;;
        "HARVEST_FAILED")
            header="FAILURE: Data harvest failed. Manual intervention required."
            ;;
        *)
            header="Status unknown - check logs for details."
            ;;
    esac
    
    cat <<EOF
$header

$status_report

Log file: $LOG_FILE

---
TELE1 Automated Data Collection System
EOF
}

################################################################################
# EMAIL SENDING
################################################################################

# Send email notification with log attachment
send_email_with_attachment() {
    local subject="$1"
    local body="$2"
    local attachment_file="$3"
    
    log_info "Sending email notification..."
    log_info "  To: $EMAIL_TO"
    log_info "  Subject: $subject"
    
    local temp_mail_file="/tmp/mail_$(date +%s).txt"
    
    # Create MIME multipart email with plain text attachment
    {
        echo "From: $EMAIL_FROM"
        echo "To: $EMAIL_TO"
        echo "Subject: $subject"
        echo "MIME-Version: 1.0"
        echo "Content-Type: multipart/mixed; boundary=\"BOUNDARY_TELE1\""
        echo ""
        echo "--BOUNDARY_TELE1"
        echo "Content-Type: text/plain; charset=utf-8"
        echo ""
        echo "$body"
        echo ""
        echo "--BOUNDARY_TELE1"
        echo "Content-Type: text/plain; charset=utf-8"
        echo "Content-Disposition: attachment; filename=\"$(basename "$attachment_file")\""
        echo "Content-Transfer-Encoding: 8bit"
        echo ""
        cat "$attachment_file"
        echo ""
        echo "--BOUNDARY_TELE1--"
    } > "$temp_mail_file"
    
    # Send via Gmail SMTP
    if timeout "$EMAIL_TIMEOUT" curl --url 'smtps://smtp.gmail.com:465' --ssl-reqd \
        --mail-from "$EMAIL_FROM" \
        --mail-rcpt "$EMAIL_TO" \
        --user "$EMAIL_FROM:$EMAIL_PASSWORD" \
        --max-time 120 --connect-timeout 60 \
        -T "$temp_mail_file" >> "$LOG_FILE" 2>&1; then
        
        log_info "SUCCESS: Email sent successfully"
        rm -f "$temp_mail_file"
        return 0
    else
        log_error "FAILED: Email sending failed"
        rm -f "$temp_mail_file"
        return 1
    fi
}

################################################################################
# MAIN NOTIFICATION FUNCTION
################################################################################

# Send status notification (main entry point)
send_status_notification() {
    local status="$1"
    local log_file="$2"
    
    log_info "Preparing status notification..."
    
    # Build status report
    local status_report
    status_report=$(build_status_report "$status")
    
    # Format email
    local subject
    subject=$(format_email_subject "$status")
    
    local body
    body=$(format_email_body "$status" "$status_report")
    
    # Send email
    if send_email_with_attachment "$subject" "$body" "$log_file"; then
        log_info "Status notification sent successfully"
        save_state "NOTIFICATION_SENT" "1"
        return 0
    else
        log_error "Failed to send status notification"
        save_state "NOTIFICATION_SENT" "0"
        
        # Create local notification file as fallback
        create_local_notification "$status" "$status_report"
        
        return 1
    fi
}

# Send simple failure notification (for early failures)
send_failure_notification() {
    local failure_type="$1"
    
    log_warn "Sending early failure notification: $failure_type"
    
    local subject="TELE1: EARLY FAILURE - $failure_type - $(date '+%Y-%m-%d %H:%M')"
    local body="TELE1 script encountered an early failure.

Failure Type: $failure_type
Timestamp: $(date '+%Y-%m-%d %H:%M:%S')
Hostname: $(hostname)

This is an automated notification. Check the system for details.

Log directory: $LOG_DIR"
    
    # Simple email without attachment
    local temp_mail_file="/tmp/mail_failure_$(date +%s).txt"
    
    {
        echo "From: $EMAIL_FROM"
        echo "To: $EMAIL_TO"
        echo "Subject: $subject"
        echo ""
        echo "$body"
    } > "$temp_mail_file"
    
    timeout "$EMAIL_TIMEOUT" curl --url 'smtps://smtp.gmail.com:465' --ssl-reqd \
        --mail-from "$EMAIL_FROM" \
        --mail-rcpt "$EMAIL_TO" \
        --user "$EMAIL_FROM:$EMAIL_PASSWORD" \
        --max-time 120 --connect-timeout 60 \
        -T "$temp_mail_file" &>> "${LOG_FILE:-/tmp/tele1_emergency.log}"
    
    rm -f "$temp_mail_file"
}

################################################################################
# LOCAL NOTIFICATION FALLBACK
################################################################################

# Create local notification file if email fails
create_local_notification() {
    local status="$1"
    local status_report="$2"
    
    local notification_file="/tmp/tele1_notification_$(date +%s).txt"
    
    log_info "Creating local notification file: $notification_file"
    
    {
        echo "========================================"
        echo "TELE1 STATUS NOTIFICATION"
        echo "========================================"
        echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Status: $status"
        echo ""
        echo "$status_report"
        echo ""
        echo "Log file: $LOG_FILE"
        echo "========================================"
    } > "$notification_file"
    
    log_info "Local notification saved: $notification_file"
}

################################################################################
# EXPORT FUNCTIONS
################################################################################

export -f collect_starlink_diagnostics
export -f build_status_report format_email_subject format_email_body
export -f send_email_with_attachment send_status_notification
export -f send_failure_notification create_local_notification
