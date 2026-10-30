#!/usr/bin/env bash
disk_by_id_path() {
    # Stable /dev/disk/by-id name for a whole disk such as /dev/sdb.
    local dev=$1 link
    for link in /dev/disk/by-id/usb-*; do
        [[ -e $link && $link != *-part[0-9]* ]] || continue
        if [[ $(readlink -f -- "$link") == "$dev" ]]; then printf '%s\n' "$link"; return 0; fi
    done
    return 1
}

detect_recorders() {
    # Prints "serial<TAB>by-id path" for each attached USB disk that the
    # Harvester itself identifies as a Pegasus. The OS disk is never probed;
    # probing uses the read-only safe mode.
    local roots name type tran dev serial link
    [[ -x ${PEGASUS_BIN:-} ]] || return 0
    roots=$(lsblk -snp -o NAME "$(findmnt -n -o SOURCE /)" 2>/dev/null || true)
    while read -r name type tran; do
        [[ $type == disk && $tran == usb ]] || continue
        dev=$name
        if printf '%s\n' "$roots" | grep -Fxq "$dev"; then continue; fi
        serial=$(lsblk -dn -o SERIAL "$dev" 2>/dev/null) || continue
        serial=$(trim "$serial")
        valid_station "$serial" || { log "Skipping USB disk $dev: serial unusable as identity ('$serial')"; continue; }
        link=$(disk_by_id_path "$dev") || continue
        local probe rc=0
        probe=$(mktemp) || continue
        timeout -k 5 40 "$PEGASUS_BIN" digitizer-info "-i=$dev" -safe >"$probe" 2>&1 || rc=$?
        if harvester_exit_ok "$rc" && harvester_report_ok "$probe"; then
            rm -f "$probe"
            log "Recorder detected: serial $serial at $dev"
            printf '%s\t%s\n' "$serial" "$link"
        else
            rm -f "$probe"
        fi
    done < <(lsblk -dnpo NAME,TYPE,TRAN 2>/dev/null)
}

identify_recorder() {
    [[ -x $PEGASUS_BIN ]] || { die "Native Harvester executable missing"; return 1; }
    DEVICE=$(readlink -f -- "$RECORDER_DEVICE") || return 1
    [[ -b $DEVICE && $(lsblk -dn -o TYPE "$DEVICE") == disk ]] ||
        { die "Recorder must resolve to a whole block disk"; return 1; }
    local serial roots
    serial=$(lsblk -dn -o SERIAL "$DEVICE") || return 1
    serial=$(trim "$serial")
    [[ $serial == "$RECORDER_SERIAL" ]] || { die "Recorder serial mismatch"; return 1; }
    # Refuse the OS disk, including a root filesystem on LVM/device mapper.
    roots=$(lsblk -snp -o NAME "$(findmnt -n -o SOURCE /)") || return 1
    if printf '%s\n' "$roots" | grep -Fxq "$DEVICE"; then
        die "Refusing the system disk"; return 1
    fi
    local identity_file="$STATE_ROOT/recorder-id"
    if [[ -f $identity_file && $(<"$identity_file") != "$RECORDER_SERIAL" ]]; then
        die "Recorder changed: require deliberate state migration"; return 1
    fi
    if [[ ! -f $identity_file ]]; then
        local temp
        temp=$(mktemp "$STATE_ROOT/identity.XXXXXX") || return 1
        printf '%s\n' "$RECORDER_SERIAL" >"$temp"
        atomic_install "$temp" "$identity_file" || return 1
    fi
    local rc=0
    source_timeout 30 "$PEGASUS_BIN" digitizer-info "-i=$DEVICE" -safe \
        >"$LOG_ROOT/$RUN_ID-digitizer.txt" 2>&1 || rc=$?
    harvester_exit_ok "$rc" && harvester_report_ok "$LOG_ROOT/$RUN_ID-digitizer.txt" || return 1
    log "Recorder identified as $RECORDER_SERIAL at $DEVICE"
}

inspect_volumes() {
    local id output lower upper
    EARLIEST_NS=9223372036854775807 LATEST_NS=0 CLOCK_PRESENT=no
    for id in 1 2 3 4 5 6 7; do
        output="$LOG_ROOT/$RUN_ID-volume-$id.txt"
        local rc=0
        source_timeout 30 "$PEGASUS_BIN" volume-info "-i=$DEVICE" "-id=$id" -safe >"$output" 2>&1 || rc=$?
        # Only an explicit "not found" is optional; I/O/format errors are fatal.
        if grep -Eiq "volume id=$id not found|volume[ #]+$id.*not found" "$output"; then
            [[ $id != 1 ]] || return 1
            continue
        fi
        harvester_exit_ok "$rc" && harvester_report_ok "$output" || return 1
        [[ $id != 3 ]] || CLOCK_PRESENT=yes
        lower=$(sed -nE 's/^[[:space:]]*lower time = ([0-9]+).*/\1/p' "$output")
        upper=$(sed -nE 's/^[[:space:]]*upper time = ([0-9]+).*/\1/p' "$output")
        # Some metadata-only volumes do not expose a time range.
        if [[ -z $lower || -z $upper ]]; then
            [[ $id != 1 ]] || return 1
            log "Volume $id has no time bounds; hardware validation must confirm its export"
            continue
        fi
        [[ $lower =~ ^[0-9]{1,19}$ && $upper =~ ^[0-9]{1,19}$ ]] || return 1
        [[ $lower != 0 && $upper != 0 ]] || continue
        (( lower <= upper && upper <= 9223372036854775807 )) || return 1
        (( lower >= EARLIEST_NS )) || EARLIEST_NS=$lower
        (( upper <= LATEST_NS )) || LATEST_NS=$upper
    done
    (( LATEST_NS > 0 && EARLIEST_NS <= LATEST_NS )) || return 1
    # Do not accept wildly wrong dates as permission for unbounded backfill.
    local now
    now=$(date -u +%s)
    (( EARLIEST_NS / 1000000000 >= 946684800 &&
       LATEST_NS / 1000000000 <= now + 86400 )) || return 1
    log "Available volume-union bounds: $EARLIEST_NS .. $LATEST_NS ns"
}
