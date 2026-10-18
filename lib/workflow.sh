#!/usr/bin/env bash
# Run lifecycle; collector-specific work belongs in modules/, not tele.sh.
usage() {
    printf '%s\n' \
        'Usage: tele.sh --check | --once | --field [--config-dir /etc/tele]' \
        '  --check  Validate setup and inspect connections/devices; no exports, email or shutdown.' \
        '  --once   One real bench collection/upload/email run; no maintenance wait or shutdown.' \
        '  --field  Service-only run; systemd powers off on exit.' \
        'Do not run bench modes while the field service or emergency timer is active.'
}

prepare_run() {
    RUN_MODE='' CONFIG_DIR=/etc/tele
    while (($#)); do
        case "$1" in
            --check|--once|--field)
                [[ -z $RUN_MODE ]] || { usage; return 64; }
                RUN_MODE=${1#--}; shift ;;
            --config-dir)
                [[ $# -ge 2 && $2 == /* ]] || return 64
                CONFIG_DIR=${2%/}; shift 2 ;;
            -h|--help) RUN_MODE=help; usage; return 0 ;;
            *) usage; return 64 ;;
        esac
    done
    [[ -n $RUN_MODE ]] || { usage; return 64; }
    [[ $EUID == 0 ]] || { die "Use sudo for station configuration and recorder access"; return 1; }
    if [[ $RUN_MODE == field ]]; then
        [[ $CONFIG_DIR == /etc/tele && ${TELE_FIELD_SERVICE:-} == 1 ]] ||
            { die "Field runs must be started by tele.service"; return 1; }
        systemctl is-active --quiet tele-power-guard.timer ||
            { die "Emergency shutdown timer is not active"; return 1; }
    else
        if systemctl is-active --quiet tele.service ||
           systemctl is-active --quiet tele-power-guard.timer; then
            die "A field service/timer is active. Arrange controlled maintenance first."
            return 1
        fi
    fi
    exec 9>/run/lock/tele.lock
    flock -n 9 || { die "Another TELE run holds the lock"; return 1; }
    load_node_config "$CONFIG_DIR/node.conf" || return 1
    load_local_config "$CONFIG_DIR/config.txt" || return 1
    init_workspace || return 1
    STATION_STATE_ROOT=$STATE_ROOT STATION_LOG_ROOT=$LOG_ROOT
    STATION_REMOTE_BASE=$REMOTE_BASE STATION_RUN_ID=$RUN_ID
    RUN_STATUS=SUCCESS CLOUD_READY=no NOTIFIED=0
    SOURCES_OK=0 SOURCES_FAILED=0
    trap workflow_exit EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    log "TELE $(<"$SCRIPT_DIR/VERSION") station=$STATION_NAME mode=$RUN_MODE"
    log "Configuration: $CONFIG_DIR; destination: $REMOTE_BASE"
    load_credentials "$CONFIG_DIR/credentials.txt"
    check_dependencies || return 1
}

workflow_exit() {
    local rc=$?
    trap - EXIT
    set +e
    if [[ ${NOTIFIED:-0} == 0 && ${RUN_MODE:-check} != check &&
          -n ${LOG_FILE:-} && -n ${EMAIL_PASSWORD:-} ]]; then
        log "Run stopped unexpectedly (status=$rc); attempting failure report"
        send_notification FAILED
    fi
    if [[ ${RUN_MODE:-} == field ]]; then
        log "Exit=$rc. tele.service owns shutdown."
    else
        log "Exit=$rc. Bench/check mode does not request shutdown."
    fi
    exit "$rc"
}

wait_for_internet() {
    # Starlink is switched on by the same USB relay as this boot and commonly
    # needs several minutes. Without this wait, every field run would find no
    # internet, skip collection and power off again.
    log "1. Wait for Starlink/Dropbox (up to ${NETWORK_WAIT_SECONDS}s)"
    local started now deadline attempt_deadline
    started=$(uptime_seconds)
    deadline=$((started + NETWORK_WAIT_SECONDS))
    while :; do
        now=$(uptime_seconds)
        attempt_deadline=$(( deadline > now + 60 ? deadline : now + 60 ))
        if (COLLECTION_DEADLINE=$attempt_deadline; verify_remote) >>"$LOG_FILE" 2>&1; then
            log "Dropbox reachable after $(( $(uptime_seconds) - started ))s"
            return 0
        fi
        now=$(uptime_seconds)
        (( now + 30 < deadline )) || break
        log "Dropbox not reachable yet; retrying in 30s"
        sleep 30
    done
    log "Internet/Dropbox still unreachable after $(( $(uptime_seconds) - started ))s"
    return 0
}

refresh_settings() {
    log "1b. Load and validate the station's remote settings"
    load_runtime_config || { RUN_STATUS=PARTIAL; log "Using local settings"; }
}

check_upload_connection() {
    log "2. Check Dropbox connectivity and content-hash support"
    if verify_remote; then CLOUD_READY=yes; else
        RUN_STATUS=PARTIAL
        log "Dropbox unavailable/unverified. Keep pending data; skip new acquisition."
    fi
}

gather_station_diagnostics() {
    log "3. Read Starlink diagnostics"
    collect_starlink_diagnostics || { RUN_STATUS=PARTIAL; log "Starlink diagnostics unavailable"; }
    return 0
}

upload_station_logs() {
    log "5. Upload run logs"
    if [[ $CLOUD_READY == yes ]]; then
        snapshot_log || { RUN_STATUS=PARTIAL; log "Log upload incomplete; local logs retained"; }
    fi
}

send_run_report() {
    log "6. Send run report: $RUN_STATUS; sources OK=$SOURCES_OK failed=$SOURCES_FAILED"
    send_notification "$RUN_STATUS" || { RUN_STATUS=PARTIAL; log "Email unavailable; inspect local logs"; }
    NOTIFIED=1
}

offer_maintenance_window() {
    if [[ $RUN_MODE == field ]]; then
        log "7. Optional SSH/VNC maintenance window"
        maintenance_window || { RUN_STATUS=PARTIAL; log "Maintenance setup failed"; }
    else
        log "7. Bench run: no maintenance wait and no poweroff"
    fi
}

finish_run() {
    if [[ $CLOUD_READY == yes ]]; then snapshot_log || RUN_STATUS=PARTIAL; fi
    log "Finished: $RUN_STATUS; sources OK=$SOURCES_OK failed=$SOURCES_FAILED"
    [[ $RUN_STATUS == SUCCESS ]]
}

check_setup() {
    local failed=0 profile
    log "CHECK: local configuration is valid"
    verify_remote || { log "CHECK FAILED: Dropbox access/hash support"; failed=1; }
    discover_sources && validate_source_set || return 1
    for profile in "${SOURCE_FILES[@]}"; do
        if run_source "$profile" check; then
            log "CHECK OK: ${profile##*/}"
        else
            log "CHECK FAILED: ${profile##*/}"; failed=1
        fi
    done
    log "Check complete. No collection, email or shutdown was requested."
    [[ $failed == 0 ]]
}
