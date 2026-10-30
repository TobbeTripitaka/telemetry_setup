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
    # Owner records: line 1 "day:path", line 2 its Dropbox hash. The Harvester
    # can re-emit an identical out-of-range log/SOH file in every daily export;
    # identical content is harmless. Different content under one path is not.
    local root=$1 day=$2 sums=${3:-} file rel key owner temp hash claimed stored
    while IFS= read -r -d '' file; do
        rel=${file#"$root/"}
        key=$(printf '%s' "${rel,,}" | sha256sum)
        key=${key%% *}
        owner="$OWNERS/$key"
        hash=''
        if [[ -n $sums ]]; then
            hash=$(awk -v p="$rel" 'length($0) > 66 && substr($0, 67) == p {print substr($0, 1, 64); exit}' "$sums")
        fi
        claimed='' stored=''
        if [[ -f $owner ]]; then
            { IFS= read -r claimed; IFS= read -r stored; } <"$owner" || true
            if [[ $claimed != "$day:$rel" ]]; then
                if [[ -n $hash && $stored == "$hash" ]]; then
                    log "Identical file re-exported in $day, already claimed by ${claimed%%:*}: $rel"
                    continue
                fi
                die "Native path reused across days/case variants with different content: $rel. Hardware output layout needs review."
                return 1
            fi
            [[ $stored != "$hash" ]] || continue
        fi
        temp=$(mktemp "$OWNERS/.new.XXXXXX") || return 1
        printf '%s\n%s\n' "$day:$rel" "$hash" >"$temp"
        atomic_install "$temp" "$owner" || return 1
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
    claim_paths "$batch/files" "$day" "$batch/dropbox.sum" || return 1
    local -a flags=(--checksum)
    [[ $force != yes ]] || flags=(--ignore-times)
    log "Uploading/verifying $day force=$force"
    cloud copy "$batch/files" "$REMOTE_DATA" --no-traverse "${flags[@]}" >>"$LOG_FILE" 2>&1 || return 1
    cloud check "$batch/dropbox.sum" "$REMOTE_DATA" --checkfile Dropbox --one-way \
        >>"$LOG_FILE" 2>&1 || return 1
    # An acknowledgment belongs to the destination actually verified, not just a day.
    jq --arg destination "$REMOTE_DATA" '.destination=$destination' \
        "$batch/meta.json" >"$batch/receipt.json" || return 1
    # Keep a small remote receipt to diagnose/rebuild local state later.
    cloud copyto "$batch/receipt.json" "$REMOTE_BASE/tele_logfiles/receipts/$RECORDER_SERIAL/$day.json" \
        --checksum >>"$LOG_FILE" 2>&1 || return 1
    cloud copyto "$batch/dropbox.sum" "$REMOTE_BASE/tele_logfiles/receipts/$RECORDER_SERIAL/$day.dropbox.sum" \
        --checksum >>"$LOG_FILE" 2>&1 || return 1
    cloud copyto "$batch/harvest.log" "$REMOTE_BASE/tele_logfiles/harvest/$RUN_ID-$day.log" \
        --checksum >>"$LOG_FILE" 2>&1 || return 1
    # The acknowledgment is the LAST correctness-changing action.
    temp=$(mktemp "$VERIFIED/.$day.XXXXXX") || return 1
    cp -- "$batch/receipt.json" "$temp" || return 1
    atomic_install "$temp" "$VERIFIED/$day.json" || return 1
    log "Verified in Dropbox: $day"
    retain_or_remove_batch "$batch" || return 1
}

retain_or_remove_batch() {
    local batch=$1 day
    # Deletion is limited to exact immediate children of the private spool.
    [[ $(dirname -- "$batch") == "$SPOOL" && ! -L $batch &&
       $(basename -- "$batch") =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    day=$(basename -- "$batch")
    if [[ ${LOCAL_DATA:-keep} == keep ]]; then
        # Verified data stays locally until space runs low (see prune_kept).
        [[ ! -L $KEPT && $KEPT == "$STATE_ROOT/kept" ]] || return 1
        mkdir -p -- "$KEPT" || return 1
        rm -rf -- "${KEPT:?}/$day"
        mv -T -- "$batch" "$KEPT/$day" || return 1
        sync -f "$STATE_ROOT" || return 1
    else
        # LOCAL_DATA=clean: the Dropbox copy was verified, so remove the local one.
        rm -rf -- "$batch"
        [[ ! -L $KEPT && $KEPT == "$STATE_ROOT/kept" ]] || return 1
        rm -rf -- "${KEPT:?}/$day"
    fi
}

prune_kept() {
    # Remove the oldest verified local copies until $1 MiB is free. Only
    # directories with a verified acknowledgment are ever removed.
    local target=$1 dir name free
    [[ -d $KEPT && ! -L $KEPT && $KEPT == "$STATE_ROOT/kept" ]] || return 0
    while IFS= read -r dir; do
        free=$(free_mib) || return 0
        (( free < target )) || return 0
        name=$(basename -- "$dir")
        [[ ! -L $dir && -f $VERIFIED/$name.json ]] || continue
        log "Local storage low (${free} MiB free): removing verified local copy of $name (it remains in Dropbox)"
        rm -rf -- "$dir"
    done < <(find "$KEPT" -mindepth 1 -maxdepth 1 -type d -name '20??-??-??' | sort)
    free=$(free_mib) || return 0
    (( free >= target )) ||
        log "WARNING: local storage still low (${free} MiB free) and no verified local copies remain to remove"
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
