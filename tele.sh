#!/usr/bin/env bash
# TELE: a run is deliberately readable from top to bottom.
set -Eeuo pipefail
umask 077
export TZ=UTC LC_ALL=C
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
for library in common config hardware harvest upload starlink notification remote sources workflow; do
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/$library.sh"
done

main() {
    prepare_run "$@" || return "$?"
    [[ $RUN_MODE != help ]] || return 0

    # Check configuration, connections and devices without collecting or powering off.
    if [[ $RUN_MODE == check ]]; then
        check_setup
        return "$?"
    fi

    # Starlink starts with this computer: wait (bounded) for the internet,
    # then load settings and confirm where uploads will go.
    wait_for_internet
    refresh_settings
    check_upload_connection

    # Collect diagnostics, then run each configured recorder/logger independently.
    gather_station_diagnostics
    collect_all_sources

    # Report what actually succeeded, including incomplete or skipped sources.
    upload_station_logs
    send_run_report

    # Only field mode opens the optional maintenance window.
    # systemd, not this script, owns normal and emergency poweroff.
    offer_maintenance_window
    finish_run
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
