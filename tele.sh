#!/usr/bin/env bash
# TELE collector. Only the systemd field service may run this entry point.
set -Eeuo pipefail
umask 077
export TZ=UTC LC_ALL=C
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
for module in common config hardware harvest upload notification remote; do
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/$module.sh"
done

on_exit() {
    local rc=$?
    trap - EXIT
    set +e
    if [[ ${NOTIFIED:-0} == 0 && -n ${LOG_FILE:-} && -n ${EMAIL_PASSWORD:-} ]]; then
        log "Abnormal exit ($rc); attempting failure notification"
        snapshot_log
        send_notification FAILED
    fi
    log "Exit status=$rc; systemd owns shutdown"
    exit "$rc"
}

main() {
    if [[ ${1:-} != --field || $# != 1 ]]; then
        printf 'Field service only. Read docs/VALIDATION.md; do not run on a workstation.\n' >&2
        return 64
    fi
    [[ $EUID == 0 ]] || die "Field service requires root"
    # The timer is armed BEFORE any configuration, credentials or dependencies.
    systemctl is-active --quiet tele-power-guard.timer ||
        die "Independent systemd shutdown timer is not active"
    [[ ${TELE_FIELD_SERVICE:-} == 1 ]] || die "Not started by the field service"
    exec 9>/run/lock/tele.lock
    flock -n 9 || die "Another collection run holds the lock"

    load_node_config /etc/tele/node.conf
    load_local_config /etc/tele/config.txt
    init_workspace
    NOTIFIED=0
    trap on_exit EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    log "TELE $(<"$SCRIPT_DIR/VERSION") station=$STATION_NAME"
    load_credentials /etc/tele/credentials.txt
    check_dependencies
    load_runtime_config
    # Failure to load email does not prevent data recovery.
    verify_remote || die "Dropbox hash verification unavailable"

    local status=SUCCESS pending_ok=yes
    collect_starlink_diagnostics || status=PARTIAL
    # Retry previously harvested data even if the recorder is now unavailable.
    drain_pending || { status=PARTIAL; pending_ok=no; }
    if [[ $pending_ok == yes ]] && identify_recorder && inspect_volumes; then
        harvest_cycle || status=PARTIAL
    else
        log "Recorder unavailable; pending uploads were still attempted"
        status=PARTIAL
    fi
    snapshot_log || status=PARTIAL
    send_notification "$status" || log "Email failed; see persistent local run log"
    NOTIFIED=1
    maintenance_window || log "Maintenance window failed"
    # This final snapshot includes maintenance and email outcomes.
    snapshot_log || log "Final log upload failed; retained locally"
    log "Run complete ($status); field service will power off"
    [[ $status == SUCCESS ]]
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
