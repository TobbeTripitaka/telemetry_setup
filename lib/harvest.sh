#!/usr/bin/env bash
# Daily, isolated exports. The native -p path pattern is NEVER overridden.
# One recorder export is one native Harvester call per UTC day for data and logs,
# plus ONE call per run for state-of-health (see ensure_soh_export). The native
# output pattern is never overridden; only -ext=0 is added so that file names
# match those written by the Pegasus Harvester application (no .mseed/.txt).
harvest_log_ok() {
    # harvest_log_ok <log> <operation>...: every named operation must have completed.
    local file=$1 op
    shift
    if grep -Eq '<<<ERROR|status[ =]+(FAILED|ERROR|ABORTED)' "$file"; then return 1; fi
    for op in "$@"; do
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

run_export() {
    # run_export <output dir> <log file> <seconds allowed> <extra harvester args>...
    local out=$1 logfile=$2 remaining=$3 pid started result=0
    shift 3
    started=$(uptime_seconds)
    # Keep a process group, not a broad pkill pattern. timeout handles its children.
    timeout --signal=TERM --kill-after=10 "$remaining" \
        "$PEGASUS_BIN" harvest "-i=$DEVICE" "-o=$out" -d=24 -ext=0 -safe "$@" \
        >"$logfile" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if ! disk_has_reserve; then
            log "Disk reserve reached; stopping harvest"
            kill -TERM "$pid" 2>/dev/null || true
            break
        fi
        sleep 1
    done
    wait "$pid" || result=$?
    HARVEST_USED_SECONDS=$((HARVEST_USED_SECONDS + $(uptime_seconds) - started))
    harvester_exit_ok "$result" && disk_has_reserve
}

prune_other_days() {
    # A day window can also export a short stub of the neighbouring day (a log
    # line stamped just before midnight). That day is exported complete by its own
    # window, so files of other days are dropped here and can never conflict.
    local root=$1 year=$2 jday=$3 file base dropped=0
    while IFS= read -r -d '' file; do
        base=${file##*/}
        if [[ $base =~ \.([0-9]{4})\.([0-9]{3})$ ]] &&
           [[ ${BASH_REMATCH[1]} != "$year" || ${BASH_REMATCH[2]} != "$jday" ]]; then
            rm -f -- "$file"
            dropped=$((dropped + 1))
        fi
    done < <(find "$root" -type f -print0)
    find "$root" -mindepth 1 -type d -empty -delete
    (( dropped == 0 )) || log "Dropped $dropped file(s) of neighbouring days from this export"
    return 0
}

ensure_soh_export() {
    # The native -l/-u window does not work for state-of-health ("Lower bound not
    # found" and nothing is written), so SOH is exported ONCE per run without
    # bounds into a work folder; each day then takes its own files from there.
    local remaining=$1 log_file="$STATE_ROOT/soh-harvest.log"
    [[ $SOH_EXPORT_DONE != yes ]] || return 0
    SOH_DIR="$STATE_ROOT/soh-work"
    rm -rf -- "$SOH_DIR" && mkdir -p -- "$SOH_DIR" || return 1
    log "Exporting state-of-health once for this run"
    run_export "$SOH_DIR" "$log_file" "$remaining" \
        -harvestData=0 -harvestLogs=0 -harvestSoh=1 -harvestLegacySoh=1 &&
        harvest_log_ok "$log_file" harvest-soh ||
        { log "State-of-health export failed; see $log_file"; return 1; }
    SOH_EXPORT_DONE=yes
}

merge_soh_for_day() {
    # Copy the day's SOH files (name ends in .YYYY.JJJ) into the day's batch.
    local work=$1 year=$2 jday=$3 file rel count=0
    SOH_DAY_FILES=0
    [[ -d $SOH_DIR/soh ]] || return 0
    while IFS= read -r -d '' file; do
        rel=${file#"$SOH_DIR/"}
        mkdir -p -- "$work/files/$(dirname -- "$rel")" || return 1
        cp -p -- "$file" "$work/files/$rel" || return 1
        count=$((count + 1))
    done < <(find "$SOH_DIR/soh" -type f -name "*.$year.$jday" -print0)
    SOH_DAY_FILES=$count
    return 0
}

harvest_day() {
    local start=$1 end=$2 request=$3 force=$4 remaining=$5
    local day year jday work
    day=$(date -u -d "@$start" +%F) || return 1
    year=$(date -u -d "@$start" +%Y) jday=$(date -u -d "@$start" +%j)
    work=$(mktemp -d "$SPOOL/.partial-$day.XXXXXX") || return 1
    mkdir "$work/files"
    run_export "$work/files" "$work/harvest.log" "$remaining" \
        "-l=$((start * 1000000000))" "-u=$((end * 1000000000 - 1))" \
        -harvestData=1 -harvestLogs=1 -harvestSoh=0 -harvestLegacySoh=0 &&
        harvest_log_ok "$work/harvest.log" harvest-logs harvest-data ||
        { log "Incomplete/failed export retained at $work"; return 1; }
    prune_other_days "$work/files" "$year" "$jday"
    if (( end * 1000000000 > SOH_LOWER_NS && start * 1000000000 <= SOH_UPPER_NS )); then
        ensure_soh_export "$remaining" || return 1
        merge_soh_for_day "$work" "$year" "$jday" || return 1
        (( SOH_DAY_FILES > 0 || end * 1000000000 > SOH_UPPER_NS )) ||
            log "WARNING: no state-of-health files for $day although the recorder's SOH volume covers it"
    fi
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
    # START_DATE: do not collect the recorder's history from before this UTC day
    # (a new station need not upload years of old data over a patchy link).
    if [[ $HARVEST_MODE != range && -n ${START_DATE:-} ]]; then
        local first
        first=$(date -u -d "$START_DATE" +%s)
        (( start >= first )) || start=$first
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
    SOH_EXPORT_DONE=no
    overlap_floor=$(( (now / 86400 - OVERLAP_DAYS) * 86400 ))
    HARVEST_USED_SECONDS=0
    for ((cursor=start; cursor<end; cursor+=86400)); do
        force=none
        [[ $HARVEST_MODE != reupload ]] || force=yes
        day=$(date -u -d "@$cursor" +%F)
        ack="$VERIFIED/$day.json"
        # No new work while an earlier ready batch cannot be safely uploaded.
        if [[ -d $SPOOL/$day ]]; then upload_with_retry "$SPOOL/$day" || return 1; fi
        if [[ -f $ack ]]; then
            jq -e --arg r "$RECORDER_SERIAL" \
                '.schema==1 and .recorder==$r and (.closed==0 or .closed==1)' "$ack" >/dev/null || return 1
            # A completed forced request is not a standing instruction to resend
            # identical recent files at every weekly boot.
            local same_destination=no
            [[ $(jq -r '.destination // ""' "$ack") != "$REMOTE_DATA" ]] || same_destination=yes
            if [[ $same_destination == yes && $(jq -r .request "$ack") == "$request" ]]; then force=none; fi
            if (( cursor < overlap_floor )) && [[ $same_destination == yes && $(jq -r .closed "$ack") == 1 ]]; then
                if [[ $HARVEST_MODE == incremental ||
                      $(jq -r .request "$ack") == "$request" ]]; then continue; fi
            fi
        fi
        remaining=$((HARVEST_BUDGET_SECONDS - HARVEST_USED_SECONDS))
        if [[ -n ${COLLECTION_DEADLINE:-} ]] && (( COLLECTION_DEADLINE - $(uptime_seconds) < remaining )); then
            remaining=$((COLLECTION_DEADLINE - $(uptime_seconds)))
        fi
        (( remaining > 0 )) || { log "Harvest budget exhausted; remaining days resume next boot"; return 1; }
        check_local_storage
        disk_has_reserve || { die "Insufficient free space"; return 1; }
        log "Harvesting UTC day $day (native paths, 24-hour files)"
        harvest_day "$cursor" "$((cursor+86400))" "$request" "$force" "$remaining" || return 1
        upload_with_retry "$SPOOL/$day" || return 1
    done
}
