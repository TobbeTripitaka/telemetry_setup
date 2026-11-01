#!/usr/bin/env bash
# Runs locally only. Never accesses a recorder, network, real credentials or poweroff.
set -Eeuo pipefail
export TZ=UTC LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/tele.sh"
BASE=$(mktemp -d)
trap 'rm -rf -- "$BASE"' EXIT
PASS=0 FAIL=0

setup_test() {
    STATE_ROOT="$BASE/$TEST"
    SPOOL="$STATE_ROOT/pending" VERIFIED="$STATE_ROOT/verified" OWNERS="$STATE_ROOT/owners"
    KEPT="$STATE_ROOT/kept" LOG_ROOT="$STATE_ROOT/logs"
    LOG_FILE="$LOG_ROOT/run.log" RUN_ID=test-run RECORDER_SERIAL=test-recorder
    REMOTE_BASE="$STATE_ROOT/remote"
    REMOTE_DATA="$REMOTE_BASE/pegasus_harvester"
    mkdir -p "$SPOOL" "$VERIFIED" "$OWNERS" "$KEPT" "$LOG_ROOT" "$REMOTE_DATA"
    touch "$LOG_FILE"
    runtime_defaults
    station=test-station STATION_NAME=test-station
    NETWORK_TIMEOUT_SECONDS=10
    PEGASUS_BIN="$ROOT/tests/fake-harvester.sh" DEVICE=/dev/never-used CLOCK_PRESENT=no
    HARVEST_USED_SECONDS=0 FAULT=none
    export MOCK_HARVEST_MODE=ok
}

cloud() {
    printf '%s\n' "$*" >>"$STATE_ROOT/cloud-calls"
    if [[ $FAULT == copy && $1 == copy ]]; then return 9; fi
    if [[ $FAULT == check && $1 == check && $3 == "$REMOTE_DATA" ]]; then return 9; fi
    if [[ $FAULT == receipt && $1 == copy && $2 == *receipt-out* ]]; then return 9; fi
    timeout -k 1 10 rclone --config /dev/null "$@" --retries 1 --low-level-retries 1 \
        --log-level ERROR
}
disk_has_reserve() { [[ ${DISK_FULL:-no} == no ]]; }
batch() { harvest_day 1735689600 1735776000 incremental none 5; }
expect_failure() { if "$@"; then printf 'Unexpected success: %s\n' "$*" >&2; return 1; fi; }

test_config_no_execution() {
    printf 'EXECUTE=$(touch %s/INJECTED)\n' "$STATE_ROOT" >"$STATE_ROOT/config"
    expect_failure read_kv "$STATE_ROOT/config" runtime_key
    [[ ! -e $STATE_ROOT/INJECTED ]]
}
test_config_unknown_key() {
    printf 'PEGASUS_BIN=/tmp/evil\n' >"$STATE_ROOT/config"
    expect_failure read_kv "$STATE_ROOT/config" runtime_key
}
test_config_duplicate() {
    printf 'EXECUTE=auto\nEXECUTE=ssh\n' >"$STATE_ROOT/config"
    expect_failure read_kv "$STATE_ROOT/config" runtime_key
}
test_config_limits() {
    expect_failure runtime_key HARVEST_BUDGET_SECONDS 3601
    expect_failure runtime_key MAINTENANCE_IDLE_SECONDS 0.5
    expect_failure runtime_key FROM_DATE 2025-02-30
    runtime_key MAINTENANCE_IDLE_SECONDS 600
}
test_config_literal_spaces() {
    printf ' HARVEST_MODE = "reconcile"\r\nREQUEST_ID=scan-1' >"$STATE_ROOT/config"
    read_kv "$STATE_ROOT/config" runtime_key
    validate_runtime
    [[ $HARVEST_MODE == reconcile && $REQUEST_ID == scan-1 ]]
}
test_config_requires_request_id() {
    HARVEST_MODE=reupload REQUEST_ID=''
    expect_failure validate_runtime
}
test_config_atomic_rejection() {
    printf 'station=test-station\nEXECUTE=auto\n' >"$STATE_ROOT/config.txt"
    printf 'station=test-station\nEXECUTE=ssh\nUNKNOWN=bad\n' >"$REMOTE_BASE/config.txt"
    RCLONE_REMOTE=unused
    load_runtime_config
    [[ $EXECUTE == auto && $(<"$STATE_ROOT/config.txt") == $'station=test-station\nEXECUTE=auto' ]]
}

test_local_station_required() {
    printf 'EXECUTE=auto\n' >"$STATE_ROOT/local.conf"
    chmod 600 "$STATE_ROOT/local.conf"
    expect_failure load_local_config "$STATE_ROOT/local.conf"
}
test_local_config_requires_private_permissions() {
    printf 'station=field01\n' >"$STATE_ROOT/local.conf"
    chmod 644 "$STATE_ROOT/local.conf"
    expect_failure load_local_config "$STATE_ROOT/local.conf"
}
test_station_sets_all_paths() {
    printf 'station=FIELD-01\nEXECUTE=ssh\n' >"$STATE_ROOT/local.conf"
    chmod 600 "$STATE_ROOT/local.conf"
    load_local_config "$STATE_ROOT/local.conf"
    RCLONE_REMOTE=tele_dropbox DROPBOX_ROOT=my_dropbox_path
    set_station_paths
    [[ $STATION_NAME == FIELD-01 && $EXECUTE == ssh &&
       $REMOTE_BASE == tele_dropbox:my_dropbox_path/tele/FIELD-01 &&
       $REMOTE_DATA == tele_dropbox:my_dropbox_path/tele/FIELD-01/pegasus_harvester &&
       $STATE_ROOT == /var/lib/tele/FIELD-01 && $LOG_ROOT == /var/log/tele/FIELD-01 ]]
}
test_station_at_remote_root() {
    STATION_NAME=field01 RCLONE_REMOTE=tele_dropbox DROPBOX_ROOT=''
    set_station_paths
    [[ $REMOTE_BASE == tele_dropbox:tele/field01 ]]
}
test_station_namespaces_do_not_mix() {
    RCLONE_REMOTE=tele_dropbox DROPBOX_ROOT=my_dropbox_path STATION_NAME=field01
    set_station_paths
    local old_state=$STATE_ROOT old_remote=$REMOTE_BASE
    STATION_NAME=field02
    set_station_paths
    [[ $STATE_ROOT != "$old_state" && $REMOTE_BASE != "$old_remote" &&
       $SPOOL == /var/lib/tele/field02/pending && $VERIFIED == /var/lib/tele/field02/verified ]]
}
test_station_rejects_unsafe_labels() {
    local value
    for value in '' . .. ../other 'bad/name' 'bad\name' 'has space' '$HOME' \
                 '$(touch hacked)' '-option' 'remote:path'; do
        expect_failure runtime_key station "$value"
    done
    expect_failure runtime_key station "$(printf '%065d' 0)"
}
test_station_duplicate_rejected() {
    printf 'station=field01\nstation=field02\n' >"$STATE_ROOT/config"
    expect_failure read_kv "$STATE_ROOT/config" runtime_key
}
test_station_key_is_lowercase() {
    printf 'STATION=field01\n' >"$STATE_ROOT/config"
    expect_failure read_kv "$STATE_ROOT/config" runtime_key
}
test_station_is_not_a_node_setting() {
    expect_failure node_key station field01
    expect_failure node_key STATION_NAME field01
}
test_matching_remote_station_applied() {
    printf 'station=test-station\nEXECUTE=vnc\n' >"$REMOTE_BASE/config.txt"
    load_runtime_config
    [[ $station == test-station && $STATION_NAME == test-station && $EXECUTE == vnc ]]
}
test_remote_station_mismatch_preserves_cache_and_paths() {
    local old_remote=$REMOTE_BASE old_state=$STATE_ROOT
    printf 'station=test-station\nEXECUTE=ssh\n' >"$STATE_ROOT/config.txt"
    printf 'station=another-station\nEXECUTE=vnc\n' >"$REMOTE_BASE/config.txt"
    load_runtime_config
    [[ $station == test-station && $STATION_NAME == test-station && $EXECUTE == ssh &&
       $REMOTE_BASE == "$old_remote" && $STATE_ROOT == "$old_state" &&
       $(<"$STATE_ROOT/config.txt") == $'station=test-station\nEXECUTE=ssh' ]]
}
test_remote_missing_station_rejected() {
    EXECUTE=ssh
    printf 'EXECUTE=vnc\n' >"$REMOTE_BASE/config.txt"
    load_runtime_config
    [[ $EXECUTE == ssh && $station == test-station && ! -f $STATE_ROOT/config.txt ]]
}
test_cached_wrong_station_ignored() {
    EXECUTE=ssh
    printf 'station=another-station\nEXECUTE=vnc\n' >"$STATE_ROOT/config.txt"
    load_runtime_config
    [[ $EXECUTE == ssh && $station == test-station && $STATION_NAME == test-station ]]
}
test_node_config_without_station_label() {
    printf '%s\n' 'RCLONE_REMOTE=tele_dropbox' 'RECORDER_SERIAL=test-recorder' \
        'RECORDER_DEVICE=/dev/disk/by-id/test-recorder' >"$STATE_ROOT/node.conf"
    chmod 600 "$STATE_ROOT/node.conf"
    load_node_config "$STATE_ROOT/node.conf"
    [[ -z $STATION_NAME && $RCLONE_REMOTE == tele_dropbox ]]
}
test_renamed_service_paths() {
    [[ -x $ROOT/tele.sh && ! -e $ROOT/tele1.sh ]]
    grep -Fxq 'ExecStart=/opt/tele/current/tele.sh --field' "$ROOT/systemd/tele.service"
    grep -Fxq 'Environment=TELE_FIELD_SERVICE=1' "$ROOT/systemd/tele.service"
    grep -Fxq 'Requires=tele-power-guard.timer' "$ROOT/systemd/tele.service"
    grep -Fxq 'Unit=tele-poweroff.service' "$ROOT/systemd/tele-power-guard.timer"
}
test_success_roundtrip() {
    batch
    upload_batch "$SPOOL/2025-01-01"
    [[ -f $VERIFIED/2025-01-01.json && -d $KEPT/2025-01-01 && ! -d $SPOOL/2025-01-01 ]]
    cloud check "$KEPT/2025-01-01/dropbox.sum" "$REMOTE_DATA" --checkfile Dropbox --one-way
}
test_failed_harvest_not_ready() {
    export MOCK_HARVEST_MODE=fail
    expect_failure batch
    [[ ! -d $SPOOL/2025-01-01 && ! -f $VERIFIED/2025-01-01.json ]]
}
test_hung_harvest_timeout() {
    export MOCK_HARVEST_MODE=hang
    local before=$SECONDS
    expect_failure harvest_day 1735689600 1735776000 incremental none 1
    (( SECONDS - before < 5 ))
    [[ ! -d $SPOOL/2025-01-01 ]]
}
test_partial_file_not_uploaded() {
    mkdir "$SPOOL/.partial-example"
    printf 'partial' >"$SPOOL/.partial-example/bad"
    drain_pending
    [[ ! -s $STATE_ROOT/cloud-calls ]]
}
test_local_corruption_blocks_upload() {
    batch
    printf 'corrupt' >>"$SPOOL/2025-01-01/files/2025/XX/TEST/BHZ.D/2025-01-01.mseed"
    expect_failure upload_batch "$SPOOL/2025-01-01"
    [[ ! -f $VERIFIED/2025-01-01.json ]]
}
test_extra_local_file_blocks_upload() {
    batch
    touch "$SPOOL/2025-01-01/files/extra"
    expect_failure upload_batch "$SPOOL/2025-01-01"
}
test_failed_copy_retains_pending() {
    batch
    FAULT=copy
    expect_failure upload_batch "$SPOOL/2025-01-01"
    [[ -d $SPOOL/2025-01-01 && ! -f $VERIFIED/2025-01-01.json ]]
}
test_failed_verification_retains_pending() {
    batch
    FAULT=check
    expect_failure upload_batch "$SPOOL/2025-01-01"
    [[ -d $SPOOL/2025-01-01 && ! -f $VERIFIED/2025-01-01.json ]]
}
test_retry_after_failed_verification() {
    batch
    FAULT=check
    expect_failure upload_batch "$SPOOL/2025-01-01"
    FAULT=none
    drain_pending
    [[ -f $VERIFIED/2025-01-01.json ]]
}
test_failed_receipt_retains_pending() {
    batch
    FAULT=receipt
    expect_failure upload_batch "$SPOOL/2025-01-01"
    [[ -d $SPOOL/2025-01-01 && ! -f $VERIFIED/2025-01-01.json ]]
}
test_pending_retry_without_recorder() {
    batch
    PEGASUS_BIN=/nonexistent/harvester
    drain_pending
    [[ -f $VERIFIED/2025-01-01.json ]]
}
test_unrelated_remote_file_preserved() {
    printf unrelated >"$REMOTE_DATA/keep-me"
    batch
    upload_batch "$SPOOL/2025-01-01"
    [[ $(<"$REMOTE_DATA/keep-me") == unrelated ]]
}
test_wrong_remote_content_repaired() {
    batch
    cloud copy "$SPOOL/2025-01-01/files" "$REMOTE_DATA"
    printf wrong >"$REMOTE_DATA/2025/XX/TEST/BHZ.D/2025-01-01.mseed"
    upload_batch "$SPOOL/2025-01-01"
    cloud check "$KEPT/2025-01-01/dropbox.sum" "$REMOTE_DATA" --checkfile Dropbox --one-way
}
test_native_name_collision_stops() {
    mkdir "$STATE_ROOT/a" "$STATE_ROOT/b"
    printf one >"$STATE_ROOT/a/shared.log"
    printf two >"$STATE_ROOT/b/shared.log"
    claim_paths "$STATE_ROOT/a" 2025-01-01
    expect_failure claim_paths "$STATE_ROOT/b" 2025-01-02
}
test_identical_reexport_across_days_allowed() {
    mkdir "$STATE_ROOT/a" "$STATE_ROOT/b"
    printf same >"$STATE_ROOT/a/shared.log"
    printf same >"$STATE_ROOT/b/shared.log"
    cloud hashsum Dropbox "$STATE_ROOT/a" --output-file "$STATE_ROOT/a.sum"
    cloud hashsum Dropbox "$STATE_ROOT/b" --output-file "$STATE_ROOT/b.sum"
    claim_paths "$STATE_ROOT/a" 2025-01-01 "$STATE_ROOT/a.sum"
    claim_paths "$STATE_ROOT/b" 2025-01-02 "$STATE_ROOT/b.sum"
}
test_changed_reexport_across_days_stops() {
    mkdir "$STATE_ROOT/a" "$STATE_ROOT/b"
    printf one >"$STATE_ROOT/a/shared.log"
    printf two >"$STATE_ROOT/b/shared.log"
    cloud hashsum Dropbox "$STATE_ROOT/a" --output-file "$STATE_ROOT/a.sum"
    cloud hashsum Dropbox "$STATE_ROOT/b" --output-file "$STATE_ROOT/b.sum"
    claim_paths "$STATE_ROOT/a" 2025-01-01 "$STATE_ROOT/a.sum"
    expect_failure claim_paths "$STATE_ROOT/b" 2025-01-02 "$STATE_ROOT/b.sum"
}
test_changed_log_across_days_kept_under_second_name() {
    local log=logs/2025/XX/TEST/LOG.D/XX.TEST..LOG.D.2025.001.txt
    MOCK_LOG_CONTENT=first harvest_day 1735689600 1735776000 incremental none 5
    upload_batch "$SPOOL/2025-01-01"
    MOCK_LOG_CONTENT=second harvest_day 1735776000 1735862400 incremental none 5
    upload_batch "$SPOOL/2025-01-02"
    [[ $(<"$REMOTE_DATA/$log") == first ]]
    [[ $(<"$REMOTE_DATA/$log.conflict-2025-01-02") == second ]]
    [[ -f $REMOTE_DATA/2025/XX/TEST/BHZ.D/2025-01-02.mseed ]]
    [[ -f $VERIFIED/2025-01-02.json ]]
    # The same second version on later days is not uploaded again, and a day
    # with nothing new needs no Dropbox traffic at all.
    : >"$STATE_ROOT/cloud-calls"
    MOCK_NO_WAVEFORM=1 MOCK_LOG_CONTENT=second harvest_day 1735862400 1735948800 incremental none 5
    upload_batch "$SPOOL/2025-01-03"
    [[ ! -e $REMOTE_DATA/$log.conflict-2025-01-03 ]]
    [[ -f $VERIFIED/2025-01-03.json ]]
    ! grep -q -E '^(copy|copyto) ' "$STATE_ROOT/cloud-calls"
    # A third, different version is still kept.
    MOCK_NO_WAVEFORM=1 MOCK_LOG_CONTENT=third harvest_day 1735948800 1736035200 incremental none 5
    upload_batch "$SPOOL/2025-01-04"
    [[ $(<"$REMOTE_DATA/$log.conflict-2025-01-04") == third ]]
}
test_changed_waveform_across_days_still_stops() {
    mkdir -p "$STATE_ROOT/a/2025/XX" "$STATE_ROOT/b/2025/XX"
    printf one >"$STATE_ROOT/a/2025/XX/f.mseed"
    printf two >"$STATE_ROOT/b/2025/XX/f.mseed"
    cloud hashsum Dropbox "$STATE_ROOT/a" --output-file "$STATE_ROOT/a.sum"
    cloud hashsum Dropbox "$STATE_ROOT/b" --output-file "$STATE_ROOT/b.sum"
    claim_paths "$STATE_ROOT/a" 2025-01-01 "$STATE_ROOT/a.sum" "$STATE_ROOT/c.txt"
    expect_failure claim_paths "$STATE_ROOT/b" 2025-01-02 "$STATE_ROOT/b.sum" "$STATE_ROOT/c.txt"
}
test_email_retries_and_reports_the_reason() {
    mkdir -p "$BASE/fakebin"
    printf '#!/usr/bin/env bash\necho x >>"%s/curl-calls"\necho "curl: (67) Login denied" >&2\nexit 67\n' "$BASE" >"$BASE/fakebin/curl"
    chmod +x "$BASE/fakebin/curl"
    EMAIL_TO=a@example.com EMAIL_FROM=b@example.com EMAIL_PASSWORD=secretsecret1234 EMAIL_RETRY_SECONDS=0
    HARVEST_MODE=incremental EXECUTE=auto MAINTENANCE_IDLE_SECONDS=600
    PATH="$BASE/fakebin:$PATH" expect_failure send_notification TEST
    [[ $(wc -l <"$BASE/curl-calls") == 3 ]]
    [[ $EMAIL_ERROR == *'curl status 67'*'Login denied'* ]]
    ! grep -q secretsecret1234 "$LOG_FILE"
}
test_location_label_in_email_and_validation() {
    mkdir -p "$BASE/fakebin2"
    printf '#!/usr/bin/env bash\nwhile (($#)); do [[ $1 == --upload-file ]] && cp -- "$2" "%s/mail.txt"; shift; done\n' "$BASE" >"$BASE/fakebin2/curl"
    chmod +x "$BASE/fakebin2/curl"
    EMAIL_TO=a@example.com EMAIL_FROM=b@example.com EMAIL_PASSWORD=secretsecret1234
    HARVEST_MODE=incremental EXECUTE=auto MAINTENANCE_IDLE_SECONDS=600 LOCATION="Carey Ntk"
    PATH="$BASE/fakebin2:$PATH" send_notification SUCCESS
    grep -q $'^Subject: TELE test-station (Carey Ntk) SUCCESS\r' "$BASE/mail.txt"
    grep -q '^Location: Carey Ntk' "$BASE/mail.txt"
    LOCATION=''
    PATH="$BASE/fakebin2:$PATH" send_notification SUCCESS
    grep -q $'^Subject: TELE test-station SUCCESS\r' "$BASE/mail.txt"
    valid_location MtBrown && valid_location "Mt. Brown (South)"
    expect_failure valid_location ' x'; expect_failure valid_location 'a;b'
    expect_failure valid_location "$(printf 'a%.0s' {1..61})"
    printf 'LOCATION=Carey Ntk\nRCLONE_REMOTE=r\n' >"$STATE_ROOT/node.conf"; chmod 600 "$STATE_ROOT/node.conf"
    load_node_config "$STATE_ROOT/node.conf"
    [[ $LOCATION == 'Carey Ntk' ]]
}
test_installation_email_lists_setup_details_only_for_the_install_check() {
    mkdir -p "$BASE/fakebin3"
    printf '#!/usr/bin/env bash\nwhile (($#)); do [[ $1 == --upload-file ]] && cp -- "$2" "%s/mail3.txt"; shift; done\n' "$BASE" >"$BASE/fakebin3/curl"
    chmod +x "$BASE/fakebin3/curl"
    EMAIL_TO=a@example.com EMAIL_FROM=b@example.com EMAIL_PASSWORD=secretsecret1234
    HARVEST_MODE=incremental EXECUTE=auto MAINTENANCE_IDLE_SECONDS=600 LOCATION=''
    INSTALL_DETAILS=$'Account:   cad1\nPassword:  p4ss word'
    PATH="$BASE/fakebin3:$PATH" send_notification INSTALLATION_CHECK
    grep -q '^Setup details' "$BASE/mail3.txt"; grep -q '^Password:  p4ss word' "$BASE/mail3.txt"
    PATH="$BASE/fakebin3:$PATH" send_notification SUCCESS
    ! grep -q 'p4ss' "$BASE/mail3.txt"
    ! grep -q 'p4ss' "$LOG_FILE"
    unset INSTALL_DETAILS
}
test_run_limit_stops_network_calls() {
    uptime_seconds() { echo 5000; }
    RUN_DEADLINE=4000 expect_failure source_timeout 30 true
    [[ $(RUN_DEADLINE=4000 source_timeout 30 true; echo $?) == 124 ]]
    RUN_DEADLINE=9000 source_timeout 30 true
    RUN_MODE=once set_run_deadline; [[ -z ${RUN_DEADLINE:-} ]]
    RUN_MODE=field RUN_LIMIT_SECONDS=7200 set_run_deadline; [[ $RUN_DEADLINE == 7200 ]]
    run_limit_reached && return 1
    uptime_seconds() { echo 8000; }
    run_limit_reached
    expect_failure runtime_key RUN_LIMIT_SECONDS 1799
    runtime_key RUN_LIMIT_SECONDS 7200
    unset RUN_DEADLINE
}
test_open_day_update_rewrites_claim() {
    mkdir "$STATE_ROOT/a"
    printf one >"$STATE_ROOT/a/day.mseed"
    cloud hashsum Dropbox "$STATE_ROOT/a" --output-file "$STATE_ROOT/a.sum"
    claim_paths "$STATE_ROOT/a" 2025-01-01 "$STATE_ROOT/a.sum"
    printf longer >"$STATE_ROOT/a/day.mseed"
    cloud hashsum Dropbox "$STATE_ROOT/a" --output-file "$STATE_ROOT/a.sum"
    claim_paths "$STATE_ROOT/a" 2025-01-01 "$STATE_ROOT/a.sum"
    [[ $(sed -n 2p "$OWNERS"/*) == "$(cut -c1-64 "$STATE_ROOT/a.sum")" ]]
}
test_network_wait_retries_until_reachable() {
    NETWORK_WAIT_SECONDS=120
    # verify_remote runs in a bounded subshell, so count attempts in a file.
    verify_remote() { echo x >>"$STATE_ROOT/tries"; (( $(wc -l <"$STATE_ROOT/tries") >= 3 )); }
    sleep() { :; }
    wait_for_internet
    [[ $(wc -l <"$STATE_ROOT/tries") == 3 ]]
}
test_network_wait_is_bounded() {
    NETWORK_WAIT_SECONDS=0
    verify_remote() { echo x >>"$STATE_ROOT/tries"; return 1; }
    sleep() { :; }
    wait_for_internet
    [[ $(wc -l <"$STATE_ROOT/tries") == 1 ]]
}
test_case_collision_stops() {
    mkdir "$STATE_ROOT/case"
    touch "$STATE_ROOT/case/A" "$STATE_ROOT/case/a"
    expect_failure validate_paths "$STATE_ROOT/case"
}
test_symlink_stops() {
    mkdir "$STATE_ROOT/links"
    ln -s /etc/passwd "$STATE_ROOT/links/file"
    expect_failure validate_paths "$STATE_ROOT/links"
}
test_clean_removes_local_data() {
    LOCAL_DATA=clean
    batch
    upload_batch "$SPOOL/2025-01-01"
    [[ ! -d $KEPT/2025-01-01 && ! -d $SPOOL/2025-01-01 && -f $VERIFIED/2025-01-01.json ]]
}
test_keep_retains_every_verified_day() {
    LOCAL_DATA=keep
    batch
    upload_batch "$SPOOL/2025-01-01"
    harvest_day 1735776000 1735862400 incremental none 5
    upload_batch "$SPOOL/2025-01-02"
    [[ -f $KEPT/2025-01-01/dropbox.sum && -f $KEPT/2025-01-02/dropbox.sum ]]
}
test_low_space_removes_oldest_verified_copy_first() {
    LOCAL_DATA=keep
    batch
    upload_batch "$SPOOL/2025-01-01"
    harvest_day 1735776000 1735862400 incremental none 5
    upload_batch "$SPOOL/2025-01-02"
    free_mib() { [[ -d $KEPT/2025-01-01 ]] && echo 10 || echo 99999; }
    MIN_FREE_MIB=2048
    check_local_storage
    [[ ! -d $KEPT/2025-01-01 && -d $KEPT/2025-01-02 ]]
    grep -q 'removing verified local copy of 2025-01-01' "$LOG_FILE"
    grep -q 'WARNING: local storage is getting low' "$LOG_FILE" || true
}
test_low_space_warns_and_never_touches_pending() {
    LOCAL_DATA=keep
    batch
    free_mib() { echo 100; }
    MIN_FREE_MIB=2048
    check_local_storage
    grep -q 'WARNING: local storage is getting low' "$LOG_FILE"
    [[ -d $SPOOL/2025-01-01 ]]
}
test_clean_mode_never_prunes_but_warns() {
    LOCAL_DATA=clean
    free_mib() { echo 100; }
    MIN_FREE_MIB=2048
    check_local_storage
    grep -q 'WARNING: local storage is getting low' "$LOG_FILE"
}
test_legacy_retain_key_maps_to_local_data() {
    runtime_defaults
    runtime_key RETAIN_LAST_BATCH no
    [[ $LOCAL_DATA == clean ]]
    runtime_key RETAIN_LAST_BATCH yes
    [[ $LOCAL_DATA == keep ]]
    expect_failure runtime_key LOCAL_DATA maybe
}
test_ensure_dirs_recreates_missing_folders() {
    rm -rf "$SPOOL" "$VERIFIED" "$OWNERS" "$KEPT" "$LOG_ROOT"
    ensure_dirs
    [[ -d $SPOOL && -d $VERIFIED && -d $OWNERS && -d $KEPT && -d $LOG_ROOT ]]
}
test_auto_recorders_get_serial_namespaces() {
    source_test_setup
    RECORDER_DEVICE=''
    detect_recorders() { printf 'SN001\t/dev/disk/by-id/usb-A\nSN002\t/dev/disk/by-id/usb-B\n'; }
    discover_sources
    validate_source_set
    [[ ${#SOURCE_FILES[@]} == 2 && ${SOURCE_FILES[0]} == @auto:SN001:/dev/disk/by-id/usb-A ]]
    load_source "${SOURCE_FILES[0]}"
    [[ $RECORDER_SERIAL == SN001 && $REMOTE_DATA == "$STATION_REMOTE_BASE/pegasus_harvester/SN001" &&
       $STATE_ROOT == "$STATION_STATE_ROOT/sources/SN001" ]]
}
test_swapped_recorder_starts_clean_and_old_pending_still_uploads() {
    source_test_setup
    RECORDER_DEVICE=''
    mkdir -p "$STATION_STATE_ROOT/sources/OLD1/pending/2025-01-01"
    detect_recorders() { printf 'NEW1\t/dev/disk/by-id/usb-N\n'; }
    discover_sources
    [[ ${SOURCE_FILES[0]} == @auto:NEW1:* && ${SOURCE_FILES[1]} == @known:OLD1:* ]]
    load_source "${SOURCE_FILES[1]}"
    [[ $SOURCE_DRAIN_ONLY == yes && $RECORDER_SERIAL == OLD1 ]]
}
test_detect_recorders_probes_only_usb_non_system_disks() {
    local probe="$STATE_ROOT/probe.sh"
    printf '%s\n' '#!/usr/bin/env bash' '[[ $1 == digitizer-info && $2 == -i=/dev/sdb ]] || exit 255' >"$probe"
    chmod +x "$probe"
    PEGASUS_BIN=$probe
    lsblk() {
        case "$*" in
            "-dnpo NAME,TYPE,TRAN") printf '/dev/sda disk sata\n/dev/sdb disk usb\n/dev/sdc disk usb\n/dev/sdd disk usb\n' ;;
            "-snp -o NAME /dev/sda2") printf '/dev/sda2\n/dev/sda\n' ;;
            "-dn -o SERIAL /dev/sdb") echo SNB ;;
            "-dn -o SERIAL /dev/sdc") echo SNC ;;
            "-dn -o SERIAL /dev/sdd") echo '' ;;
        esac
    }
    findmnt() { echo /dev/sda2; }
    disk_by_id_path() { echo "/dev/disk/by-id/usb-$(basename "$1")"; }
    [[ $(detect_recorders 2>/dev/null) == $'SNB\t/dev/disk/by-id/usb-sdb' ]]
}
test_real_tool_success_exit_status_one_is_accepted() {
    # Measured on hardware: the Nanometrics tool exits 1 after a working command.
    export MOCK_SUCCESS_EXIT=1
    batch
    [[ -d $SPOOL/2025-01-01 ]]
    inspect_volumes
}
test_real_tool_error_exit_status_255_is_rejected() {
    export MOCK_HARVEST_MODE=fail
    export MOCK_SUCCESS_EXIT=1
    expect_failure batch
}
test_harvester_exit_status_rules() {
    harvester_exit_ok 0 && harvester_exit_ok 1
    ! harvester_exit_ok 2 && ! harvester_exit_ok 124 && ! harvester_exit_ok 137 && ! harvester_exit_ok 255
}
test_error_text_is_never_accepted_even_with_exit_one() {
    local f="$STATE_ROOT/report.txt"
    printf "'/dev/sdb1' is not a PSF library or doesn't exist\nFinished in [0 days]\n" >"$f"
    ! harvester_report_ok "$f"
    printf 'Digitizer info:\n  serial = 123\nFinished in [0 days]\n' >"$f"
    harvester_report_ok "$f"
}
test_detect_recorders_uses_real_exit_codes() {
    local probe="$STATE_ROOT/probe2.sh"
    printf '%s\n' '#!/usr/bin/env bash' \
        'if [[ $2 == -i=/dev/sdb ]]; then echo "Digitizer info"; exit 1; fi' \
        'echo "no such device"; exit 255' >"$probe"
    chmod +x "$probe"
    PEGASUS_BIN=$probe
    lsblk() {
        case "$*" in
            "-dnpo NAME,TYPE,TRAN") printf '/dev/sda disk sata\n/dev/sdb disk usb\n/dev/sdc disk usb\n' ;;
            "-snp -o NAME /dev/sda2") printf '/dev/sda2\n/dev/sda\n' ;;
            "-dn -o SERIAL /dev/sdb") echo SNB ;;
            "-dn -o SERIAL /dev/sdc") echo SNC ;;
        esac
    }
    findmnt() { echo /dev/sda2; }
    disk_by_id_path() { echo "/dev/disk/by-id/usb-$(basename "$1")"; }
    [[ $(detect_recorders 2>/dev/null) == $'SNB\t/dev/disk/by-id/usb-sdb' ]]
}
test_no_recorder_connected_is_reported_not_fatal() {
    source_test_setup
    RECORDER_DEVICE='' CLOUD_READY=yes RUN_STATUS=SUCCESS
    detect_recorders() { :; }
    collect_all_sources
    [[ $RUN_STATUS == PARTIAL ]] && grep -q 'no recorder connected' "$LOG_FILE"
}
test_reupload_flag() {
    harvest_day 1735689600 1735776000 reupload:one yes 5
    upload_batch "$SPOOL/2025-01-01"
    grep -q -- '--ignore-times' "$STATE_ROOT/cloud-calls"
}
test_identical_file_not_retransferred() {
    batch
    upload_batch "$SPOOL/2025-01-01"
    local file="$REMOTE_DATA/2025/XX/TEST/BHZ.D/2025-01-01.mseed" before
    before=$(stat -c '%i:%y' "$file")
    batch
    upload_batch "$SPOOL/2025-01-01"
    [[ $(stat -c '%i:%y' "$file") == "$before" ]]
}
test_full_disk_blocks_ready() {
    DISK_FULL=yes
    expect_failure batch
    [[ ! -d $SPOOL/2025-01-01 ]]
}
test_failed_scratch_reclaimed() {
    export MOCK_HARVEST_MODE=fail
    expect_failure batch
    drain_pending
    [[ -z $(find "$SPOOL" -mindepth 1 -maxdepth 1 -type d -print -quit) ]]
    [[ -n $(find "$LOG_ROOT" -name '*partial*.log' -print -quit) ]]
}
test_incremental_skip_verified_old() {
    batch
    upload_batch "$SPOOL/2025-01-01"
    EARLIEST_NS=1735689600000000000 LATEST_NS=1735689700000000000
    PEGASUS_BIN=/nonexistent
    harvest_cycle
}
test_new_request_revisits_verified_day() {
    batch
    upload_batch "$SPOOL/2025-01-01"
    EARLIEST_NS=1735689600000000000 LATEST_NS=1735689700000000000
    HARVEST_MODE=reconcile REQUEST_ID=new-scan
    harvest_cycle
    [[ $(jq -r .request "$VERIFIED/2025-01-01.json") == reconcile:new-scan ]]
}
test_auto_no_wait() {
    remote_session_active() { return 0; }
    EXECUTE=auto
    maintenance_window
}
test_idle_timer_resets() {
    EXECUTE=ssh MAINTENANCE_IDLE_SECONDS=4
    printf 0 >"$STATE_ROOT/clock"
    uptime_seconds() { cat "$STATE_ROOT/clock"; }
    sleep() {
        local n
        n=$(<"$STATE_ROOT/clock")
        printf '%s\n' "$((n + $1))" >"$STATE_ROOT/clock"
    }
    # Connection present at t=2,4. Window closes at t=8, not t=4.
    remote_session_active() {
        local n
        n=$(<"$STATE_ROOT/clock")
        (( n == 2 || n == 4 ))
    }
    maintenance_window
    [[ $(<"$STATE_ROOT/clock") == 8 ]]
}
test_tailscale_detection() {
    ps() { printf '/usr/sbin/tailscaled be-child ssh --uid=1000\n'; }
    ss() { return 0; }
    remote_session_active
}
test_vnc_detection() {
    ps() { printf '/usr/sbin/tailscaled\n'; }
    ss() { printf '0 0 127.0.0.1:5901 127.0.0.1:44000\n'; }
    VNC_PORT=5901
    remote_session_active
}
test_entrypoint_requires_field() {
    expect_failure bash "$ROOT/tele.sh"
}
test_early_notification_failure_is_nonfatal() {
    load_credentials "$STATE_ROOT/nonexistent"
    [[ -z $EMAIL_PASSWORD ]]
}
test_unknown_harvester_error_rejected() {
    batch
    printf 'Failed to read sensor page\n' >>"$SPOOL/2025-01-01/harvest.log"
    expect_failure harvest_log_ok "$SPOOL/2025-01-01/harvest.log"
}
test_clock_failure_when_present_rejected() {
    batch
    CLOCK_PRESENT=yes
    expect_failure harvest_log_ok "$SPOOL/2025-01-01/harvest.log"
}
test_log_retry_from_older_run() {
    printf 'old diagnostic\n' >"$LOG_ROOT/previous-run.log"
    snapshot_log
    [[ $(<"$REMOTE_BASE/tele_logfiles/previous-run.log") == 'old diagnostic' ]]
}
test_volume_union_includes_soh_and_logs() {
    inspect_volumes
    [[ $EARLIEST_NS == 1735603200000000000 && $LATEST_NS == 1735948800000000000 &&
       $CLOCK_PRESENT == no ]]
}
test_volume_error_even_with_zero_exit() {
    export MOCK_HARVEST_MODE=bad-volume
    expect_failure inspect_volumes
}
test_native_flags_and_boundaries() {
    export MOCK_ARGUMENT_LOG="$STATE_ROOT/native-arguments"
    batch
    grep -Fxq -- '-l=1735689600000000000' "$MOCK_ARGUMENT_LOG"
    grep -Fxq -- '-u=1735775999999999999' "$MOCK_ARGUMENT_LOG"
    grep -Fxq -- '-d=24' "$MOCK_ARGUMENT_LOG"
    ! grep -q -- '^-p=' "$MOCK_ARGUMENT_LOG"
}

test_dropbox_team_root_and_spaces() {
    RCLONE_REMOTE=tele_dropbox STATION_NAME=field01
    node_key DROPBOX_ROOT '/Research Team/Project/'
    set_station_paths
    [[ $REMOTE_BASE == 'tele_dropbox:/Research Team/Project/tele/field01' ]]
    [[ $REMOTE_DATA == "$REMOTE_BASE/pegasus_harvester" ]]
    node_key DROPBOX_ROOT /
    set_station_paths
    [[ $REMOTE_BASE == tele_dropbox:/tele/field01 ]]
}
test_dropbox_unsafe_roots_rejected() {
    local value
    for value in '../team' '/team/../other' 'a//b' $'team\nbad' 'team\bad' '/./team'; do
        expect_failure node_key DROPBOX_ROOT "$value"
    done
}
test_destination_change_revisits_verified_days() {
    batch
    upload_batch "$SPOOL/2025-01-01"
    REMOTE_DATA="$REMOTE_BASE/other-destination"
    mkdir -p "$REMOTE_DATA"
    EARLIEST_NS=1735689600000000000 LATEST_NS=1735775999999999999
    HARVEST_BUDGET_SECONDS=20
    harvest_cycle
    [[ $(jq -r .destination "$VERIFIED/2025-01-01.json") == "$REMOTE_DATA" ]]
}
source_test_setup() {
    STATION_STATE_ROOT=$STATE_ROOT STATION_LOG_ROOT=$LOG_ROOT
    STATION_REMOTE_BASE=$REMOTE_BASE STATION_RUN_ID=$RUN_ID
    SOURCE_PROFILES_DIR="$STATE_ROOT/profiles"
    mkdir "$SOURCE_PROFILES_DIR"
}
profile_fixture() {
    printf 'TYPE=pegasus\nRECORDER_DEVICE=/dev/disk/by-id/usb-%s\nRECORDER_SERIAL=%s\n' \
        "$2" "$2" >"$SOURCE_PROFILES_DIR/$1.conf"
}
test_sources_keep_legacy_paths() {
    source_test_setup
    RECORDER_DEVICE=/dev/disk/by-id/usb-test
    discover_sources
    [[ ${SOURCE_FILES[0]} == @single-pegasus ]]
    load_source "${SOURCE_FILES[0]}"
    [[ $STATE_ROOT == "$STATION_STATE_ROOT" && $REMOTE_DATA == "$STATION_REMOTE_BASE/pegasus_harvester" ]]
}
test_sources_isolated_namespaces() {
    source_test_setup
    profile_fixture pegasus01 recorder01
    profile_fixture pegasus02 recorder02
    discover_sources
    validate_source_set
    load_source "${SOURCE_FILES[0]}"
    local first=$SPOOL
    [[ $REMOTE_DATA == "$STATION_REMOTE_BASE/pegasus_harvester/pegasus01" ]]
    load_source "${SOURCE_FILES[1]}"
    [[ $SPOOL != "$first" && $RECORDER_SERIAL == recorder02 &&
       $REMOTE_DATA == "$STATION_REMOTE_BASE/pegasus_harvester/pegasus02" ]]
}
test_duplicate_recorder_profiles_rejected() {
    source_test_setup
    profile_fixture one recorder01
    profile_fixture two recorder01
    discover_sources
    expect_failure validate_source_set
}
test_case_colliding_source_names_rejected() {
    source_test_setup
    profile_fixture North recorder01
    profile_fixture north recorder02
    discover_sources
    expect_failure validate_source_set
}
test_sources_continue_after_failure() {
    SOURCE_FILES=(one two)
    CLOUD_READY=yes HARVEST_BUDGET_SECONDS=30 SOURCES_OK=0 SOURCES_FAILED=0 RUN_STATUS=SUCCESS
    discover_sources() { :; }
    validate_source_set() { :; }
    run_source() { [[ $1 == two ]]; }
    collect_all_sources
    [[ $SOURCES_OK == 1 && $SOURCES_FAILED == 1 && $RUN_STATUS == PARTIAL &&
       $HARVEST_BUDGET_SECONDS == 30 && -z ${COLLECTION_DEADLINE:-} ]]
}
test_expired_source_deadline_blocks_commands() {
    COLLECTION_DEADLINE=1
    expect_failure source_timeout 30 touch "$STATE_ROOT/SHOULD_NOT_RUN"
    [[ ! -e $STATE_ROOT/SHOULD_NOT_RUN ]]
}
test_unknown_provider_rejected() {
    source_test_setup
    printf 'TYPE=camera\n' >"$SOURCE_PROFILES_DIR/camera.conf"
    expect_failure load_source "$SOURCE_PROFILES_DIR/camera.conf"
}
test_snow_modes_read_correctly() {
    [[ $(starlink_snow_mode <<<'{"dishGetConfig":{"dishConfig":{"snowMeltMode":"ALWAYS_OFF"}}}') == ALWAYS_OFF ]]
    [[ $(starlink_snow_mode <<<'{"dish_get_config":{"dish_config":{"snow_melt_mode":0}}}') == AUTO ]]
    expect_failure starlink_snow_mode <<<'{}'
}
test_snow_off_no_write_when_already_off() {
    starlink_rpc() {
        [[ $1 == '{"dish_get_config":{}}' ]] || return 99
        printf '{"dishGetConfig":{"dishConfig":{"snowMeltMode":"ALWAYS_OFF"}}}'
    }
    starlink_set_snow_off
}
test_snow_off_permission_denied_is_failure() {
    starlink_rpc() {
        [[ $1 == '{"dish_get_config":{}}' ]] || return 7
        printf '{"dishGetConfig":{"dishConfig":{"snowMeltMode":"AUTO"}}}'
    }
    expect_failure starlink_set_snow_off
}
test_snow_off_false_success_rejected() {
    starlink_rpc() {
        if [[ $1 == '{"dish_get_config":{}}' ]]; then
            printf '{"dishGetConfig":{"dishConfig":{"snowMeltMode":"AUTO"}}}'
        else printf '{"dishSetConfig":{"error":""}}'; fi
    }
    expect_failure starlink_set_snow_off
}
test_workflow_readable_order() {
    local calls="$STATE_ROOT/order"
    prepare_run() { RUN_MODE=once; }
    wait_for_internet() { echo wait >>"$calls"; }
    refresh_settings() { echo settings >>"$calls"; }
    check_upload_connection() { echo cloud >>"$calls"; }
    gather_station_diagnostics() { echo diagnostics >>"$calls"; }
    collect_all_sources() { echo sources >>"$calls"; }
    upload_station_logs() { echo logs >>"$calls"; }
    send_run_report() { echo email >>"$calls"; }
    offer_maintenance_window() { echo maintenance >>"$calls"; }
    finish_run() { echo finish >>"$calls"; }
    main --once
    [[ $(<"$calls") == $'wait\nsettings\ncloud\ndiagnostics\nsources\nlogs\nemail\nmaintenance\nfinish' ]]
}
test_check_does_not_run_collection() {
    prepare_run() { RUN_MODE=check; }
    check_setup() { return 0; }
    refresh_settings() { return 99; }
    collect_all_sources() { return 99; }
    main --check
}

for TEST in $(declare -F | awk '$3 ~ /^test_/ {print $3}' | sort); do
    # Run strict tests in a subprocess, not an if-function context that disables errexit.
    set +e
    (set -Eeuo pipefail; setup_test; "$TEST") >"$BASE/$TEST.out" 2>&1
    result=$?
    set -e
    if [[ $result == 0 ]]; then
        printf 'PASS %s\n' "$TEST"; PASS=$((PASS+1))
    else
        printf 'FAIL %s\n' "$TEST"; cat "$BASE/$TEST.out"; FAIL=$((FAIL+1))
    fi
done
printf '\n%d passed; %d failed\n' "$PASS" "$FAIL"
[[ $FAIL == 0 ]]
