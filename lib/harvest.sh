#!/usr/bin/env bash
# Daily, isolated exports. The native -p path pattern is NEVER overridden.
harvest_log_ok() {
    local file=$1 op
    if grep -Eq '<<<ERROR|status[ =]+(FAILED|ERROR|ABORTED)' "$file"; then return 1; fi
    for op in harvest-logs harvest-soh harvest-data; do
        grep -Fq "Operation '$op' finished with status COMPLETED(0)" "$file" || return 1
    done
    # Firmware on the user's recorder lacks volume 3. Allow only this known skip.
    if grep -Fq 'Failed to harvest ClockStatus data!' "$file"; then
        [[ $CLOCK_PRESENT == no ]] &&
            grep -Fq 'Clock Status Volume not found - harvesting skipped' "$file" || return 1
    fi
    # Any other error/failure text blocks promotion; do not guess that it is benign.
    if sed '/Failed to harvest ClockStatus data!/d' "$file" |
        grep -Eiq '(^|[^a-z])(error|failed|aborted|cancelled)([^a-z]|$)'; then return 1; fi
}

harvest_day() {
    local start=$1 end=$2 request=$3 force=$4 remaining=$5
    local day work pid started elapsed
    day=$(date -u -d "@$start" +%F) || return 1
    work=$(mktemp -d "$SPOOL/.partial-$day.XXXXXX") || return 1
    mkdir "$work/files"
    started=$(uptime_seconds)
    # Keep a process group, not a broad pkill pattern. timeout handles its children.
    timeout --signal=TERM --kill-after=10 "$remaining" \
        "$PEGASUS_BIN" harvest "-i=$DEVICE" "-o=$work/files" \
        "-l=$((start * 1000000000))" "-u=$((end * 1000000000 - 1))" \
        -d=24 -safe -harvestData=1 -harvestSoh=1 -harvestLegacySoh=1 -harvestLogs=1 \
        >"$work/harvest.log" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if ! disk_has_reserve; then
            log "Disk reserve reached; stopping harvest"
            kill -TERM "$pid" 2>/dev/null || true
            break
        fi
        sleep 1
    done
    local result=0
    wait "$pid" || result=$?
    elapsed=$(( $(uptime_seconds) - started ))
    HARVEST_USED_SECONDS=$((HARVEST_USED_SECONDS + elapsed))
    [[ $result == 0 ]] && disk_has_reserve && harvest_log_ok "$work/harvest.log" ||
        { log "Incomplete/failed export retained at $work"; return 1; }
    validate_paths "$work/files" || return 1
    # Freeze hashes before creating the ready marker. No log/manifest inside files/.
    cloud hashsum Dropbox "$work/files" --output-file "$work/dropbox.sum" \
        >>"$LOG_FILE" 2>&1 || return 1
    local now
    now=$(date -u +%s)
    jq -n --arg day "$day" --arg recorder "$RECORDER_SERIAL" --arg request "$request" \
        --arg force "$force" --argjson start "$start" --argjson end "$end" \
        --argjson closed "$(( end <= (now / 86400) * 86400 ? 1 : 0 ))" \
        '{schema:1,day:$day,recorder:$recorder,request:$request,force:$force,
          start:$start,end:$end,closed:$closed}' >"$work/meta.json" || return 1
    (cd "$work" && sha256sum meta.json dropbox.sum >READY) || return 1
    sync -f "$work" || return 1
    [[ ! -e $SPOOL/$day ]] || { die "Pending day already exists: $day"; return 1; }
    mv -T -- "$work" "$SPOOL/$day" || return 1
    sync -f "$SPOOL"
}

harvest_cycle() {
    local start end cursor day ack request force remaining now overlap_floor
    now=$(date -u +%s)
    start=$(( (EARLIEST_NS / 1000000000 / 86400) * 86400 ))
    end=$(( (LATEST_NS / 1000000000 / 86400 + 1) * 86400 ))
    (( end <= now + 86400 )) || return 1
    request=incremental
    if [[ $HARVEST_MODE != incremental ]]; then request="$HARVEST_MODE:$REQUEST_ID"; fi
    if [[ $HARVEST_MODE == range ]]; then
        start=$(date -u -d "$FROM_DATE" +%s)
        end=$(date -u -d "$TO_DATE" +%s)
        (( end <= (now / 86400 + 1) * 86400 )) || return 1
    fi
    # Retention-window loss must be visible, never silently described as complete.
    if [[ -f $STATE_ROOT/earliest-seen ]]; then
        local previous
        previous=$(<"$STATE_ROOT/earliest-seen")
        [[ $previous =~ ^[0-9]+$ ]] || return 1
        if (( previous < start )); then log "WARNING: recorder lower bound advanced; review any unverified gaps"; fi
    else
        printf '%s\n' "$start" >"$STATE_ROOT/earliest-seen"
        sync -f "$STATE_ROOT/earliest-seen" || return 1
    fi
    overlap_floor=$(( (now / 86400 - OVERLAP_DAYS) * 86400 ))
    HARVEST_USED_SECONDS=0
    for ((cursor=start; cursor<end; cursor+=86400)); do
        force=none
        [[ $HARVEST_MODE != reupload ]] || force=yes
        day=$(date -u -d "@$cursor" +%F)
        ack="$VERIFIED/$day.json"
        # No new work while an earlier ready batch cannot be safely uploaded.
        if [[ -d $SPOOL/$day ]]; then upload_batch "$SPOOL/$day" || return 1; fi
        if [[ -f $ack ]]; then
            jq -e --arg r "$RECORDER_SERIAL" \
                '.schema==1 and .recorder==$r and (.closed==0 or .closed==1)' "$ack" >/dev/null || return 1
            # A completed forced request is not a standing instruction to resend
            # identical recent files at every weekly boot.
            if [[ $(jq -r .request "$ack") == "$request" ]]; then force=none; fi
            if (( cursor < overlap_floor )) && [[ $(jq -r .closed "$ack") == 1 ]]; then
                if [[ $HARVEST_MODE == incremental ||
                      $(jq -r .request "$ack") == "$request" ]]; then continue; fi
            fi
        fi
        remaining=$((HARVEST_BUDGET_SECONDS - HARVEST_USED_SECONDS))
        (( remaining > 0 )) || { log "Harvest budget exhausted; remaining days resume next boot"; return 1; }
        disk_has_reserve || { die "Insufficient free space"; return 1; }
        log "Harvesting UTC day $day (native paths, 24-hour files)"
        harvest_day "$cursor" "$((cursor+86400))" "$request" "$force" "$remaining" || return 1
        upload_batch "$SPOOL/$day" || return 1
    done
}
