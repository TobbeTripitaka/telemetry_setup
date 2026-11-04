#!/usr/bin/env bash
# Deployment records. At deployment the Pegasus stores a JSON description of the
# station (network and station code, channels, sensors, position) in its
# operation log. The Pegasus Harvester application turns each one into a
# StationXML file named NN.SSSS_<UTC time>Z.xml; the command line cannot write
# the XML, but it can read the record. We keep each record as
# NN.SSSS_<UTC time>Z.json in the root of the Nanometrics tree, with the same
# name stem as the XML, so a StationXML can be made from it at any time.
export_deployments() {
    local work messages ts b64 json net sta stamp name rc=0 done_dir="$STATE_ROOT/deployments"
    mkdir -p -- "$done_dir" || return 1
    work=$(mktemp -d "$STATE_ROOT/.deployments.XXXXXX") || return 1
    messages=$work/messages.txt
    local read_rc=0
    source_timeout 120 "$PEGASUS_BIN" read-volume "-i=$DEVICE" -id=5 -safe \
        >"$work/volume5.txt" 2>&1 </dev/null || read_rc=$?
    if ! harvester_exit_ok "$read_rc"; then
        log "Operation log could not be read for deployment records (exit status $read_rc)"
        rm -rf -- "$work"; return 1
    fi
    if grep -a -Eq '<<<ERROR' "$work/volume5.txt"; then
        log "Operation log could not be read for deployment records"
        rm -rf -- "$work"; return 1
    fi
    # Each message holds "timestamp" (ns) and, for a deployment, "opaque_data"
    # (base64 of gzip of the JSON). Prints "<seconds> <base64>" per deployment.
    awk '$1 == "\"timestamp\":" { ts = $2; gsub(/[^0-9]/, "", ts) }
         $1 == "\"opaque_data\":" { v = $2; gsub(/[",]/, "", v); if (ts != "" && v != "") print substr(ts, 1, 10), v }' \
        "$work/volume5.txt" >"$messages"
    while read -r ts b64; do
        json=$work/$ts.json
        if ! printf '%s' "$b64" | base64 -d 2>/dev/null | gzip -dc >"$json" 2>/dev/null ||
           ! net=$(jq -er '.station.networkCode' "$json" 2>/dev/null) ||
           ! sta=$(jq -er '.station.stationCode' "$json" 2>/dev/null) ||
           [[ ! $net =~ ^[A-Za-z0-9_-]{1,8}$ || ! $sta =~ ^[A-Za-z0-9_-]{1,16}$ ]]; then
            log "WARNING: a deployment record in the operation log could not be decoded (time $ts)"
            rc=1; continue
        fi
        stamp=$(date -u -d "@$ts" +%Y%m%dT%H%M%SZ) || { rc=1; continue; }
        name="$net.${sta}_$stamp.json"
        [[ ! -e $done_dir/$name ]] || continue
        cloud copyto "$json" "$REMOTE_DATA/$name" --checksum >>"$LOG_FILE" 2>&1 || { rc=1; continue; }
        if [[ ${LOCAL_DATA:-keep} == keep ]]; then
            mkdir -p -- "$LOCAL_ARCHIVE" &&
                install -m 644 -- "$json" "$LOCAL_ARCHIVE/$name" || { rc=1; continue; }
            chown --reference="$LOCAL_ARCHIVE" -- "$LOCAL_ARCHIVE/$name" 2>/dev/null || true
        fi
        : >"$done_dir/$name" || { rc=1; continue; }
        log "Deployment record uploaded: $name"
    done <"$messages"
    rm -rf -- "$work"
    return "$rc"
}
