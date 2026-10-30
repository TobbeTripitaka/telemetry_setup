#!/usr/bin/env bash
# A provider is trusted code in modules/. Profiles are private DATA files.
source_setting() {
    local key=$1 value=$2
    SOURCE_SETTINGS["$key"]=$value
}

discover_sources() {
    SOURCE_FILES=()
    local file
    SOURCE_PROFILES_DIR=${SOURCE_PROFILES_DIR:-/etc/tele/sources.d}
    if [[ -d ${SOURCE_PROFILES_DIR:-/etc/tele/sources.d} ]]; then
        while IFS= read -r -d '' file; do SOURCE_FILES+=("$file"); done < <(
            find "$SOURCE_PROFILES_DIR" -mindepth 1 -maxdepth 1 -name '*.conf' -print0 | sort -z
        )
    fi
    if ((${#SOURCE_FILES[@]} > 0)); then return 0; fi
    if [[ -n ${RECORDER_DEVICE:-} ]]; then
        # Keep the existing single-recorder paths when one is configured by hand.
        SOURCE_FILES=('@single-pegasus')
    else
        discover_recorders
    fi
}

discover_recorders() {
    # Automatic mode: every attached recorder gets its own state and its own
    # Dropbox subfolder named by its serial number, so swapping recorders is safe.
    # Recorders that are gone but still hold unuploaded batches are drained too.
    local serial link dir id
    local -A found=()
    while IFS=$'\t' read -r serial link; do
        [[ -n $serial ]] || continue
        SOURCE_FILES+=("@auto:$serial:$link")
        found[${serial,,}]=1
    done < <(detect_recorders)
    if [[ -d ${STATION_STATE_ROOT:-/nonexistent}/sources ]]; then
        while IFS= read -r -d '' dir; do
            id=$(basename -- "$dir")
            [[ -z ${found[${id,,}]+yes} ]] || continue
            valid_station "$id" || continue
            if find "$dir/pending" -mindepth 1 -maxdepth 1 -type d \
                \( -name '20??-??-??' -o -name '.partial-*' \) -print -quit 2>/dev/null | grep -q .; then
                SOURCE_FILES+=("@known:$id:/dev/disk/by-id/usb-absent")
            fi
        done < <(find "$STATION_STATE_ROOT/sources" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
    fi
    ((${#SOURCE_FILES[@]} > 0)) || log "No Pegasus recorder detected on USB"
    return 0
}

validate_source_set() {
    local profile identity destination record
    local -A seen=()
    for profile in "${SOURCE_FILES[@]}"; do
        record=$(
            load_source "$profile" || exit 1
            if [[ ${SOURCE_SETTINGS[TYPE]} == pegasus ]]; then
                printf '%s\t%s' "$RECORDER_SERIAL" "$REMOTE_DATA"
            else
                printf 'provider:%s:%s\t%s' "${SOURCE_SETTINGS[TYPE]}" "$SOURCE_ID" "$REMOTE_DATA"
            fi
        ) || return 1
        IFS=$'\t' read -r identity destination <<<"$record"
        [[ -z ${seen[identity:${identity,,}]+yes} ]] ||
            { die "Duplicate source identity: $identity"; return 1; }
        [[ -z ${seen[path:${destination,,}]+yes} ]] ||
            { die "Case-insensitive source destination collision: $destination"; return 1; }
        seen[identity:${identity,,}]=1
        seen[path:${destination,,}]=1
    done
}

load_source() {
    local profile=$1 kind file target
    declare -gA SOURCE_SETTINGS=()
    SOURCE_LEGACY=no SOURCE_DRAIN_ONLY=no
    if [[ $profile == @auto:* || $profile == @known:* ]]; then
        local rest=${profile#@*:} serial
        serial=${rest%%:*}
        SOURCE_ID=$serial
        valid_station "$SOURCE_ID" || { die "Unusable recorder serial: $serial"; return 1; }
        [[ $profile != @known:* ]] || SOURCE_DRAIN_ONLY=yes
        SOURCE_SETTINGS[TYPE]=pegasus
        SOURCE_SETTINGS[RECORDER_SERIAL]=$serial
        SOURCE_SETTINGS[RECORDER_DEVICE]=${rest#*:}
    elif [[ $profile == '@single-pegasus' ]]; then
        SOURCE_ID=pegasus SOURCE_LEGACY=yes
        SOURCE_SETTINGS[TYPE]=pegasus
        SOURCE_SETTINGS[RECORDER_DEVICE]=${RECORDER_DEVICE:-}
        SOURCE_SETTINGS[RECORDER_SERIAL]=${RECORDER_SERIAL:-}
    else
        check_private_file "$profile" || { die "Unsafe source profile: $profile"; return 1; }
        SOURCE_ID=$(basename "$profile" .conf)
        valid_station "$SOURCE_ID" || return 1
        read_kv "$profile" source_setting || return 1
    fi
    kind=${SOURCE_SETTINGS[TYPE]:-}
    [[ $kind =~ ^[a-z][a-z0-9_]{0,31}$ ]] || { die "Invalid source TYPE"; return 1; }
    file="$SCRIPT_DIR/modules/$kind.sh"
    [[ -f $file && ! -L $file ]] || { die "Provider not implemented: $kind"; return 1; }
    unset -f provider_validate provider_target provider_check provider_collect
    # shellcheck source=/dev/null
    source "$file" || return 1
    local function
    for function in provider_validate provider_target provider_check provider_collect; do
        declare -F "$function" >/dev/null || { die "Provider $kind lacks $function"; return 1; }
    done
    provider_validate || return 1
    target=$(provider_target) || return 1
    [[ $target =~ ^[a-z][a-z0-9_-]*$ ]] || return 1
    if [[ $SOURCE_LEGACY == yes ]]; then
        STATE_ROOT=$STATION_STATE_ROOT
        REMOTE_DATA="$STATION_REMOTE_BASE/$target"
    else
        STATE_ROOT="$STATION_STATE_ROOT/sources/$SOURCE_ID"
        REMOTE_DATA="$STATION_REMOTE_BASE/$target/$SOURCE_ID"
    fi
    SPOOL="$STATE_ROOT/pending" VERIFIED="$STATE_ROOT/verified"
    OWNERS="$STATE_ROOT/owners" KEPT="$STATE_ROOT/kept"
    LOG_ROOT=$STATION_LOG_ROOT REMOTE_BASE=$STATION_REMOTE_BASE
    RUN_ID="$STATION_RUN_ID-$SOURCE_ID"
}

run_source() (
    # Isolation prevents one recorder's state, timestamps or driver variables
    # leaking into the next. No provider edits are needed in the main script.
    local profile=$1 action=$2
    if [[ $action != check ]]; then
        local source_deadline=$(( $(uptime_seconds) + HARVEST_BUDGET_SECONDS ))
        if [[ -z ${COLLECTION_DEADLINE:-} ]] || ((source_deadline < COLLECTION_DEADLINE)); then
            COLLECTION_DEADLINE=$source_deadline
        fi
    fi
    load_source "$profile" || exit 1
    log "Source=$SOURCE_ID provider=${SOURCE_SETTINGS[TYPE]} destination=$REMOTE_DATA"
    ensure_dirs || exit 1
    if [[ $action == check ]]; then
        if [[ $SOURCE_DRAIN_ONLY == yes ]]; then log "Recorder $SOURCE_ID is not connected"; exit 0; fi
        provider_check
    else
        check_local_storage
        if [[ $SOURCE_DRAIN_ONLY == yes ]]; then
            # Disconnected recorder: still upload anything already harvested.
            log "Recorder $SOURCE_ID is not connected; uploading pending data only"
            drain_pending
        else
            provider_collect
        fi
    fi
)

collect_all_sources() {
    log "4. Collect configured sources"
    if [[ $CLOUD_READY != yes ]]; then log "Sources skipped: Dropbox was not verified"; return 0; fi
    discover_sources && validate_source_set || { RUN_STATUS=PARTIAL; return 0; }
    if ((${#SOURCE_FILES[@]} == 0)); then
        log "WARNING: no recorder connected; nothing to collect on this boot"
        RUN_STATUS=PARTIAL
        return 0
    fi
    local profile remaining count=${#SOURCE_FILES[@]} budget=$HARVEST_BUDGET_SECONDS
    COLLECTION_DEADLINE=$(( $(uptime_seconds) + budget ))
    for profile in "${SOURCE_FILES[@]}"; do
        remaining=$((COLLECTION_DEADLINE - $(uptime_seconds)))
        if ((remaining <= 0)); then
            SOURCES_FAILED=$((SOURCES_FAILED+1)); RUN_STATUS=PARTIAL
            log "Collection budget exhausted; remaining source resumes next run: $profile"
        else
            # Fair-share what remains, so one large recorder cannot take the
            # entire acquisition allowance before other sources are considered.
            HARVEST_BUDGET_SECONDS=$((remaining / count))
            ((HARVEST_BUDGET_SECONDS > 0)) || HARVEST_BUDGET_SECONDS=1
            if run_source "$profile" collect; then SOURCES_OK=$((SOURCES_OK+1)); else
                SOURCES_FAILED=$((SOURCES_FAILED+1)); RUN_STATUS=PARTIAL
                log "Source failed; continuing with the next: $profile"
            fi
        fi
        count=$((count-1))
    done
    HARVEST_BUDGET_SECONDS=$budget
    unset COLLECTION_DEADLINE
}
