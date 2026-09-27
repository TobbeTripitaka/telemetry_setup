#!/usr/bin/env bash
# Configuration is DATA, never shell code. No source, eval or interpolation.
trim() {
    local value=$1
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

read_kv() {
    local file=$1 callback=$2 line key value
    local -A seen=()
    [[ -f $file && $(stat -c %s -- "$file") -le 32768 ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        line=$(trim "$line")
        [[ -z $line || $line == \#* ]] && continue
        [[ $line == *=* ]] || return 1
        key=$(trim "${line%%=*}")
        value=$(trim "${line#*=}")
        [[ $key =~ ^([A-Z][A-Z0-9_]*|station)$ && -z ${seen[$key]+yes} ]] || return 1
        seen[$key]=1
        # Optional literal wrapping quotes, without escape/variable expansion.
        if [[ $value == \"*\" || $value == \'*\' ]]; then value=${value:1:${#value}-2}; fi
        [[ $value != *$'\n'* && $value != *$'\r'* ]] || return 1
        "$callback" "$key" "$value" || return 1
    done <"$file"
}

node_key() {
    local key=$1 value=$2
    case "$key" in
        RCLONE_REMOTE|RECORDER_SERIAL)
            [[ $value =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 1 ;;
        station|STATION_NAME)
            die "Set station in /etc/tele/config.txt, not node.conf"
            return 1 ;;
        DROPBOX_ROOT)
            [[ $value =~ ^[A-Za-z0-9_./-]*$ && /$value/ != *'/../'* ]] || return 1
            value=${value#/}; value=${value%/} ;;
        PEGASUS_BIN|RCLONE_CONFIG|RECORDER_DEVICE)
            [[ $value == /* && $value != *$'\t'* ]] || return 1 ;;
        VNC_SERVICE)
            [[ $value =~ ^tele-vnc@[a-zA-Z0-9_-]+\.service$ ]] || return 1 ;;
        VNC_PORT)
            integer_between "$value" 5900 5999 || return 1 ;;
        *) return 1 ;;
    esac
    printf -v "$key" '%s' "$value"
}

integer_between() {
    [[ $1 =~ ^(0|[1-9][0-9]{0,7})$ ]] && (( $1 >= $2 && $1 <= $3 ))
}

load_node_config() {
    local file=$1
    check_private_file "$file" || { die "Unsafe node configuration"; return 1; }
    STATION_NAME='' RCLONE_REMOTE='' RECORDER_SERIAL='' RECORDER_DEVICE=''
    DROPBOX_ROOT='' VNC_SERVICE=tele-vnc@tele.service VNC_PORT=5901
    PEGASUS_BIN=/opt/PegasusHarvester/resources/app/node_modules/@nanometrics/pegasus-harvest-lib/build/Release/harvester
    RCLONE_CONFIG=/etc/tele/rclone.conf
    read_kv "$file" node_key || { die "Invalid node configuration"; return 1; }
    [[ -n $RCLONE_REMOTE && -n $RECORDER_SERIAL &&
       $RECORDER_DEVICE == /dev/disk/by-id/* && $RECORDER_DEVICE != *-part[0-9]* ]] ||
        { die "Remote, recorder serial and whole-disk by-id path required"; return 1; }
}

runtime_defaults() {
    station=''
    EXECUTE=auto
    HARVEST_MODE=incremental
    REQUEST_ID=''
    FROM_DATE='' TO_DATE=''
    MAINTENANCE_IDLE_SECONDS=600
    HARVEST_BUDGET_SECONDS=3600
    NETWORK_TIMEOUT_SECONDS=300
    RETAIN_LAST_BATCH=yes
    MIN_FREE_MIB=2048
    OVERLAP_DAYS=2
}

runtime_key() {
    local key=$1 value=$2
    case "$key" in
        station) valid_station "$value" || return 1 ;;
        EXECUTE) [[ $value =~ ^(auto|ssh|vnc)$ ]] || return 1 ;;
        HARVEST_MODE) [[ $value =~ ^(incremental|reconcile|reupload|range)$ ]] || return 1 ;;
        REQUEST_ID) [[ $value =~ ^[A-Za-z0-9_.-]{1,80}$ ]] || return 1 ;;
        FROM_DATE|TO_DATE)
            [[ $value =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]] &&
                [[ $(date -u -d "$value" +%F 2>/dev/null) == "$value" ]] || return 1 ;;
        MAINTENANCE_IDLE_SECONDS) integer_between "$value" 0 3600 || return 1 ;;
        HARVEST_BUDGET_SECONDS) integer_between "$value" 1 3600 || return 1 ;;
        NETWORK_TIMEOUT_SECONDS) integer_between "$value" 10 600 || return 1 ;;
        RETAIN_LAST_BATCH) [[ $value =~ ^(yes|no)$ ]] || return 1 ;;
        MIN_FREE_MIB) integer_between "$value" 256 1048576 || return 1 ;;
        OVERLAP_DAYS) integer_between "$value" 1 30 || return 1 ;;
        *) return 1 ;;
    esac
    printf -v "$key" '%s' "$value"
}

validate_runtime() {
    valid_station "${station:-}" || { die "A valid station label is required in config.txt"; return 1; }
    if [[ -n ${1:-} && $station != "$1" ]]; then
        die "Config station '$station' does not match local station '$1'"
        return 1
    fi
    if [[ $HARVEST_MODE != incremental ]]; then [[ -n $REQUEST_ID ]] || return 1; fi
    if [[ $HARVEST_MODE == range ]]; then
        [[ -n $FROM_DATE && -n $TO_DATE && $FROM_DATE < $TO_DATE ]] || return 1
    fi
}

valid_station() {
    # One path component only. Reject empty names, traversal, shell syntax and
    # whitespace before constructing local or remote paths; preserve label case.
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]]
}

load_local_config() {
    local file=$1
    check_private_file "$file" || { die "Unsafe/missing local config.txt"; return 1; }
    # Validate in isolation before changing any live setting or deriving paths.
    (runtime_defaults; read_kv "$file" runtime_key && validate_runtime) ||
        { die "Invalid local config.txt"; return 1; }
    runtime_defaults
    read_kv "$file" runtime_key || return 1
    validate_runtime || return 1
    STATION_NAME=$station
}

load_runtime_config() {
    # Local config must be loaded before remote discovery: config.txt itself is
    # inside that station's Dropbox folder. Remote settings cannot redirect it.
    [[ -n ${STATION_NAME:-} ]] && validate_runtime "$STATION_NAME" ||
        { die "Load local station configuration before remote settings"; return 1; }
    local cache="$STATE_ROOT/config.txt" temp
    temp=$(mktemp "$STATE_ROOT/config.XXXXXX") || return 1
    # Local settings are already active, including a bounded network timeout.
    if cloud copyto "$REMOTE_BASE/config.txt" "$temp" >>"$LOG_FILE" 2>&1 &&
       (runtime_defaults; read_kv "$temp" runtime_key && validate_runtime "$STATION_NAME"); then
        atomic_install "$temp" "$cache" || return 1
    else
        log "Remote config missing/invalid; using matching cached config or local settings"
        rm -f -- "$temp"
    fi
    if [[ -f $cache ]]; then
        # Parse in a subshell first so an invalid file cannot partly change settings.
        if (runtime_defaults; read_kv "$cache" runtime_key && validate_runtime "$STATION_NAME"); then
            runtime_defaults
            read_kv "$cache" runtime_key || return 1
            validate_runtime "$STATION_NAME" || return 1
        else
            log "Cached configuration invalid or belongs to another station; using local settings"
        fi
    fi
    log "station=$STATION_NAME mode=$HARVEST_MODE post-run=$EXECUTE harvest-budget=${HARVEST_BUDGET_SECONDS}s"
}

credential_key() {
    local key=$1 value=$2
    case "$key" in
        EMAIL_TO|EMAIL_FROM)
            [[ $value =~ ^[A-Za-z0-9_.+%-]+@[A-Za-z0-9.-]+$ ]] || return 1 ;;
        EMAIL_PASSWORD) [[ -n $value ]] || return 1 ;;
        *) return 1 ;;
    esac
    printf -v "$key" '%s' "$value"
}

load_credentials() {
    EMAIL_TO='' EMAIL_FROM='' EMAIL_PASSWORD=''
    if ! check_private_file "$1" || ! read_kv "$1" credential_key; then
        EMAIL_PASSWORD=''
        log "Email credentials unavailable/invalid; data collection will continue"
    fi
    return 0
}
