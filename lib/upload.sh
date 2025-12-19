#!/bin/bash

################################################################################
# Upload Library
# Functions for uploading data and logs to Dropbox
################################################################################

# Prevent multiple sourcing
[[ -n "${_UPLOAD_LIB_LOADED:-}" ]] && return 0
readonly _UPLOAD_LIB_LOADED=1

################################################################################
# UPLOAD CONFIGURATION
################################################################################

MAX_UPLOAD_ATTEMPTS=3
UPLOAD_RETRY_DELAY=30
UPLOAD_TIMEOUT=3000

################################################################################
# GENERIC UPLOAD FUNCTION
################################################################################

# Upload a single file to Dropbox with retry
upload_file_to_dropbox() {
    local local_file="$1"
    local remote_path="$2"
    local max_attempts="${3:-$MAX_UPLOAD_ATTEMPTS}"
    local timeout="${4:-$UPLOAD_TIMEOUT}"
    
    if [[ ! -f "$local_file" ]]; then
        log_error "File not found for upload: $local_file"
        return 1
    fi
    
    local file_size
    file_size=$(get_file_size "$local_file")
    
    log_info "Uploading file: $(basename "$local_file") ($file_size)"
    log_info "  Local path: $local_file"
    log_info "  Remote path: $remote_path"
    
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Upload attempt $attempt of $max_attempts"
        
        if timeout "$timeout" "$DROPBOX_SCRIPT" upload "$local_file" "$remote_path" >> "$LOG_FILE" 2>&1; then
            log_info "SUCCESS: File uploaded on attempt $attempt"
            return 0
        else
            local exit_code=$?
            log_warn "FAILED: Upload attempt $attempt failed (exit code: $exit_code)"
            
            if [[ $attempt -lt $max_attempts ]]; then
                log_info "Waiting ${UPLOAD_RETRY_DELAY}s before retry..."
                sleep "$UPLOAD_RETRY_DELAY"
            fi
        fi
        
        ((attempt++))
    done
    
    log_error "FAILED: File upload failed after $max_attempts attempts"
    return 1
}

################################################################################
# HARVEST DATA UPLOAD
################################################################################

# Upload harvest data (compress and upload)
upload_harvest_data() {
    log_info "Preparing harvest data for upload..."

    # Compress harvest directory
    local archive_path
    archive_path=$(compress_harvest 2>&1 | tail -1)  # ← Only capture last line
    if [[ -z "$archive_path" || ! -f "$archive_path" ]]; then
        log_error "Failed to compress harvest data"
        return 1
    fi

    # Determine remote destination
    local timestamp
    timestamp=$(basename "$HARVEST_DIR")
    local remote_dir="/${timestamp}"
    local remote_file="${remote_dir}/$(basename "$archive_path")"

    log_info "Dropbox destination: $remote_file"

    # Upload compressed archive
    if upload_file_to_dropbox "$archive_path" "$remote_file"; then
        log_info "Harvest data uploaded successfully"

        
        # Clean up temporary archive
        log_info "Cleaning up temporary archive..."
        rm -f "$archive_path"
        
        save_state "DATA_UPLOADED" "1"
        save_state "DATA_UPLOAD_PATH" "$remote_file"
        
        return 0
    else
        log_error "Harvest data upload failed"
        save_state "DATA_UPLOADED" "0"
        
        # Keep archive for manual upload
        log_warn "Archive retained for manual upload: $archive_path"
        
        return 1
    fi
}

################################################################################
# LOG FILE UPLOAD
################################################################################

# Upload log file to Dropbox
upload_log_file() {
    local log_file="$1"
    
    log_info "Preparing log file for upload..."
    
    if [[ ! -f "$log_file" ]]; then
        log_error "Log file not found: $log_file"
        return 1
    fi
    
    # Determine remote destination (same folder as harvest data)
    local timestamp
    timestamp=$(get_state "HARVEST_TIMESTAMP" "$(date '+%Y%m%d_%H%M')")
    local remote_dir="/${timestamp}"
    local remote_file="${remote_dir}/$(basename "$log_file")"
    
    log_info "Dropbox destination: $remote_file"
    
    # Upload log file
    if upload_file_to_dropbox "$log_file" "$remote_file" 3 120; then
        log_info "Log file uploaded successfully"
        save_state "LOG_UPLOADED" "1"
        save_state "LOG_UPLOAD_PATH" "$remote_file"
        return 0
    else
        log_error "Log file upload failed"
        save_state "LOG_UPLOADED" "0"
        return 1
    fi
}

################################################################################
# CAMERA FILES UPLOAD (FUTURE IMPLEMENTATION)
################################################################################

# Upload timelapse camera files
upload_camera_files() {
    log_info "Preparing camera files for upload..."
    
    # FUTURE IMPLEMENTATION:
    # This function will:
    # 1. Locate camera data directory
    # 2. Compress camera files (images/videos)
    # 3. Upload to Dropbox
    # 4. Clean up after successful upload
    #
    # Example structure:
    # local camera_data_dir="/home/tele/tele/data/camera"
    # local archive_name="camera_data_$(date '+%Y%m%d_%H%M').tar.gz"
    # local archive_path="/tmp/${archive_name}"
    #
    # # Compress camera files
    # if tar -czf "$archive_path" -C "$camera_data_dir" . 2>>"$LOG_FILE"; then
    #     local timestamp=$(date '+%Y%m%d_%H%M')
    #     local remote_file="/${timestamp}/${archive_name}"
    #     
    #     # Upload
    #     if upload_file_to_dropbox "$archive_path" "$remote_file"; then
    #         log_info "Camera files uploaded successfully"
    #         rm -f "$archive_path"
    #         
    #         # Clean camera directory after successful upload
    #         rm -rf "${camera_data_dir}"/*
    #         
    #         save_state "CAMERA_UPLOADED" "1"
    #         return 0
    #     fi
    # fi
    
    log_warn "Camera file upload not yet implemented (stub function)"
    return 0
}

################################################################################
# UPLOAD STATUS VERIFICATION
################################################################################

# Verify upload success by checking state
verify_uploads() {
    log_info "Verifying upload status..."
    
    local data_uploaded
    data_uploaded=$(get_state "DATA_UPLOADED" "0")
    
    local log_uploaded
    log_uploaded=$(get_state "LOG_UPLOADED" "0")
    
    log_info "Data uploaded: $([ "$data_uploaded" == "1" ] && echo 'YES' || echo 'NO')"
    log_info "Log uploaded: $([ "$log_uploaded" == "1" ] && echo 'YES' || echo 'NO')"
    
    if [[ "$data_uploaded" == "1" ]] && [[ "$log_uploaded" == "1" ]]; then
        log_info "All uploads completed successfully"
        return 0
    else
        log_warn "Some uploads incomplete"
        return 1
    fi
}

################################################################################
# EXPORT FUNCTIONS
################################################################################

export -f upload_file_to_dropbox
export -f upload_harvest_data upload_log_file upload_camera_files
export -f verify_uploads
