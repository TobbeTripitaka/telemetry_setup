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

claim_paths() {
    local root=$1 day=$2 file rel key owner temp
    while IFS= read -r -d '' file; do
        rel=${file#"$root/"}
        key=$(printf '%s' "${rel,,}" | sha256sum)
        key=${key%% *}
        owner="$OWNERS/$key"
        if [[ -f $owner ]]; then
            [[ $(<"$owner") == "$day:$rel" ]] ||
                { die "Native path reused across days/case variants: $rel. Hardware output layout needs review."; return 1; }
        else
            temp=$(mktemp "$OWNERS/.new.XXXXXX") || return 1
            printf '%s\n' "$day:$rel" >"$temp"
            atomic_install "$temp" "$owner" || return 1
        fi
    done < <(find "$root" -type f -print0)
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

upload_batch() {
    local batch=$1 day force temp
    validate_batch "$batch" || { die "Pending batch integrity check failed: $batch"; return 1; }
    day=$(jq -r .day "$batch/meta.json")
    force=$(jq -r .force "$batch/meta.json")
    claim_paths "$batch/files" "$day" || return 1
    local -a flags=(--checksum)
    [[ $force != yes ]] || flags=(--ignore-times)
    log "Uploading/verifying $day force=$force"
    cloud copy "$batch/files" "$REMOTE_DATA" --no-traverse "${flags[@]}" >>"$LOG_FILE" 2>&1 || return 1
    cloud check "$batch/dropbox.sum" "$REMOTE_DATA" --checkfile Dropbox --one-way \
        >>"$LOG_FILE" 2>&1 || return 1
    # Keep a small remote receipt to diagnose/rebuild local state later.
    cloud copyto "$batch/meta.json" "$REMOTE_BASE/tele_logfiles/receipts/$RECORDER_SERIAL/$day.json" \
        --checksum >>"$LOG_FILE" 2>&1 || return 1
    cloud copyto "$batch/dropbox.sum" "$REMOTE_BASE/tele_logfiles/receipts/$RECORDER_SERIAL/$day.dropbox.sum" \
        --checksum >>"$LOG_FILE" 2>&1 || return 1
    cloud copyto "$batch/harvest.log" "$REMOTE_BASE/tele_logfiles/harvest/$RUN_ID-$day.log" \
        --checksum >>"$LOG_FILE" 2>&1 || return 1
    # The acknowledgment is the LAST correctness-changing action.
    temp=$(mktemp "$VERIFIED/.$day.XXXXXX") || return 1
    cp -- "$batch/meta.json" "$temp" || return 1
    atomic_install "$temp" "$VERIFIED/$day.json" || return 1
    log "Verified in Dropbox: $day"
    retain_or_remove_batch "$batch" || return 1
}

retain_or_remove_batch() {
    local batch=$1
    # Deletion is limited to exact immediate children of the private spool.
    [[ $(dirname -- "$batch") == "$SPOOL" && ! -L $batch &&
       $(basename -- "$batch") =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    if [[ $RETAIN_LAST_BATCH == yes ]]; then
        # Old last-verified data is already acknowledged; pending data is untouched.
        [[ ! -L $LAST_BATCH && $LAST_BATCH == "$STATE_ROOT/last-verified" ]] || return 1
        rm -rf -- "$LAST_BATCH.previous"
        if [[ -d $LAST_BATCH ]]; then mv -T -- "$LAST_BATCH" "$LAST_BATCH.previous" || return 1; fi
        mv -T -- "$batch" "$LAST_BATCH" || return 1
        sync -f "$STATE_ROOT" || return 1
        rm -rf -- "$LAST_BATCH.previous"
    else
        rm -rf -- "$batch"
        [[ ! -L $LAST_BATCH && $LAST_BATCH == "$STATE_ROOT/last-verified" ]] || return 1
        rm -rf -- "$LAST_BATCH" "$LAST_BATCH.previous"
    fi
}

drain_pending() {
    local batch name
    while IFS= read -r -d '' batch; do
        upload_batch "$batch" || return 1
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
