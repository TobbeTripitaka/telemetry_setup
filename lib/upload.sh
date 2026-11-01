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
    # identical content is harmless. Different content under one path is not:
    # for waveform data (first folder is a year) it stops the run; for logs and
    # other non-waveform files it is recorded in the optional conflicts file
    # (4th argument) and uploaded under a second name, never overwriting.
    # Owner lines 3+ list the hashes of second versions already uploaded; the
    # same second version re-exported on a later day is listed in the skips
    # file (5th argument) instead of being uploaded again.
    local root=$1 day=$2 sums=${3:-} conflicts=${4:-} skips=${5:-}
    local file rel key owner temp hash claimed stored variants
    while IFS= read -r -d '' file; do
        rel=${file#"$root/"}
        key=$(printf '%s' "${rel,,}" | sha256sum)
        key=${key%% *}
        owner="$OWNERS/$key"
        hash=''
        if [[ -n $sums ]]; then
            hash=$(awk -v p="$rel" 'length($0) > 66 && substr($0, 67) == p {print substr($0, 1, 64); exit}' "$sums")
        fi
        claimed='' stored='' variants=''
        if [[ -f $owner ]]; then
            { IFS= read -r claimed; IFS= read -r stored; variants=$(cat); } <"$owner" || true
            if [[ $claimed != "$day:$rel" ]]; then
                if [[ -n $hash && $stored == "$hash" ]]; then
                    log "Identical file re-exported in $day, already claimed by ${claimed%%:*}: $rel"
                    continue
                fi
                if [[ -n $skips && -n $hash && $rel != [0-9][0-9][0-9][0-9]/* &&
                      $'\n'$variants$'\n' == *$'\n'"$hash"$'\n'* ]]; then
                    log "Same second version of $rel already uploaded; skipping it in $day"
                    printf '%s\n' "$rel" >>"$skips" || return 1
                    continue
                fi
                if [[ -n $conflicts && -n $hash && $rel != [0-9][0-9][0-9][0-9]/* ]]; then
                    log "WARNING: $rel differs from the copy already uploaded for ${claimed%%:*}; keeping both"
                    printf '%s\n' "$rel" >>"$conflicts" || return 1
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

prepare_filtered_upload() {
    # Writes an rclone exclude list for the main copy and a Dropbox-hash list
    # for verification: skipped files are left out, and each conflicting file
    # carries its second name.
    local batch=$1 day=$2 conflicts=$3 skips=$4 verify=$5 rel
    local exclude=$batch/upload-exclude.txt sums=$batch/dropbox.sum omit=$batch/upload-omit.txt
    : >"$exclude" || return 1
    cat -- "$conflicts" "$skips" >"$omit" || return 1
    while IFS= read -r rel; do
        # rclone patterns: escape glob characters; the leading slash anchors.
        # shellcheck disable=SC2001  # bracket-class escaping is clearer with sed
        printf '/%s\n' "$(sed 's/[][*?{}]/\\&/g' <<<"$rel")" >>"$exclude" || return 1
    done <"$omit"
    awk 'NR == FNR {skip[$0]; next} !(substr($0, 67) in skip)' "$omit" "$sums" >"$verify" || return 1
    while IFS= read -r rel; do
        awk -v p="$rel" -v d="$day" 'length($0) > 66 && substr($0, 67) == p {print substr($0, 1, 66) p ".conflict-" d; exit}' \
            "$sums" >>"$verify" || return 1
    done <"$conflicts"
}

record_second_versions() {
    # Called only after the second versions are verified in Dropbox.
    local batch=$1 conflicts=$2 rel key owner hash temp
    while IFS= read -r rel; do
        key=$(printf '%s' "${rel,,}" | sha256sum)
        owner="$OWNERS/${key%% *}"
        hash=$(awk -v p="$rel" 'length($0) > 66 && substr($0, 67) == p {print substr($0, 1, 64); exit}' "$batch/dropbox.sum")
        [[ -f $owner && -n $hash ]] || continue
        temp=$(mktemp "$OWNERS/.new.XXXXXX") || return 1
        { cat -- "$owner"; printf '%s\n' "$hash"; } >"$temp" || return 1
        atomic_install "$temp" "$owner" || return 1
    done <"$conflicts"
}

upload_batch() {
    local batch=$1 day force temp rel verify
    local conflicts=$batch/conflicts.txt skips=$batch/skips.txt
    validate_batch "$batch" || { die "Pending batch integrity check failed: $batch"; return 1; }
    day=$(jq -r .day "$batch/meta.json")
    force=$(jq -r .force "$batch/meta.json")
    : >"$conflicts" || return 1
    : >"$skips" || return 1
    claim_paths "$batch/files" "$day" "$batch/dropbox.sum" "$conflicts" "$skips" || return 1
    local -a flags=(--checksum) exclude=()
    [[ $force != yes ]] || flags=(--ignore-times)
    verify=$batch/dropbox.sum
    if [[ -s $conflicts || -s $skips ]]; then
        verify=$batch/upload-verify.sum
        prepare_filtered_upload "$batch" "$day" "$conflicts" "$skips" "$verify" || return 1
        exclude=(--exclude-from "$batch/upload-exclude.txt")
    fi
    # An acknowledgment belongs to the destination actually verified, not just a day.
    jq --arg destination "$REMOTE_DATA" '.destination=$destination' \
        "$batch/meta.json" >"$batch/receipt.json" || return 1
    if [[ ! -s $verify ]]; then
        # Nothing new: every file is already in Dropbox from an earlier day.
        log "Nothing new to upload for $day"
    else
        log "Uploading/verifying $day force=$force"
        cloud copy "$batch/files" "$REMOTE_DATA" --no-traverse "${flags[@]}" "${exclude[@]}" \
            >>"$LOG_FILE" 2>&1 || return 1
        if [[ -s $conflicts ]]; then
            while IFS= read -r rel; do
                log "Uploading second version as $rel.conflict-$day"
                cloud copyto "$batch/files/$rel" "$REMOTE_DATA/$rel.conflict-$day" "${flags[@]}" \
                    >>"$LOG_FILE" 2>&1 || return 1
            done <"$conflicts"
        fi
        cloud check "$verify" "$REMOTE_DATA" --checkfile Dropbox --one-way \
            >>"$LOG_FILE" 2>&1 || return 1
        record_second_versions "$batch" "$conflicts" || return 1
        # Small remote receipts to diagnose/rebuild local state later: ONE
        # transfer for all of them (every round trip is slow on a patchy link).
        rm -rf -- "$batch/receipt-out" && mkdir "$batch/receipt-out" || return 1
        cp -- "$batch/receipt.json" "$batch/receipt-out/$day.json" || return 1
        cp -- "$batch/dropbox.sum" "$batch/receipt-out/$day.dropbox.sum" || return 1
        [[ ! -f $batch/harvest.log ]] || cp -- "$batch/harvest.log" "$batch/receipt-out/$day.harvest.log" || return 1
        [[ ! -s $conflicts ]] || cp -- "$conflicts" "$batch/receipt-out/$day.conflicts.txt" || return 1
        cloud copy "$batch/receipt-out" "$REMOTE_BASE/tele_logfiles/receipts/$RECORDER_SERIAL" \
            --no-traverse --checksum >>"$LOG_FILE" 2>&1 || return 1
    fi
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
