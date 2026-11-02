#!/usr/bin/env bash
# Read-only overview of what is on this computer and where: tele.sh --status.
# It changes nothing, needs no network and does not stop a running service.

status_size_mib() {
    # Size in MiB of a folder tree; 0 when it does not exist.
    local mib
    [[ -d $1 ]] || { printf '0\n'; return 0; }
    mib=$(du -sm -- "$1" 2>/dev/null | cut -f1)
    printf '%s\n' "${mib:-0}"
}

status_list_days() {
    # Names of the day folders (YYYY-MM-DD) in a folder, oldest first.
    [[ -d $1 ]] || return 0
    find "$1" -mindepth 1 -maxdepth 1 -type d -name '20??-??-??' -printf '%f\n' | LC_ALL=C sort
}

status_one_source() {
    local dir=$1 id=$2 days count first last files
    printf '\nRecorder %s\n  Folder    %s\n' "$id" "$dir"
    days=$(status_list_days "$dir/pending")
    count=$(grep -c . <<<"$days" || true)
    if ((count)); then
        printf '  Waiting   %s day(s), %s MiB, from %s to %s: not yet uploaded (retried at the next wake)\n' \
            "$count" "$(status_size_mib "$dir/pending")" "$(head -n1 <<<"$days")" "$(tail -n1 <<<"$days")"
    else
        printf '  Waiting   nothing: everything exported has been uploaded\n'
    fi
    files=$(find "$dir/verified" -maxdepth 1 -type f -name '20??-??-??.json' -printf '%f\n' 2>/dev/null | LC_ALL=C sort || true)
    count=$(grep -c . <<<"$files" || true)
    if ((count)); then
        first=${files%%$'\n'*} last=$(tail -n1 <<<"$files")
        printf '  Uploaded  %s day(s) verified in Dropbox, %s to %s\n' "$count" "${first%.json}" "${last%.json}"
    else
        printf '  Uploaded  no day verified yet\n'
    fi
    days=$(status_list_days "$dir/kept")
    count=$(grep -c . <<<"$days" || true)
    if ((count)); then
        printf '  Local copy %s day(s), %s MiB, in kept/<day>/files/ (native Harvester paths); LOCAL_DATA=%s\n' \
            "$count" "$(status_size_mib "$dir/kept")" "${LOCAL_DATA:-keep}"
    fi
    count=$(find "$dir/quarantine" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    ((count == 0)) || printf '  Set aside %s damaged batch(es) in quarantine/ (the days are exported again)\n' "$count"
    printf '  (owners/ holds one small hash-named record per uploaded file; it is bookkeeping, not data)\n'
}

status_report() {
    local latest src id others base version
    version=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo unknown)
    printf 'TELE %s, station %s%s\n' "$version" "$STATION_NAME" "${LOCATION:+ ($LOCATION)}"
    if [[ -e ${CONFIG_DIR:-/etc/tele}/FIELD_ENABLED ]]; then
        printf 'Mode: field mode is ON (powers off after each run; keep it on with: sudo tele-maintenance on)\n'
    else
        printf 'Mode: bench (field mode off; the computer stays on)\n'
    fi
    printf 'Free disk: %s MiB\n' "$(free_mib 2>/dev/null || echo unknown)"
    latest=$(ls -1t "$LOG_ROOT"/*.log 2>/dev/null | head -n1 || true)
    printf '\nWhere things are\n'
    printf '  Settings   %s  (config.txt, node.conf, credentials.txt)\n' "${CONFIG_DIR:-/etc/tele}"
    printf '  Code       /opt/tele/current\n'
    printf '  Run logs   %s  (latest: %s)\n' "$LOG_ROOT" "${latest:-none yet}"
    printf '  Dropbox    %s\n' "$REMOTE_BASE"
    printf '  Data       %s/sources/<recorder serial>/{pending,verified,kept}\n' "$STATE_ROOT"
    base=$(dirname -- "$STATE_ROOT")
    if [[ -d $STATE_ROOT/sources ]] && find "$STATE_ROOT/sources" -mindepth 1 -maxdepth 1 -type d | grep -q .; then
        while IFS= read -r src; do
            id=$(basename -- "$src")
            status_one_source "$src" "$id"
        done < <(find "$STATE_ROOT/sources" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)
    else
        status_one_source "$STATE_ROOT" "(single recorder layout)"
    fi
    others=$(find "$base" -mindepth 1 -maxdepth 1 -type d ! -name "$STATION_NAME" -printf '%f ' 2>/dev/null || true)
    [[ -z $others ]] || printf '\nOther station folders on this computer (from an earlier name, not used now): %s\n' "$others"
    printf '\nThe empty folders pending/, verified/, owners/ and kept/ directly under %s belong to the single-recorder layout and are unused here.\n' "$STATE_ROOT"
}
