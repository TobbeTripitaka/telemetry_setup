#!/bin/bash

################################################################################
# Common Utilities Library
# Shared functions used across all modules
################################################################################

# Prevent multiple sourcing
[[ -n "${_COMMON_LIB_LOADED:-}" ]] && return 0
readonly _COMMON_LIB_LOADED=1

################################################################################
# LOGGING FUNCTIONS
################################################################################

# Log levels
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3
readonly LOG_LEVEL_FATAL=4

# Current log level (can be overridden)
LOG_LEVEL=${LOG_LEVEL:-$LOG_LEVEL_INFO}

# Initialize log file with header
init_log_file() {
    local log_file="$1"
    
    {
        echo "========================================================================"
        echo "TELE1 Data Collection and Upload Log"
        echo "========================================================================"
        echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Hostname: $(hostname)"
        echo "User: $(whoami)"
        echo "Script: ${BASH_SOURCE[1]}"
        echo "========================================================================"
        echo ""
    } > "$log_file"
}

# Generic log function
log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    local log_line="$timestamp [$level] $message"
    
    # Write to log file if LOG_FILE is set
    if [[ -n "${LOG_FILE:-}" ]]; then
    echo "$log_line" >> "$LOG_FILE" 2>/dev/null || true
    fi

    
    # Also echo to console
    echo "$log_line"
}

# Convenience functions for different log levels
log_debug() {
    # Best-effort only: never let debug logging abort the script
    {
        [[ ${LOG_LEVEL:-$LOG_LEVEL_INFO} -le $LOG_LEVEL_DEBUG ]] && log_message "DEBUG" "$1"
    } || true
}

log_info() {
    [[ $LOG_LEVEL -le $LOG_LEVEL_INFO ]] && log_message "INFO" "$1"
}

log_warn() {
    [[ $LOG_LEVEL -le $LOG_LEVEL_WARN ]] && log_message "WARN" "$1"
}

log_error() {
    [[ $LOG_LEVEL -le $LOG_LEVEL_ERROR ]] && log_message "ERROR" "$1"
}

log_fatal() {
    log_message "FATAL" "$1"
}

################################################################################
# RETRY AND TIMEOUT FUNCTIONS
################################################################################

# Generic retry function with exponential backoff
# Usage: retry_with_timeout <max_attempts> <base_delay> <timeout> <command> [args...]
retry_with_timeout() {
    local max_attempts="$1"
    local base_delay="$2"
    local timeout="$3"
    shift 3
    local command=("$@")
    
    local attempt=1
    local delay="$base_delay"
    
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Attempt $attempt of $max_attempts: ${command[*]}"
        
        if timeout "$timeout" "${command[@]}"; then
            log_info "Command succeeded on attempt $attempt"
            return 0
        else
            local exit_code=$?
            log_warn "Command failed on attempt $attempt (exit code: $exit_code)"
            
            if [[ $attempt -lt $max_attempts ]]; then
                log_info "Waiting ${delay}s before retry..."
                sleep "$delay"
                # Exponential backoff
                delay=$((delay * 2))
            fi
        fi
        
        ((attempt++))
    done
    
    log_error "Command failed after $max_attempts attempts"
    return 1
}

################################################################################
# DEPENDENCY CHECKING
################################################################################

# Check if a command/binary exists
check_command() {
    local cmd="$1"
    
    if command -v "$cmd" &> /dev/null; then
        log_debug "Command found: $cmd"
        return 0
    else
        log_error "Required command not found: $cmd"
        return 1
    fi
}

# Check if a file/directory exists
check_path() {
    local path="$1"
    local type="${2:-file}"  # file or directory
    
    if [[ "$type" == "directory" ]]; then
        if [[ -d "$path" ]]; then
            log_debug "Directory exists: $path"
            return 0
        else
            log_error "Required directory not found: $path"
            return 1
        fi
    else
        if [[ -f "$path" ]]; then
            log_debug "File exists: $path"
            return 0
        else
            log_error "Required file not found: $path"
            return 1
        fi
    fi
}

# Check all system dependencies
check_dependencies() {
    log_info "Checking system dependencies..."
    
    local all_ok=0
    local required_commands=(
        "curl"
        "tar"
        "gzip"
        "node"
        "timeout"
        "jq"
        "lsusb"
    )
    
    for cmd in "${required_commands[@]}"; do
        if ! check_command "$cmd"; then
            all_ok=1
        fi
    done
    
    # Check required paths
    if ! check_path "$DROPBOX_SCRIPT" "file"; then
        all_ok=1
    fi
    
    if ! check_path "$PEGASUS_BIN" "file"; then
        all_ok=1
    fi
    
    # Check JavaScript files
    if ! check_path "${JS_DIR}/starlink_get_json.js" "file"; then
        log_warn "Starlink diagnostics script not found (non-critical)"
    fi
    
    if [[ $all_ok -eq 0 ]]; then
        log_info "All dependencies satisfied"
        return 0
    else
        log_error "Some dependencies are missing"
        return 1
    fi
}

################################################################################
# STATE MANAGEMENT
################################################################################

# Save a state variable to the state file
save_state() {

    local key="$1"
    local value="$2"

    if [[ -z "${STATE_FILE:-}" ]]; then
        # Don't break the run if state file isn't configured yet
        log_warn "STATE_FILE not defined, cannot save state (key=${key})"
        return 0
    fi

    # Create state file if it doesn't exist
    touch "$STATE_FILE" 2>/dev/null || {
        log_warn "Cannot touch state file ${STATE_FILE} (key=${key})"
        return 0
    }

    # Remove old value if exists, then append new value
    grep -v "^${key}=" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
    echo "${key}=${value}" >> "${STATE_FILE}.tmp"

    # Do not let mv failure kill the whole script
    if ! mv "${STATE_FILE}.tmp" "$STATE_FILE" 2>/dev/null; then
        log_warn "Failed to update state file ${STATE_FILE} (key=${key})"
        return 0
    fi

    log_debug "State saved: ${key}=${value}"
}


# Get a state variable from the state file
get_state() {
    local key="$1"
    local default="${2:-}"
    
    if [[ -z "${STATE_FILE:-}" ]] || [[ ! -f "$STATE_FILE" ]]; then
        echo "$default"
        return 0
    fi
    
    local value
    value=$(grep "^${key}=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2-)
    
    if [[ -n "$value" ]]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# Clear the state file (start fresh)
clear_state() {
    if [[ -n "${STATE_FILE:-}" ]]; then
        rm -f "$STATE_FILE"
        log_info "State file cleared"
    fi
}

################################################################################
# CLEANUP FUNCTIONS
################################################################################

# Global cleanup function called on exit
cleanup_on_exit() {
    local exit_code=$?
    
    log_info "Cleanup initiated (exit code: $exit_code)"
    
    # Kill any remaining Pegasus processes
    pkill -f "$PEGASUS_BIN" 2>/dev/null || true
    
    # Kill any remaining node processes related to our scripts
    pkill -f "starlink_get_json.js" 2>/dev/null || true
    pkill -f "pegasus_harvest.js" 2>/dev/null || true
    
    # Clean up temporary files
    cleanup_temp_files
    
    log_info "Cleanup completed"
}

# Clean up temporary files
cleanup_temp_files() {
    log_info "Cleaning up temporary files..."
    
    # Remove temporary mail files
    rm -f /tmp/mail_*.txt 2>/dev/null || true
    
    # Remove temporary archives (if not needed)
    rm -f /tmp/pegasus_data_*.tar.gz 2>/dev/null || true
    rm -f /tmp/camera_data_*.tar.gz 2>/dev/null || true
    
    # Remove timestamp markers
    rm -f /tmp/harvest_start_* 2>/dev/null || true
    
    log_debug "Temporary files cleaned"
}

################################################################################
# INPUT VALIDATION
################################################################################

# Validate that a value is within a set of allowed values
validate_enum() {
    local value="$1"
    shift
    local allowed_values=("$@")
    
    for allowed in "${allowed_values[@]}"; do
        if [[ "$value" == "$allowed" ]]; then
            return 0
        fi
    done
    
    return 1
}

# Validate that a value is a positive number
validate_positive_number() {
    local value="$1"
    
    if [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        if (( $(echo "$value > 0" | bc -l) )); then
            return 0
        fi
    fi
    
    return 1
}

# Validate date format YYYY-MM-DD HH:MM:SS
validate_datetime() {
    local datetime="$1"
    
    if [[ "$datetime" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        # Try to parse with date command
        if date -d "$datetime" &>/dev/null; then
            return 0
        fi
    fi
    
    return 1
}

################################################################################
# UTILITY FUNCTIONS
################################################################################

# Get file size in human-readable format
get_file_size() {
    local file="$1"
    
    if [[ -f "$file" ]]; then
        du -h "$file" | awk '{print $1}'
    else
        echo "0"
    fi
}

# Count files in directory
count_files() {
    local dir="$1"
    
    if [[ -d "$dir" ]]; then
        find "$dir" -type f 2>/dev/null | wc -l
    else
        echo "0"
    fi
}

# Get directory size in human-readable format
get_dir_size() {
    local dir="$1"
    
    if [[ -d "$dir" ]]; then
        du -sh "$dir" 2>/dev/null | awk '{print $1}'
    else
        echo "0"
    fi
}

# Prompt user for yes/no with timeout
prompt_yes_no() {
    local prompt="$1"
    local timeout_seconds="${2:-60}"
    local default="${3:-N}"
    
    echo ""
    echo "$prompt (Y/N)"
    echo "Auto-selecting '$default' in ${timeout_seconds} seconds..."
    
    if read -t "$timeout_seconds" -n 1 -p "Enter choice: " response; then
        echo ""
        case "$response" in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
            *)
                echo "Invalid choice, using default: $default"
                [[ "$default" == "Y" ]] && return 0 || return 1
                ;;
        esac
    else
        echo ""
        echo "Timeout - using default: $default"
        [[ "$default" == "Y" ]] && return 0 || return 1
    fi
}

# Shutdown prompt (called at end of main script)
prompt_for_shutdown() {
    local auto_shutdown="${1:-false}"  # Optional parameter for auto-shutdown

    log_info "Process completed"

    if [[ "$auto_shutdown" == "true" ]]; then
        log_info "Auto-shutdown enabled - powering down in 10 seconds..."
        echo "=========================================="
        echo "AUTO-SHUTDOWN MODE"
        echo "System will power down in 10 seconds"
        echo "Press Ctrl+C to cancel"
        echo "=========================================="
        sleep 10
        log_info "Executing automatic shutdown"
        sudo poweroff
    else
        # Interactive mode
        if prompt_yes_no "Do you want to power down?" 120 "Y"; then
            log_info "User selected shutdown"
            echo "Powering down in 5 seconds..."
            sleep 5
            sudo poweroff
        else
            log_info "User chose to remain in terminal"
            echo "Remaining in terminal..."
            exec bash
        fi
    fi
}


################################################################################
# EXPORT FUNCTIONS
################################################################################

# Make functions available to other scripts
export -f log_message log_debug log_info log_warn log_error log_fatal
export -f retry_with_timeout check_command check_path check_dependencies
export -f save_state get_state clear_state
export -f cleanup_on_exit cleanup_temp_files
export -f validate_enum validate_positive_number validate_datetime
export -f get_file_size count_files get_dir_size
export -f prompt_yes_no prompt_for_shutdown
