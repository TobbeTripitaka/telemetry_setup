#!/usr/bin/env bash
collect_starlink_diagnostics() {
    local file="$LOG_ROOT/$RUN_ID-starlink.json" temp="$LOG_ROOT/$RUN_ID-starlink.partial"
    command -v grpcurl >/dev/null || { log "grpcurl missing: Starlink diagnostics unavailable"; return 1; }
    # Read-only get_status; no browser, dish control, speed test or history flood.
    if starlink_rpc '{"get_status":{}}' >"$temp" 2>>"$LOG_FILE" &&
        jq -e '.dishGetStatus | type=="object"' "$temp" >/dev/null; then
        atomic_install "$temp" "$file" || return 1
        local config="$LOG_ROOT/$RUN_ID-starlink-config.json" mode
        if starlink_rpc '{"dish_get_config":{}}' >"$config" 2>>"$LOG_FILE"; then
            mode=$(starlink_snow_mode <"$config") || mode=UNKNOWN
            log "Starlink snow-melt mode: $mode"
            if [[ ${STARLINK_EXPECT_SNOW_OFF:-no} == yes && $mode != ALWAYS_OFF ]]; then
                log "WARNING: snow melt is not verified Off; set it through the app and recheck"
                return 1
            fi
        elif [[ ${STARLINK_EXPECT_SNOW_OFF:-no} == yes ]]; then
            log "WARNING: snow-melt configuration unreadable"
            return 1
        fi
        return 0
    else
        log "Starlink diagnostics failed (data collection continues)"
        return 1
    fi
}

snapshot_log() {
    local snapshots="$LOG_ROOT/.outbound"
    mkdir -p "$snapshots"
    # Immutable copy: the active log must not change under rclone's checksum.
    local file
    # Include old runs that ended before their snapshot could be uploaded.
    while IFS= read -r -d '' file; do
        cp -- "$file" "$snapshots/" || return 1
    done < <(find "$LOG_ROOT" -maxdepth 1 -type f \
        \( -name '*.log' -o -name '*.txt' -o -name '*.json' \) -print0)
    # Outbound logs from previous offline runs are retried as well.
    cloud copy "$snapshots" "$REMOTE_BASE/tele_logfiles" --checksum >>"$LOG_FILE" 2>&1 || return 1
    cloud check "$snapshots" "$REMOTE_BASE/tele_logfiles" --one-way >>"$LOG_FILE" 2>&1 || return 1
    # Only verified copies are pruned; keep local source logs for the last 30 days.
    find "$snapshots" -type f -delete
    find "$LOG_ROOT" -maxdepth 1 -type f -mtime +30 -delete
}

send_notification() {
    local status=$1 dir auth mail password from pending
    [[ -n $EMAIL_TO && -n $EMAIL_FROM && -n $EMAIL_PASSWORD ]] ||
        { log "Email not sent: credentials unavailable"; return 1; }
    dir=$(mktemp -d "$STATE_ROOT/.mail.XXXXXX") || return 1
    auth="$dir/curl.conf" mail="$dir/message.txt"
    # curl configuration escaping; secret is never in process arguments or log.
    password=${EMAIL_PASSWORD//\\/\\\\}; password=${password//\"/\\\"}
    from=${EMAIL_FROM//\\/\\\\}; from=${from//\"/\\\"}
    printf 'user = "%s:%s"\n' "$from" "$password" >"$auth"
    pending=$(find "${STATION_STATE_ROOT:-$STATE_ROOT}" -type d \
        -path '*/pending/*' \( -name '20??-??-??' -o -name '.partial-*' \) -printf '.\n' | wc -l)
    {
        printf 'From: %s\r\nTo: %s\r\nSubject: TELE %s %s\r\n' "$EMAIL_FROM" "$EMAIL_TO" "$STATION_NAME" "$status"
        printf 'MIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n'
        printf 'Station: %s\nRun: %s\nStatus: %s\nMode: %s\nPending/incomplete batches: %s\n' \
            "$STATION_NAME" "$RUN_ID" "$status" "$HARVEST_MODE" "$pending"
        printf 'Local data: %s; free disk: %s MiB\n' "${LOCAL_DATA:-keep}" "$(free_mib 2>/dev/null || echo unknown)"
        printf 'Dropbox: %s\nPost-run mode: %s\nIdle maintenance window: %ss\n' \
            "$REMOTE_BASE" "$EXECUTE" "$MAINTENANCE_IDLE_SECONDS"
        printf 'Run mode: %s\nSources succeeded: %s; failed: %s\n' \
            "${RUN_MODE:-bench-helper}" "${SOURCES_OK:-unknown}" "${SOURCES_FAILED:-unknown}"
        if [[ ${RUN_MODE:-} == field ]]; then
            printf 'Emergency power-off timer remains active, including during remote sessions.\n\n'
        else printf 'Bench/check helper: no poweroff is requested by this script.\n\n'; fi
        tail -n 100 "$LOG_FILE"
    } >"$mail"
    # Starlink may have only just come up: try three times before giving up, and
    # keep the reason (EMAIL_ERROR) so the installer and the log can show it.
    local rc=0 attempt err="$dir/curl.err"
    EMAIL_ERROR=''
    for attempt in 1 2 3; do
        rc=0
        timeout -k 5 60 curl --config "$auth" --silent --show-error --ssl-reqd \
            --url smtps://smtp.gmail.com:465 --mail-from "$EMAIL_FROM" --mail-rcpt "$EMAIL_TO" \
            --connect-timeout 15 --max-time 50 --upload-file "$mail" >>"$LOG_FILE" 2>"$err" || rc=$?
        [[ $rc != 0 ]] || break
        EMAIL_ERROR="curl status $rc: $(tail -n 1 "$err")"
        log "Email attempt $attempt of 3 failed: $EMAIL_ERROR"
        ((attempt == 3)) || sleep "${EMAIL_RETRY_SECONDS:-10}"
    done
    rm -rf -- "$dir"
    [[ $rc == 0 ]]
}
