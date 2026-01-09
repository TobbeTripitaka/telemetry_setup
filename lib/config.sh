#!/bin/bash

################################################################################
# Configuration Management Library
# Functions for downloading, parsing, and validating configuration
# Tobias Stål 2025
################################################################################

################################################################################
# CONFIGURATION VARIABLES (with defaults)
################################################################################

# Execution mode
EXECUTE="${EXECUTE:-auto}"          # Options: auto, vnc
WAIT_TIME="${WAIT_TIME:-2}"         # Hours to wait for VNC connection
AFTER_WAIT="${AFTER_WAIT:-auto}"    # Options: auto, power off

HARVEST_MODE="${HARVEST_MODE:-since last}"  # Options: all, since last, date range

# Use ISO-style defaults (T separator)
FROM_DATE="${FROM_DATE:-2000-01-01T00:00:00}"   # For date range mode
TO_DATE="${TO_DATE:-2050-12-31T23:59:59}"       # For date range mode

# Hours to keep SSH window open after run before power down
WAIT_TIME_SSH="${WAIT_TIME_SSH:-2}"

# Config download status
CONFIG_DOWNLOAD_SUCCESS=0

################################################################################
# CONFIGURATION DOWNLOAD
################################################################################

download_config() {
    log_info "Downloading configuration from ${RCLONE_REMOTE}:/ ..."
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
            CONFIG_DOWNLOAD_SUCCESS=1

            local config_size
            config_size=$(wc -c < "$config_local_path" 2>/dev/null || echo "0")
            log_info "Config file size: $config_size bytes"
            return 0
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
    CONFIG_DOWNLOAD_SUCCESS=0
    return 1
}

################################################################################
# DEFAULT CONFIG
################################################################################

load_default_config() {
    log_info "Loading default configuration..."
    local default_config="${CONFIG_DIR}/config.defaults"
    local config_local_path="${CONFIG_DIR}/config.txt"

    if [[ -f "$default_config" ]]; then
        log_info "Copying default config from: $default_config"
        cp "$default_config" "$config_local_path"
        return 0
    else
        log_warn "No default config file found, using hardcoded defaults"
        if ! cat > "$config_local_path" <<EOF
# Empty config – using built-in defaults
EOF
        then
            log_error "Failed to create default config file at $config_local_path"
            return 1
        fi
    fi
}

################################################################################
# INTERNAL HELPERS
################################################################################

# Normalise a datetime string:
# - Accept "YYYY-MM-DD HH:MM:SS" or "YYYY-MM-DDTHH:MM:SS"
# - Return canonical "YYYY-MM-DDTHH:MM:SS"
_normalise_datetime_iso() {
    local input="$1"

    # Trim whitespace
    input="$(echo "$input" | xargs)"

    # Replace single space separator with 'T'
    input="${input/ /T}"

    # Validate: strict 4-2-2 T 2:2:2 digits
    if [[ "$input" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        printf '%s\n' "$input"
        return 0
    fi

    return 1
}

################################################################################
# CONFIG PARSING & VALIDATION
################################################################################

parse_and_validate_config() {
    local config_file="${CONFIG_DIR}/config.txt"

    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration file not found: $config_file"
        return 1
    fi

    log_info "Parsing configuration..."
    log_info "Sourcing configuration file: $config_file"

    # Source key=value pairs (user config) into environment
    # shellcheck disable=SC1090
    source "$config_file"

    local error_count=0

    # ---- EXECUTION MODE ----
    case "${EXECUTE,,}" in
        auto|vnc|ssh|clear)
            ;;
        *)
            log_warn "Invalid EXECUTE value: $EXECUTE (expected: auto|vnc|ssh|clear), using default: auto"
            EXECUTE="auto"
            ((error_count++))
            ;;
    esac

    # WAIT_TIME must be numeric (hours)
    if ! [[ "$WAIT_TIME" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        log_warn "Invalid WAIT_TIME value: $WAIT_TIME (expected numeric hours), using default: 2"
        WAIT_TIME="2"
        ((error_count++))
    fi

    # AFTER_WAIT
    case "${AFTER_WAIT,,}" in
        auto|"power off")
            ;;
        *)
            log_warn "Invalid AFTER_WAIT value: $AFTER_WAIT (expected: auto|power off), using default: auto"
            AFTER_WAIT="auto"
            ((error_count++))
            ;;
    esac

    # ---- HARVEST MODE ----
    case "${HARVEST_MODE,,}" in
        "all"|"since last"|"date range")
            ;;
        *)
            log_warn "Invalid HARVEST_MODE: $HARVEST_MODE (expected: all|since last|date range), using default: since last"
            HARVEST_MODE="since last"
            ((error_count++))
            ;;
    esac

    # ---- DATE RANGE ----
    if [[ "${HARVEST_MODE,,}" == "date range" ]]; then
        local from_normalised to_normalised

        from_normalised=$(_normalise_datetime_iso "$FROM_DATE") || {
            log_warn "Invalid FROM_DATE format: $FROM_DATE (expected: YYYY-MM-DD[ T]HH:MM:SS), using default"
            from_normalised="2000-01-01T00:00:00"
            ((error_count++))
        }

        to_normalised=$(_normalise_datetime_iso "$TO_DATE") || {
            log_warn "Invalid TO_DATE format: $TO_DATE (expected: YYYY-MM-DD[ T]HH:MM:SS), using default"
            to_normalised="2050-12-31T23:59:59"
            ((error_count++))
        }

        # Basic logical check using GNU date if available
        if command -v date >/dev/null 2>&1; then
            local from_epoch to_epoch
            from_epoch=$(date -d "$from_normalised" +%s 2>/dev/null || echo "")
            to_epoch=$(date -d "$to_normalised" +%s 2>/dev/null || echo "")
            if [[ -n "$from_epoch" && -n "$to_epoch" ]]; then
                if (( from_epoch >= to_epoch )); then
                    log_warn "FROM_DATE must be before TO_DATE (FROM=$from_normalised, TO=$to_normalised), resetting to defaults"
                    from_normalised="2000-01-01T00:00:00"
                    to_normalised="2050-12-31T23:59:59"
                    ((error_count++))
                fi
            else
                log_warn "Failed to parse dates with system 'date', resetting to defaults"
                from_normalised="2000-01-01T00:00:00"
                to_normalised="2050-12-31T23:59:59"
                ((error_count++))
            fi
        fi

        # Commit normalised ISO strings back to globals for JS
        FROM_DATE="$from_normalised"
        TO_DATE="$to_normalised"
    else
        # Not using date range; still normalise any user-provided values for consistency
        local maybe_from maybe_to
        maybe_from=$(_normalise_datetime_iso "$FROM_DATE") && FROM_DATE="$maybe_from"
        maybe_to=$(_normalise_datetime_iso "$TO_DATE") && TO_DATE="$maybe_to"
    fi

    # WAIT_TIME_SSH must be numeric (hours)
    if ! [[ "$WAIT_TIME_SSH" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        log_warn "Invalid WAIT_TIME_SSH value: $WAIT_TIME_SSH (expected numeric hours), using default: 2"
        WAIT_TIME_SSH="2"
        ((error_count++))
    fi

    if (( error_count > 0 )); then
        log_warn "Configuration had $error_count issue(s), but will proceed with corrected values"
    fi

    return 0
}

################################################################################
# APPLY & DISPLAY CONFIG
################################################################################

apply_config() {
    export EXECUTE WAIT_TIME AFTER_WAIT
    export HARVEST_MODE FROM_DATE TO_DATE
    export WAIT_TIME_SSH
    log_info "Configuration applied to environment"
}



display_config() {
    log_info ""
    log_info "==============================="
    log_info "Configuration Summary"
    log_info "==============================="
    log_info "EXECUTE: $EXECUTE"
    log_info "AFTER_WAIT: $AFTER_WAIT"
    log_info "HARVEST_MODE: $HARVEST_MODE"
    log_info "FROM_DATE: $FROM_DATE"
    log_info "TO_DATE: $TO_DATE"
    log_info "WAIT_TIME_SSH: $WAIT_TIME_SSH"
    log_info "Config download status: $( [[ $CONFIG_DOWNLOAD_SUCCESS -eq 1 ]] && echo SUCCESS || echo FAILED )"
    log_info "==============================="
    log_info ""
}
