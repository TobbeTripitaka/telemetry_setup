#!/bin/bash

################################################################################
# Post-Upload Action Library
# Functions for executing configuration-driven actions after data upload
# Tobias Stål 2025
################################################################################

# Prevent multiple sourcing
[[ -n "${_POSTACTION_LIB_LOADED:-}" ]] && return 0
readonly _POSTACTION_LIB_LOADED=1

################################################################################
# POST-ACTION CONFIGURATION VARIABLES
################################################################################

EXECUTE="simple" # Options: simple, remote, clean, update
STANDBY=0 # Seconds to wait in remote mode
POSTACTION_CONFIG_DOWNLOAD_SUCCESS=0

################################################################################
# CONFIGURATION DOWNLOAD & PARSING
################################################################################

# Download and parse post-action configuration from remote (via rclone)
download_and_parse_config() {

    log_info "Downloading post-action configuration from ${RCLONE_REMOTE}:/ ..."
    local config_remote_path="${RCLONE_REMOTE}:/config.txt"
    local config_local_path="${CONFIG_DIR}/config.txt"
    local max_attempts=3
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        log_info "Config download attempt $attempt of $max_attempts"

        if timeout 60 rclone copy "$config_remote_path" "$CONFIG_DIR/" \
            --progress \
            --transfers 1 \
            --checkers 1 \
            --retries 2 \
            --verbose 2>> "$RCLONE_LOG_PATH"; then

            log_info "SUCCESS: Config file downloaded"
            POSTACTION_CONFIG_DOWNLOAD_SUCCESS=1

            if parse_postaction_config "$config_local_path"; then
                return 0
            else
                log_error "Failed to parse configuration file"
                return 1
            fi
        else
            local exit_code=$?
            log_warn "FAILED: Config download attempt $attempt (exit code: $exit_code)"

            if [[ $attempt -lt $max_attempts ]]; then
                log_info "Waiting 10 seconds before retry..."
                sleep 10
            fi
        fi

        ((attempt++))
    done

    log_error "Failed to download config after $max_attempts attempts"
    POSTACTION_CONFIG_DOWNLOAD_SUCCESS=0

    return 1
}

# Parse post-action configuration file
parse_postaction_config() {

    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration file not found: $config_file"
        return 1
    fi

    log_info "Parsing configuration file..."

    EXECUTE="simple"
    STANDBY=0

    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue

        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)

        case "${key^^}" in
            EXECUTE)
                if [[ "$value" =~ ^(simple|remote|clean|update)$ ]]; then
                    EXECUTE="$value"
                    log_info "EXECUTE set to: $EXECUTE"
                else
                    log_warn "Invalid EXECUTE value: $value (using default: simple)"
                    EXECUTE="simple"
                fi
                ;;

            STANDBY)
                if [[ "$value" =~ ^[0-9]+$ ]]; then
                    STANDBY="$value"
                    log_info "STANDBY set to: $STANDBY seconds"
                else
                    log_warn "Invalid STANDBY value: $value (using default: 0)"
                    STANDBY=0
                fi
                ;;

            *)
                log_debug "Ignoring unknown configuration parameter: $key"
                ;;
        esac

    done < "$config_file"

    return 0
}

# Load default post-action configuration
load_default_postaction_config() {

    log_info "Loading default post-action configuration..."

    EXECUTE="simple"
    STANDBY=0

    log_info "Defaults: EXECUTE=simple, STANDBY=0"
}

# Display final post-action configuration
display_postaction_config() {

    log_info ""
    log_info "================================"
    log_info "Post-Action Configuration"
    log_info "================================"
    log_info "EXECUTE: $EXECUTE"

    if [[ "$EXECUTE" == "remote" ]]; then
        log_info "STANDBY: $STANDBY seconds"
    fi

    log_info "================================"
    log_info ""
}

################################################################################
# POST-ACTION HANDLERS
################################################################################

# Simple action: Send email and power down (handled by main script)
execute_simple_action() {

    log_info "Executing SIMPLE action: email notification and power down"

    # Nothing extra here – notification and shutdown are handled by tele1.sh
}

# Remote action: Enable SSH and wait for STANDBY seconds
execute_remote_action() {

    log_info "Executing REMOTE action: enable SSH and wait"
    log_info "Enabling SSH daemon..."

    if enable_ssh_daemon; then
        log_info "SSH daemon enabled successfully"
        log_info "SSH is now available for remote access"
    else
        log_warn "Failed to enable SSH daemon"
    fi

    if [[ $STANDBY -gt 0 ]]; then
        log_info "Waiting $STANDBY seconds for remote access..."
        sleep "$STANDBY"
        log_info "STANDBY period completed"
    else
        log_info "STANDBY time is 0, skipping wait"
    fi

    log_info "Remote session ended, proceeding to power down"
}

# Clean action: Delete old data/logs
execute_clean_action() {

    log_info "Executing CLEAN action: delete old data and logs"

    log_info "Cleaning old harvest data (keeping only most recent)..."

    if clean_old_harvest_data; then
        log_info "Harvest data cleanup completed"
    else
        log_warn "Harvest data cleanup encountered issues"
    fi

    log_info "Cleaning old logs (keeping last 7 days)..."

    if clean_old_logs; then
        log_info "Logs cleanup completed"
    else
        log_warn "Logs cleanup encountered issues"
    fi

    log_info "Clean action completed"
}

# Update action: Placeholder
execute_update_action() {

    log_info "Executing UPDATE action"
    log_warn "UPDATE not yet implemented - this is a placeholder"
    log_info "Proceeding to notification and power down"
}

################################################################################
# SSH MANAGEMENT
################################################################################

# Enable SSH daemon if not already running
enable_ssh_daemon() {

    log_debug "Enabling SSH daemon..."

    if ! command -v systemctl &>/dev/null; then
        log_warn "systemctl not available, cannot manage SSH service"
        return 1
    fi

    # Enable and start SSH service (supports ssh or sshd names)
    if systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null; then
        log_debug "SSH service enabled"
    else
        log_warn "Failed to enable SSH service"
        return 1
    fi

    if systemctl start ssh 2>/dev/null || systemctl start sshd 2>/dev/null; then
        log_debug "SSH service started"
        return 0
    else
        log_warn "Failed to start SSH service"
        return 1
    fi
}

# Configure SSH port (stub for future implementation)
configure_ssh_port() {

    local port="$1"
    log_debug "STUB: Would configure SSH port to $port"

    # Future implementation
}

# Open SSH firewall (stub for future implementation)
open_ssh_firewall() {

    log_debug "STUB: Would open firewall for SSH"

    # Future implementation
}

################################################################################
# DATA & LOG CLEANUP
################################################################################

# Delete old harvest folders, keeping only most recent
clean_old_harvest_data() {

    log_info "Scanning harvest data directory: $DATA_DIR"

    if [[ ! -d "$DATA_DIR" ]]; then
        log_warn "Harvest data directory does not exist: $DATA_DIR"
        return 1
    fi

    local dir_count
    dir_count=$(find "$DATA_DIR" -maxdepth 1 -type d ! -name "." | wc -l)

    if [[ $dir_count -le 1 ]]; then
        log_info "Only 0–1 harvest folders found, nothing to delete"
        return 0
    fi

    log_info "Found $dir_count harvest folders"

    local most_recent
    most_recent=$(find "$DATA_DIR" -maxdepth 1 -type d ! -name "." -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)

    if [[ -z "$most_recent" ]]; then
        log_error "Could not determine most recent harvest folder"
        return 1
    fi

    log_info "Most recent harvest folder: $most_recent"

    local deleted_count=0

    while IFS= read -r dir; do
        if [[ "$dir" != "$most_recent" ]]; then
            log_info "Deleting old harvest folder: $dir"

            if rm -rf "$dir"; then
                ((deleted_count++))
            else
                log_warn "Failed to delete: $dir"
            fi
        fi
    done < <(find "$DATA_DIR" -maxdepth 1 -type d ! -name ".")

    log_info "Deleted $deleted_count old harvest folders"
    return 0
}

# Delete logs older than 7 days, keeping recent logs
clean_old_logs() {

    log_info "Scanning logs directory: $LOG_DIR"

    if [[ ! -d "$LOG_DIR" ]]; then
        log_warn "Logs directory does not exist: $LOG_DIR"
        return 1
    fi

    local log_count
    log_count=$(find "$LOG_DIR" -maxdepth 1 -type f -name "*.log" | wc -l)

    if [[ $log_count -eq 0 ]]; then
        log_info "No log files found to delete"
        return 0
    fi

    log_info "Found $log_count log files"

    local deleted_count=0
    local days_to_keep=7

    while IFS= read -r logfile; do
        if [[ -f "$logfile" ]]; then
            local file_age_days

            # POSIX-compatible stat
            if stat -f%m "$logfile" &>/dev/null; then
                file_age_days=$(( ( $(date +%s) - $(stat -f%m "$logfile") ) / 86400 ))
            else
                file_age_days=$(( ( $(date +%s) - $(stat -c%Y "$logfile") ) / 86400 ))
            fi

            if [[ $file_age_days -gt $days_to_keep ]]; then
                log_info "Deleting old log file (${file_age_days} days old): $(basename "$logfile")"

                if rm -f "$logfile"; then
                    ((deleted_count++))
                else
                    log_warn "Failed to delete: $logfile"
                fi
            fi
        fi
    done < <(find "$LOG_DIR" -maxdepth 1 -type f -name "*.log")

    log_info "Deleted $deleted_count log files older than $days_to_keep days"
    return 0
}

################################################################################
# INTEGRATION WITH CONFIG SYSTEM (future use)
################################################################################

# This library can be integrated into tele1.sh for post-upload actions
# Example usage in tele1.sh:
#
# if [[ "$EXECUTE" == "remote" ]]; then
#     log_info "Post-action: REMOTE mode"
#     download_and_parse_config || load_default_postaction_config
#     parse_and_validate_postaction_config
#     display_postaction_config
#     execute_remote_action
# elif [[ "$EXECUTE" == "clean" ]]; then
#     log_info "Post-action: CLEAN mode"
#     execute_clean_action
# fi

################################################################################
# EXPORT FUNCTIONS
################################################################################

export -f download_and_parse_config parse_postaction_config
export -f load_default_postaction_config display_postaction_config
export -f execute_simple_action execute_remote_action
export -f execute_clean_action execute_update_action
export -f enable_ssh_daemon configure_ssh_port open_ssh_firewall
export -f clean_old_harvest_data clean_old_logs
