#!/bin/bash

################################################################################
# Upload Library - Updated for new workflow
# Functions for compressing and uploading data
# Tobias Staal 2025
################################################################################

# Prevent multiple sourcing
[[ -n "${_UPLOAD_LIB_LOADED:-}" ]] && return 0
readonly _UPLOAD_LIB_LOADED=1

################################################################################
# DATA COMPRESSION
################################################################################

# Compress harvest data to tar.gz
compress_harvest_data() {
    log_info "Compressing harvest data..."

    local harvest_dir
    harvest_dir=$(get_state "LAST_HARVEST_DIR" "")

    if [[ -z "$harvest_dir" ]] || [[ ! -d "$harvest_dir" ]]; then
        log_error "Harvest directory not found or not set (LAST_HARVEST_DIR)"
        return 1
    fi

    local compress_file="${harvest_dir}.tar.gz"

    # Check if already compressed
    if [[ -f "$compress_file" ]]; then
        log_warn "Compressed file already exists: $compress_file"
        return 0
    fi

    log_info "Creating archive: $compress_file"
    if tar -czf "$compress_file" -C "$(dirname "$harvest_dir")" "$(basename "$harvest_dir")" 2>> "$LOG_FILE"; then
        local compressed_size
        compressed_size=$(du -h "$compress_file" | awk '{print $1}')
        log_info "SUCCESS: Data compressed (size: $compressed_size)"

        # File count and size for reporting
        local file_count
        file_count=$(find "$harvest_dir" -type f | wc -l)

        save_state "HARVEST_FILE_COUNT" "$file_count"
        save_state "HARVEST_SIZE" "$compressed_size"

        return 0
    else
        log_error "Failed to compress data"
        return 1
    fi
}

################################################################################
# DATA UPLOAD
################################################################################

# Upload harvest data to Dropbox
upload_harvest_data() {
    log_info "Uploading harvest data to Dropbox..."

    local harvest_dir
    harvest_dir=$(get_state "LAST_HARVEST_DIR" "")

    if [[ -z "$harvest_dir" ]] || [[ ! -d "$harvest_dir" ]]; then
        log_error "Harvest directory not found (LAST_HARVEST_DIR)"
        return 1
    fi

    # Prefer compressed archive if present
    local upload_source
    if [[ -f "${harvest_dir}.tar.gz" ]]; then
        upload_source="${harvest_dir}.tar.gz"
    else
        upload_source="$harvest_dir"
    fi

    local timestamp
    timestamp=$(get_state "HARVEST_TIMESTAMP" "$(date '+%Y-%m-%d_%H-%M-%S')")
    local remote_path="/harvests/${timestamp}"

    local max_attempts=3
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        log_info "Upload attempt $attempt of $max_attempts to $remote_path"

        if timeout 600 "$DROPBOX_SCRIPT" upload "$upload_source" "$remote_path" >> "$LOG_FILE" 2>&1; then
            log_info "SUCCESS: Harvest data uploaded to Dropbox"
            return 0
        else
            log_warn "FAILED: Upload attempt $attempt"
            if [[ $attempt -lt $max_attempts ]]; then
                log_info "Waiting 20 seconds before retry..."
                sleep 20
            fi
        fi

        ((attempt++))
    done

    log_error "Failed to upload harvest data after $max_attempts attempts"
    return 1
}

# Upload log file to Dropbox
upload_log_file() {
    local log_file="$1"

    if [[ ! -f "$log_file" ]]; then
        log_error "Log file not found: $log_file"
        return 1
    fi

    log_info "Uploading log file: $log_file"

    local remote_path="/logs/$(basename "$log_file")"

    if timeout 300 "$DROPBOX_SCRIPT" upload "$log_file" "$remote_path" >> "$LOG_FILE" 2>&1; then
        log_info "SUCCESS: Log file uploaded to Dropbox"
        return 0
    else
        log_error "FAILED: Log file upload failed"
        return 1
    fi
}

################################################################################
# EXPORT FUNCTIONS
################################################################################

export -f compress_harvest_data upload_harvest_data upload_log_file
