#!/bin/bash

################################################################################
# Upload Library - Rclone-based Implementation
# Functions for compressing and uploading data to Dropbox via rclone
# Tobias Stål 2025
################################################################################

# Prevent multiple sourcing
[[ -n "${_UPLOAD_LIB_LOADED:-}" ]] && return 0
readonly _UPLOAD_LIB_LOADED=1

################################################################################
# HELPER FUNCTIONS
################################################################################

# Get list of files currently in a remote rclone directory
get_remote_file_list() {
    local remote_path="$1"

    # List files in remote, output format: "filename"
    rclone lsf "$remote_path" --format "p" 2>/dev/null | sort || true
}

# Check if a file exists on the remote
remote_file_exists() {
    local remote_path="$1"
    local filename="$2"

    # Use rclone lsf with filter
    rclone lsf "$remote_path" --include "$filename" 2>/dev/null | grep -q "^${filename}$" && return 0 || return 1
}

################################################################################
# DATA COMPRESSION
################################################################################

compress_harvest_data() {
    log_info "Compressing harvest data (with copied run log)..."

    local harvest_dir
    harvest_dir=$(get_state "LAST_HARVEST_DIR" "")

    if [[ -z "$harvest_dir" ]] || [[ ! -d "$harvest_dir" ]]; then
        log_error "Harvest directory not found or not set (LAST_HARVEST_DIR)"
        return 1
    fi

    # Harvest parent and name (e.g. /home/tele/tele/data/pegasus and 20260106_0414)
    local harvest_parent
    harvest_parent="$(dirname "$harvest_dir")"
    local harvest_name
    harvest_name="$(basename "$harvest_dir")"

    # Copy the current run log into the harvest directory (best-effort)
    if [[ -n "${LOG_FILE:-}" ]] && [[ -f "$LOG_FILE" ]]; then
        local log_basename
        log_basename="$(basename "$LOG_FILE")"
        local log_target="${harvest_dir}/${log_basename}"

        if cp "$LOG_FILE" "$log_target" 2>/dev/null; then
            log_info "Copied run log into harvest dir: $log_target"
        else
            log_warn "Failed to copy run log into harvest dir; proceeding without log in archive"
        fi
    else
        log_warn "LOG_FILE not set or log file not found; proceeding without log in archive"
    fi

    # One archive per run: just the harvest directory (now containing data + copied log)
    local compress_file="${harvest_parent}/${harvest_name}.tar.gz"

    # Check if already compressed
    if [[ -f "$compress_file" ]]; then
        log_warn "Compressed file already exists: $compress_file"
        return 0
    fi

    log_info "Creating archive: $compress_file"

    (
        cd "$harvest_parent" || exit 1
        # Compress only the harvest directory (by name)
        if tar -czf "$compress_file" "$harvest_name"; then
            :
        else
            exit 1
        fi
    )

    if [[ $? -ne 0 ]]; then
        log_error "Failed to compress data/log"
        return 1
    fi

    local compressed_size
    compressed_size=$(du -h "$compress_file" | awk '{print $1}')
    log_info "SUCCESS: Data directory compressed (size: $compressed_size)"

    # File count and size for reporting
    local file_count
    file_count=$(find "$harvest_dir" -type f | wc -l)
    save_state "HARVEST_FILE_COUNT" "$file_count" 2>/dev/null || log_warn "save_state HARVEST_FILE_COUNT failed"
    save_state "HARVEST_SIZE" "$compressed_size" 2>/dev/null || log_warn "save_state HARVEST_SIZE failed"

    return 0
}



################################################################################
# DATA UPLOAD (RCLONE-BASED)
################################################################################

# Upload all compressed harvest archives not already on remote
upload_harvest_data() {
    log_info "Uploading harvest data to ${RCLONE_REMOTE}:data/ ..."

    local harvest_base_dir
    harvest_base_dir=$(dirname "$(get_state "LAST_HARVEST_DIR" "")")

    if [[ -z "$harvest_base_dir" ]] || [[ ! -d "$harvest_base_dir" ]]; then
        log_error "Harvest base directory not found"
        return 1
    fi

    local local_archives=()
    while IFS= read -r -d '' archive; do
        local_archives+=("$archive")
    done < <(find "$harvest_base_dir" -maxdepth 1 -name "*.tar.gz" -print0 2>/dev/null)

    if [[ ${#local_archives[@]} -eq 0 ]]; then
        log_warn "No compressed harvest archives found in $harvest_base_dir"
        return 1
    fi

    log_info "Found ${#local_archives[@]} archive file(s)"

    local uploaded_count=0
    local failed_count=0

    for archive in "${local_archives[@]}"; do
        local filename
        filename=$(basename "$archive")

        log_info "Checking: $filename"

        # Skip if same-name archive already on remote
        if remote_file_exists "${RCLONE_REMOTE}:data/" "$filename" 2>/dev/null; then
            log_info "  → Already on remote, skipping: $filename"
            ((uploaded_count++))
            continue
        fi

        log_info "  → Uploading: $filename"

            # Upload the file
    log_info "  → Uploading: $filename"

    local start_time=$(date '+%s')

    if timeout 3600 rclone copy "$archive" "${RCLONE_REMOTE}:data/" \
        --progress \
        --transfers 1 \
        --checkers 1 \
        --retries 2 \
        --verbose 2>> "$RCLONE_LOG_PATH"; then

        local end_time=$(date '+%s')
        local elapsed=$((end_time - start_time))
        local file_size_kb=$(du -k "$archive" | awk '{print $1}')

        log_info "  → SUCCESS: $filename uploaded ($file_size_kb KB in ${elapsed}s)"
        ((uploaded_count++))
    else
        local exit_code=$?
        log_error "  → FAILED: $filename upload failed (exit code: $exit_code)"
        ((failed_count++))
    fi

    done

    log_info "Upload summary: $uploaded_count file(s) processed, $failed_count failed"

    if [[ $failed_count -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}


################################################################################
# EXPORT FUNCTIONS
################################################################################

export -f compress_harvest_data
export -f upload_harvest_data
export -f get_remote_file_list remote_file_exists
