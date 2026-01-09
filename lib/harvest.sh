#!/bin/bash

################################################################################
# Data Harvest Library for Pegasus Automation
################################################################################

# Prevent multiple sourcing
[[ -n "${_HARVEST_LIB_LOADED:-}" ]] && return 0
readonly _HARVEST_LIB_LOADED=1

################################################################################
# CONFIGURATION
################################################################################

MAX_HARVEST_ATTEMPTS=3
HARVEST_TIMEOUT=300
PEGASUS_STARTUP_WAIT=6
PEGASUS_SHUTDOWN_WAIT=2

HARVEST_DIR=""
HARVEST_FILES_COUNT=0
HARVEST_SUCCESS=0

################################################################################
# FUNCTIONS
################################################################################

prepare_harvest_directory() {
    local current_time
    current_time=$(date "+%Y%m%d_%H%M")

    HARVEST_DIR="${DATA_DIR}/${current_time}"
    log_info "Creating harvest directory: $HARVEST_DIR"
    mkdir -p "$HARVEST_DIR"
    [[ ! -d "$HARVEST_DIR" ]] && { log_error "Failed to create harvest directory"; return 1; }

    TIMESTAMP_MARKER="/tmp/harvest_start_${current_time}"
    touch "$TIMESTAMP_MARKER"

    save_state "LAST_HARVEST_DIR" "$HARVEST_DIR" 2>/dev/null || log_warn "save_state LAST_HARVEST_DIR failed"
    save_state "HARVEST_TIMESTAMP" "$current_time" 2>/dev/null || log_warn "save_state HARVEST_TIMESTAMP failed"


    return 0
}

launch_pegasus() {
    log_info "Launching Pegasus Harvester..."

    log_info "Cleaning up any existing Pegasus processes..."
    pkill -9 pegasus 2>/dev/null || true
    pkill -9 -f PegasusHarvester 2>/dev/null || true
    pkill -9 -f pegasus-harvester 2>/dev/null || true
    killall -9 pegasus-harvester 2>/dev/null || true

    local port_pid
    port_pid=$(lsof -ti :9222 2>/dev/null)
    if [[ -n "$port_pid" ]]; then
        log_warn "Killing process holding port 9222 (PID: $port_pid)"
        kill -9 "$port_pid" 2>/dev/null || true
    fi

    sleep 3

    log_info "PEGASUS_BIN=$PEGASUS_BIN"
    log_info "Launch command: $PEGASUS_BIN --remote-debugging-port=9222 --remote-allow-origins=*"

    "$PEGASUS_BIN" --remote-debugging-port=9222 --remote-allow-origins=* > /dev/null 2>&1 &
    local pid=$!
    log_info "Pegasus Harvester started (PID: $pid)"
    log_info "Waiting ${PEGASUS_STARTUP_WAIT}s for Pegasus to initialize..."
    sleep "$PEGASUS_STARTUP_WAIT"

    # Just verify process is still running, don't check port
    if ! ps -p "$pid" > /dev/null 2>&1; then
        log_error "Pegasus Harvester process died"
        return 1
    fi

    log_info "Pegasus Harvester initialized (PID verified)"
    echo "$pid"
    return 0
}

shutdown_pegasus() {
    local pid="$1"
    log_info "Shutting down Pegasus Harvester (PID: $pid)..."

    if ps -p "$pid" > /dev/null 2>&1; then
        kill "$pid" 2>/dev/null || true
        sleep "$PEGASUS_SHUTDOWN_WAIT"
    fi

    if ps -p "$pid" > /dev/null 2>&1; then
        log_warn "Pegasus did not terminate, force killing..."
        kill -9 "$pid" 2>/dev/null || true
        sleep 1
    fi

    pkill -9 -f "$PEGASUS_BIN" 2>/dev/null || true
    log_info "Pegasus Harvester shutdown complete"
}

run_single_pegasus_harvest() {
    log_info "Starting single harvest attempt..."

    prepare_harvest_directory || return 1

    local pegasus_pid
    pegasus_pid=$(launch_pegasus) || return 1

    log_info "Running JavaScript harvester..."
    log_info "Command: node $JS_DIR/pegasus_harvest.js $HARVEST_DIR $EXECUTE $WAIT_TIME $AFTER_WAIT \"$HARVEST_MODE\" \"$FROM_DATE\" \"$TO_DATE\""

    # Run Node.js WITHOUT timeout wrapper, WITH output to console and log
    node "$JS_DIR/pegasus_harvest.js" \
        "$HARVEST_DIR" \
        "$EXECUTE" \
        "$WAIT_TIME" \
        "$AFTER_WAIT" \
        "$HARVEST_MODE" \
        "$FROM_DATE" \
        "$TO_DATE" 2>&1 | tee -a "$LOG_FILE"
    local status=${PIPESTATUS[0]}

    if [[ $status -eq 0 ]]; then
        log_info "JavaScript Harvester completed successfully"
    else
        log_error "JavaScript Harvester failed (exit code $status)"
    fi

    shutdown_pegasus "$pegasus_pid"
    return $status
}

run_harvest_with_retry() {
    log_info "Starting Pegasus harvest cycle..."
    local attempt=1

    while [[ $attempt -le $MAX_HARVEST_ATTEMPTS ]]; do
        log_info "========================================"
        log_info "Harvest Attempt $attempt of $MAX_HARVEST_ATTEMPTS"
        log_info "========================================"

        if run_single_pegasus_harvest; then
            log_info "SUCCESS: Harvest automation completed on attempt $attempt"

            if verify_harvest_success; then
                HARVEST_SUCCESS=1
                save_state "HARVEST_COMPLETED" "1" 2>/dev/null || log_warn "save_state 1 HARVEST_COMPLETED failed"
                save_state "HARVEST_ATTEMPTS" "$attempt" 2>/dev/null || log_warn "save_state HARVEST_ATTEMPTS failed"

                analyze_harvest_data
                return 0
            else
                log_warn "Automation completed but no data harvested"
            fi
        else
            log_error "FAILED: Harvest automation failed on attempt $attempt"
        fi

        if [[ $attempt -lt $MAX_HARVEST_ATTEMPTS ]]; then
            log_info "Waiting 10 seconds before retry..."
            sleep 10
        fi

        ((attempt++))
    done

    log_error "Harvest failed after $MAX_HARVEST_ATTEMPTS attempts"
    save_state "HARVEST_COMPLETED" "0" 2>/dev/null || log_warn "save_state 0 HARVEST_COMPLETED failed"
    save_state "HARVEST_ATTEMPTS" "$attempt" 2>/dev/null || log_warn "save_state HARVEST_ATTEMPTS failed"
    return 1
}

verify_harvest_success() {
    log_info "Verifying harvest success..."

    [[ ! -d "$HARVEST_DIR" ]] && { log_error "Harvest directory does not exist: $HARVEST_DIR"; return 1; }

    local file_count
    file_count=$(find "$HARVEST_DIR" -type f 2>/dev/null | wc -l)
    [[ $file_count -eq 0 ]] && { log_warn "No files found in harvest directory"; return 1; }

    log_info "Harvest verified: $file_count files collected"
    HARVEST_FILES_COUNT=$file_count
    return 0
}

analyze_harvest_data() {
    log_info ""
    log_info "Analyzing harvested data..."
    log_info "----------------------------"

    [[ ! -d "$HARVEST_DIR" ]] && { log_warn "Harvest directory not found for analysis"; return 1; }

    local total_files total_size
    total_files=$(find "$HARVEST_DIR" -type f 2>/dev/null | wc -l)
    total_size=$(du -sh "$HARVEST_DIR" 2>/dev/null | awk '{print $1}' || echo 'N/A')

    log_info "Total files harvested: $total_files"
    log_info "Total harvest size: $total_size"


    save_state "HARVEST_FILE_COUNT" "$total_files" 2>/dev/null || log_warn "save_state HARVEST_FILE_COUNT failed"
    save_state "HARVEST_SIZE" "$total_size" 2>/dev/null || log_warn "save_state HARVEST_SIZE failed"

    log_info "----------------------------"
    log_info ""

    # Critical: always return 0 so analysis is informational only
    return 0
}

compress_harvest() {
    log_info "Compressing harvest data..."

    [[ ! -d "$HARVEST_DIR" ]] && { log_error "Harvest directory not found: $HARVEST_DIR"; return 1; }

    local file_count
    file_count=$(find "$HARVEST_DIR" -type f 2>/dev/null | wc -l)
    [[ $file_count -eq 0 ]] && { log_warn "No files to compress in harvest directory"; return 1; }

    local archive_name="pegasus_data_$(basename "$HARVEST_DIR").tar.gz"
    local archive_path="/tmp/${archive_name}"

    log_info "Creating archive: $archive_path"
    log_info "Compressing $file_count files..."

    if tar -czf "$archive_path" -C "$(dirname "$HARVEST_DIR")" "$(basename "$HARVEST_DIR")" 2>>"$LOG_FILE"; then
        local archive_size
        archive_size=$(du -sh "$archive_path" 2>/dev/null | awk '{print $1}' || echo 'N/A')

        log_info "SUCCESS: Archive created ($archive_size)"
        log_info "Archive path: $archive_path"

        save_state "HARVEST_ARCHIVE" "$archive_path" 2>/dev/null || log_warn "save_state HARVEST_ARCHIVE failed"
        save_state "HARVEST_ARCHIVE_SIZE" "$archive_size" 2>/dev/null || log_warn "save_state HARVEST_ARCHIVE_SIZE failed"

        # ONLY output the path, no extra text
        echo "$archive_path"
        return 0
    else
        log_error "Failed to create archive"
        return 1
    fi
}

################################################################################
# EXPORT FUNCTIONS
################################################################################

export -f prepare_harvest_directory
export -f launch_pegasus shutdown_pegasus
export -f run_harvest_with_retry run_single_pegasus_harvest
export -f verify_harvest_success analyze_harvest_data compress_harvest
