#!/usr/bin/env bash
# A provider has four small functions; the main workflow is device-independent.
provider_validate() {
    local key
    for key in "${!SOURCE_SETTINGS[@]}"; do
        case "$key" in TYPE|RECORDER_DEVICE|RECORDER_SERIAL) ;; *) die "Unknown Pegasus setting: $key"; return 1 ;; esac
    done
    RECORDER_DEVICE=${SOURCE_SETTINGS[RECORDER_DEVICE]:-}
    RECORDER_SERIAL=${SOURCE_SETTINGS[RECORDER_SERIAL]:-}
    [[ $RECORDER_DEVICE == /dev/disk/by-id/* && $RECORDER_DEVICE != *-part[0-9]* &&
       $RECORDER_SERIAL =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ||
        { die "Pegasus needs a whole-disk by-id path and expected serial"; return 1; }
}
provider_target() { printf '%s\n' pegasus_harvester; }
provider_check() { identify_recorder && inspect_volumes; }
provider_collect() {
    # Upload recovery does not depend on the recorder being connected today.
    drain_pending || return 1
    provider_check || return 1
    harvest_cycle
}
