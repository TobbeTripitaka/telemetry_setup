#!/usr/bin/env bash
# No rclone sync/delete/move. Only complete exports enter this upload path.
verify_remote() {
    local features
    features=$(cloud backend features "$REMOTE_DATA") || return 1
    jq -e '(.Hashes | index("dropbox") != null) and .Features.IsLocal != true' <<<"$features" >/dev/null
}

validate_paths() {
    local root=$1 file rel
    local -A names=()
    while IFS= read -r -d '' file; do
        [[ -f $file && ! -L $file ]] || return 1
        rel=${file#"$root/"}
        [[ $rel != *$'\n'* && $rel != *$'\r'* && $rel != *$'\t'* &&
           $rel != *\\* && $rel != -* ]] || return 1
        # Dropbox case-folds paths; never merge distinct native names silently.
        [[ -z ${names[${rel,,}]+yes} ]] || return 1
        names[${rel,,}]=1
    done < <(find "$root" -mindepth 1 ! -type d -print0)
}

validate_batch() {
    local batch=$1
    [[ -f $batch/READY && -d $batch/files && ! -L $batch && ! -L $batch/files ]] || return 1
    [[ ! -L $batch/READY && ! -L $batch/meta.json && ! -L $batch/dropbox.sum ]] || return 1
    # READY is generated locally but still treat corruption as data, not paths.
    [[ $(wc -l <"$batch/READY") == 2 ]] &&
        grep -Eq '^[a-f0-9]{64}  meta.json$' "$batch/READY" &&
        grep -Eq '^[a-f0-9]{64}  dropbox.sum$' "$batch/READY" || return 1
    (cd "$batch" && sha256sum -c READY >/dev/null) || return 1
    jq -e --arg r "$RECORDER_SERIAL" \
        '.schema==1 and .recorder==$r and (.day|test("^20[0-9]{2}-[0-9]{2}-[0-9]{2}$"))' \
        "$batch/meta.json" >/dev/null || return 1
    validate_paths "$batch/files" || return 1
    # Explicit Dropbox hash avoids size-only fallback on unsupported hash types.
    cloud check "$batch/dropbox.sum" "$batch/files" --checkfile Dropbox --one-way \
        >>"$LOG_FILE" 2>&1 || return 1
    # Detect extra local files added after the export was frozen.
    local count expected
    count=$(find "$batch/files" -type f -printf '.\n' | wc -l)
    expected=$(wc -l <"$batch/dropbox.sum")
    [[ $count == "$expected" ]]
}

count_file_kinds() {
    # "data 3, logs 5, soh 0, other 1": waveform files sit under a year folder,
    # logs under logs/, state-of-health under soh/; a 0 for soh is worth a look.
    local root=$1 data logs soh total
    total=$(find "$root" -type f | wc -l)
    data=$(find "$root" -type f -path "$root/[0-9][0-9][0-9][0-9]/*" | wc -l)
    logs=$(find "$root/logs" -type f 2>/dev/null | wc -l)
    soh=$(find "$root/soh" -type f 2>/dev/null | wc -l)
    printf 'data %s, logs %s, soh %s, other %s' "$data" "$logs" "$soh" "$((total - data - logs - soh))"
}

quarantine_batch() {
    local batch=$1 quarantine="$STATE_ROOT/quarantine" old
    mkdir -p -- "$quarantine" || return 0
    mv -T -- "$batch" "$quarantine/$(basename -- "$batch")-$RUN_ID" 2>/dev/null || rm -rf -- "$batch"
    # Keep only the newest few; this is a diagnostic aid, not an archive.
    while IFS= read -r old; do rm -rf -- "$old"; done < <(ls -1dt "$quarantine"/* 2>/dev/null | tail -n +6)
    return 0
}

upload_batch() {
    local batch=$1 day force temp started=$SECONDS files_count size_bytes
    local verify=$batch/dropbox.sum receipts=$batch/receipt-out
    if ! validate_batch "$batch"; then
        # A damaged batch must never block this recorder for good: set it aside
        # (kept for inspection) so the day is exported again at the next run.
        quarantine_batch "$batch"
        die "Pending batch failed its integrity check and was set aside; the day will be exported again: $batch"
        return 1
    fi
    day=$(jq -r .day "$batch/meta.json")
    force=$(jq -r .force "$batch/meta.json")
    local -a flags=(--checksum)
    [[ $force != yes ]] || flags=(--ignore-times)
    # An acknowledgment belongs to the destination actually verified, not just a day.
    jq --arg destination "$REMOTE_DATA" '.destination=$destination' \
        "$batch/meta.json" >"$batch/receipt.json" || return 1
    if [[ ! -s $verify ]]; then
        log "Nothing to upload for $day (the recorder holds no files for this day)"
    else
        log "Uploading/verifying $day force=$force"
        cloud copy "$batch/files" "$REMOTE_DATA" --no-traverse "${flags[@]}" \
            >>"$LOG_FILE" 2>&1 || return 1
        cloud check "$verify" "$REMOTE_DATA" --checkfile Dropbox --one-way \
            >>"$LOG_FILE" 2>&1 || return 1
        # Small remote receipts (one transfer: every round trip is slow on a patchy
        # link) next to the Nanometrics tree: <computer>/tele_logfiles/harvest/.
        rm -rf -- "$receipts" && mkdir "$receipts" || return 1
        cp -- "$batch/receipt.json" "$receipts/$day.json" || return 1
        cp -- "$verify" "$receipts/$day.dropbox.sum" || return 1
        [[ ! -f $batch/harvest.log ]] || cp -- "$batch/harvest.log" "$receipts/$day.harvest.log" || return 1
        cloud copy "$receipts" "$REMOTE_BASE/tele_logfiles/harvest" \
            --no-traverse --checksum >>"$LOG_FILE" 2>&1 || return 1
    fi
    # The acknowledgment is the LAST correctness-changing action.
    temp=$(mktemp "$VERIFIED/.$day.XXXXXX") || return 1
    cp -- "$batch/receipt.json" "$temp" || return 1
    atomic_install "$temp" "$VERIFIED/$day.json" || return 1
    # How many files/MiB and how long: tells a slow link from a big day.
    files_count=$(find "$batch/files" -type f | wc -l)
    size_bytes=$(du -sb "$batch/files" | cut -f1)
    log "Verified in Dropbox: $day ($(count_file_kinds "$batch/files"); $((size_bytes / 1048576)) MiB, $((SECONDS - started)) s)"
    : "$files_count"
    retain_or_remove_batch "$batch" || return 1
}

retain_or_remove_batch() {
    # Deletion is limited to exact immediate children of the private spool.
    local batch=$1
    [[ $(dirname -- "$batch") == "$SPOOL" && ! -L $batch &&
       $(basename -- "$batch") =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    if [[ ${LOCAL_DATA:-keep} == keep ]]; then
        # The local copy has the same seismic layout as Dropbox: LOCAL_ARCHIVE
        # (/home/<user>/data/Nanometrics) holds the merged tree of every day.
        mkdir -p -- "$LOCAL_ARCHIVE" || return 1
        chown -R --reference="$LOCAL_ARCHIVE" -- "$batch/files" 2>/dev/null || true
        cp -a -- "$batch/files/." "$LOCAL_ARCHIVE/" || return 1
        sync -f "$LOCAL_ARCHIVE" || return 1
    fi
    rm -rf -- "$batch"
}

prune_archive() {
    # Remove the oldest local days (already verified in Dropbox) until $1 MiB is free.
    local target=$1 y j day free
    [[ -d $LOCAL_ARCHIVE && ! -L $LOCAL_ARCHIVE ]] || return 0
    while read -r y j; do
        free=$(free_mib) || return 0
        (( free < target )) || return 0
        day=$(date -u -d "$y-01-01 +$((10#$j - 1)) days" +%F 2>/dev/null) || continue
        [[ -f $VERIFIED/$day.json ]] || continue
        log "Local storage low (${free} MiB free): removing the verified local copy of $day (it remains in Dropbox)"
        find "$LOCAL_ARCHIVE" -type f -name "*.$y.$j" -delete
    done < <(find "$LOCAL_ARCHIVE" -type f -printf '%f\n' |
        sed -nE 's/.*\.([0-9]{4})\.([0-9]{3})$/\1 \2/p' | sort -u)
    free=$(free_mib) || return 0
    (( free >= target )) ||
        log "WARNING: local storage still low (${free} MiB free) and no verified local copies remain to remove"
}

wait_for_dropbox() {
    # Wait (bounded) for the connection to come back after a failed transfer.
    local limit=$1 started
    started=$(uptime_seconds)
    while (( $(uptime_seconds) - started < limit )); do
        # The collection and run deadlines still apply: stop at once when spent.
        source_timeout 1 true || return 1
        if verify_remote >/dev/null 2>&1; then return 0; fi
        sleep 15
    done
    return 1
}

upload_with_retry() {
    # A flapping link (Starlink dropping for minutes) must not end the whole run:
    # on a failed transfer, wait for Dropbox to return and try again. Files that
    # already arrived are skipped by their hash, so each attempt only finishes the rest.
    local batch=$1 attempt max=${UPLOAD_ATTEMPTS:-3}
    for ((attempt = 1; attempt <= max; attempt++)); do
        if upload_batch "$batch"; then return 0; fi
        [[ -d $batch ]] || return 1    # set aside as damaged: nothing to retry
        ((attempt < max)) || break
        log "Upload of $(basename -- "$batch") failed (attempt $attempt of $max); waiting for the connection"
        wait_for_dropbox 240 || { log "The connection did not return in time"; return 1; }
        log "Connection is back; retrying $(basename -- "$batch")"
    done
    return 1
}

drain_pending() {
    local batch name
    while IFS= read -r -d '' batch; do
        upload_with_retry "$batch" || return 1
    done < <(find "$SPOOL" -mindepth 1 -maxdepth 1 -type d -name '20??-??-??' -print0 | sort -z)
    # Scratch from an interrupted export is not a recoverable ready batch.
    # Preserve its diagnostic log but reclaim space; no acknowledgment was written.
    # Completed pending batches above are NEVER subject to this cleanup.
    while IFS= read -r -d '' batch; do
        name=$(basename -- "$batch")
        [[ $name =~ ^\.partial-20[0-9]{2}-[0-9]{2}-[0-9]{2}\.[A-Za-z0-9]{6}$ ]] || continue
        if [[ -f $batch/harvest.log && ! -L $batch/harvest.log ]]; then
            cp -- "$batch/harvest.log" "$LOG_ROOT/$RUN_ID-$name.log" || return 1
        fi
        log "Discarding incomplete scratch $name; its day remains unverified and will be re-harvested"
        rm -rf -- "$batch"
    done < <(find "$SPOOL" -mindepth 1 -maxdepth 1 -type d -name '.partial-*' -print0)
}
