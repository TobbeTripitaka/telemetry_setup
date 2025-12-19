#!/bin/bash

################################################################################
# Configuration Management Library
# Functions for downloading, parsing, and validating configuration
################################################################################

# Prevent multiple sourcing
[[ -n "${_CONFIG_LIB_LOADED:-}" ]] && return 0
readonly _CONFIG_LIB_LOADED=1

################################################################################
# CONFIGURATION VARIABLES (with defaults)
################################################################################

# Execution mode
EXECUTE="auto"                    # Options: auto, vnc
WAIT_TIME=2                       # Hours to wait for VNC connection
AFTER_WAIT="auto"                 # Options: auto, power off
HARVEST_MODE="since last"         # Options: all, since last, date range
FROM_DATE="2000-01-01 00:00:00"  # For date range mode
TO_DATE="2050-12-31 23:59:59"    # For date range mode

# Config download status
CONFIG_DOWNLOAD_SUCCESS=0

################################################################################
# CONFIGURATION DOWNLOAD
################################################################################

# Download config.txt from Dropbox
download_config() {
    log_info "Downloading configuration from Dropbox..."
    
    local config_remote_path="/config.txt"
    local config_local_path="${CONFIG_DIR}/config.txt"
    local max_attempts=3
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Config download attempt $attempt of $max_attempts"
        
        if timeout 60 "$DROPBOX_SCRIPT" download "$config_remote_path" "$config_local_path" >> "$LOG_FILE" 2>&1; then
            log_info "SUCCESS: Config file downloaded"
            CONFIG_DOWNLOAD_SUCCESS=1
            
            # Log config file size
            local config_size
            config_size=$(wc -c < "$config_local_path" 2>/dev/null || echo "0")
            log_info "Config file size: $config_size bytes"
            
            return 0
        else
            log_warn "FAILED: Config download attempt $attempt"
            
            if [[ $attempt -lt $max_attempts ]]; then
                log_info "Waiting 10 seconds before retry..."
                sleep 10
            fi
        fi
        
        ((attempt++))
    done
    
    log_error "Failed to download config after $max_attempts attempts"
    CONFIG_DOWNLOAD_SUCCESS=0
    return 1
}

# Load default configuration
load_default_config() {
    log_info "Loading default configuration..."
    
    local default_config="${CONFIG_DIR}/config.defaults"
    local config_local_path="${CONFIG_DIR}/config.txt"
    
    # Check if defaults file exists
    if [[ -f "$default_config" ]]; then
        log_info "Copying default config from: $default_config"
        cp "$default_config" "$config_local_path"
        return 0
    else
        log_warn "No default config file found, using hardcoded defaults"
        # Create a minimal config file with defaults
        cat > "$config_local_path" <<EOF
# Default configuration (auto-generated)
EXECUTE = auto
WAIT_TIME = 2
AFTER_WAIT = auto
HARVEST_MODE = since last
FROM_DATE = 2000-01-01 00:00:00
TO_DATE = 2050-12-31 23:59:59
EOF
        return 0
    fi
}

################################################################################
# CONFIGURATION PARSING
################################################################################

# Parse time value (supports hours with optional 'h' suffix)
parse_time_value() {
    local input="$1"
    
    # Remove spaces and convert to lowercase
    input=$(echo "$input" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    
    # Remove 'h', 'hr', 'hours' suffix if present
    input=$(echo "$input" | sed 's/h.*$//')
    
    echo "$input"
}

# Parse and validate configuration file
parse_and_validate_config() {
    log_info "Parsing configuration file..."
    
    local config_file="${CONFIG_DIR}/config.txt"
    
    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration file not found: $config_file"
        return 1
    fi
    
    # Track keys we've seen (to detect duplicates)
    declare -A config_keys_seen
    local validation_errors=0
    
    # Read config file line by line
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Remove leading/trailing whitespace
        line=$(echo "$line" | xargs)
        
        # Skip empty lines and comments
        if [[ -z "$line" ]] || [[ "$line" =~ ^#.* ]]; then
            continue
        fi
        
        # Extract key-value pairs
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            
            # Convert key to uppercase for consistency
            local key_upper
            key_upper=$(echo "$key" | tr '[:lower:]' '[:upper:]')
            
            # Remove trailing comments from value
            value=$(echo "$value" | sed 's/[[:space:]]*#.*$//')
            value=$(echo "$value" | xargs)
            
            # Check for duplicate keys
            if [[ -n "${config_keys_seen[$key_upper]:-}" ]]; then
                log_warn "Duplicate key '$key_upper' found, using last occurrence"
            fi
            config_keys_seen["$key_upper"]=1
            
            # Warn if case doesn't match exactly
            if [[ "$key" != "$key_upper" ]]; then
                log_warn "Key '$key' should be uppercase: '$key_upper'"
            fi
            
            # Process each configuration variable
            case "$key_upper" in
                "EXECUTE")
                    if validate_execute_value "$value"; then
                        EXECUTE="$value"
                        log_info "Config: EXECUTE = '$EXECUTE'"
                    else
                        log_error "Invalid EXECUTE value: '$value'"
                        ((validation_errors++))
                    fi
                    ;;
                    
                "WAIT_TIME")
                    local parsed_time
                    parsed_time=$(parse_time_value "$value")
                    if validate_positive_number "$parsed_time"; then
                        WAIT_TIME="$parsed_time"
                        log_info "Config: WAIT_TIME = $WAIT_TIME hours"
                    else
                        log_error "Invalid WAIT_TIME value: '$value'"
                        ((validation_errors++))
                    fi
                    ;;
                    
                "AFTER_WAIT")
                    if validate_after_wait_value "$value"; then
                        AFTER_WAIT="$value"
                        log_info "Config: AFTER_WAIT = '$AFTER_WAIT'"
                    else
                        log_error "Invalid AFTER_WAIT value: '$value'"
                        ((validation_errors++))
                    fi
                    ;;
                    
                "HARVEST_MODE")
                    if validate_harvest_mode_value "$value"; then
                        HARVEST_MODE="$value"
                        log_info "Config: HARVEST_MODE = '$HARVEST_MODE'"
                    else
                        log_error "Invalid HARVEST_MODE value: '$value'"
                        ((validation_errors++))
                    fi
                    ;;
                    
                "FROM_DATE")
                    if validate_datetime "$value"; then
                        FROM_DATE="$value"
                        log_info "Config: FROM_DATE = '$FROM_DATE'"
                    else
                        log_error "Invalid FROM_DATE value: '$value'"
                        ((validation_errors++))
                    fi
                    ;;
                    
                "TO_DATE")
                    if validate_datetime "$value"; then
                        TO_DATE="$value"
                        log_info "Config: TO_DATE = '$TO_DATE'"
                    else
                        log_error "Invalid TO_DATE value: '$value'"
                        ((validation_errors++))
                    fi
                    ;;
                    
                *)
                    log_warn "Unknown configuration key: '$key_upper' (ignored)"
                    ;;
            esac
        fi
    done < "$config_file"
    
    if [[ $validation_errors -gt 0 ]]; then
        log_error "Configuration validation failed with $validation_errors errors"
        return 1
    fi
    
    log_info "Configuration parsed and validated successfully"
    return 0
}

################################################################################
# CONFIGURATION VALIDATION
################################################################################

# Validate EXECUTE parameter
validate_execute_value() {
    local value="$1"
    local value_lower
    value_lower=$(echo "$value" | tr '[:upper:]' '[:lower:]')
    
    validate_enum "$value_lower" "auto" "vnc"
}

# Validate AFTER_WAIT parameter
validate_after_wait_value() {
    local value="$1"
    local value_normalized
    value_normalized=$(echo "$value" | tr '[:upper:]' '[:lower:]' | sed 's/  */ /g')
    
    validate_enum "$value_normalized" "auto" "power off"
}

# Validate HARVEST_MODE parameter
validate_harvest_mode_value() {
    local value="$1"
    local value_normalized
    value_normalized=$(echo "$value" | tr '[:upper:]' '[:lower:]' | sed 's/  */ /g')
    
    validate_enum "$value_normalized" "all" "since last" "date range"
}

################################################################################
# CONFIGURATION APPLICATION
################################################################################

# Apply configuration settings (make available globally)
apply_config() {
    log_info "Applying configuration settings..."

    # Export variables so they're available to other scripts
    export EXECUTE
    export WAIT_TIME
    export AFTER_WAIT
    export HARVEST_MODE
    export FROM_DATE
    export TO_DATE

    log_info "Save to state file for reference."


    # Save to state file for reference
    save_state "CONFIG_EXECUTE" "$EXECUTE"
    save_state "CONFIG_WAIT_TIME" "$WAIT_TIME"
    save_state "CONFIG_AFTER_WAIT" "$AFTER_WAIT"
    save_state "CONFIG_HARVEST_MODE" "$HARVEST_MODE"
    save_state "CONFIG_FROM_DATE" "$FROM_DATE"
    save_state "CONFIG_TO_DATE" "$TO_DATE"

    log_debug "Configuration applied successfully"
}

# Display current configuration
display_config() {
    log_info ""
    log_info "Current Configuration:"
    log_info "====================="
    log_info "EXECUTE      = '$EXECUTE'"
    log_info "WAIT_TIME    = $WAIT_TIME hours"
    log_info "AFTER_WAIT   = '$AFTER_WAIT'"
    log_info "HARVEST_MODE = '$HARVEST_MODE'"
    log_info "FROM_DATE    = '$FROM_DATE'"
    log_info "TO_DATE      = '$TO_DATE'"
    log_info "====================="
    log_info ""
}

################################################################################
# VNC MODE HANDLING (FUTURE IMPLEMENTATION)
################################################################################

# Handle VNC remote desktop mode
handle_vnc_mode() {
    local wait_hours="$1"
    
    log_info "VNC mode enabled"
    log_info "Waiting up to $wait_hours hours for VNC connection..."
    
    # FUTURE IMPLEMENTATION:
    # This function will:
    # 1. Start VNC server if not already running
    # 2. Wait for client connection with timeout
    # 3. Keep session alive while connected
    # 4. Proceed with script after disconnection or timeout
    #
    # Example implementation outline:
    # - Start VNC: vncserver :1 -geometry 1920x1080 -depth 24
    # - Monitor for connection: netstat or vnc logs
    # - Wait loop with timeout: sleep in intervals, check connection
    # - Clean up: vncserver -kill :1
    #
    # Security considerations:
    # - Use SSH tunneling for VNC connection
    # - Set strong VNC password
    # - Limit connection time
    
    log_warn "VNC mode not yet implemented (stub function)"
    log_info "Proceeding with automated execution..."
    
    return 0
}

################################################################################
# EXPORT FUNCTIONS
################################################################################

export -f download_config load_default_config
export -f parse_and_validate_config apply_config display_config
export -f validate_execute_value validate_after_wait_value validate_harvest_mode_value
export -f handle_vnc_mode
