#!/usr/bin/env bash
# Runs locally only. Never accesses a recorder, network, real credentials or poweroff.
set -Eeuo pipefail
export TZ=UTC LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/tele1.sh"
BASE=$(mktemp -d)
trap 'rm -rf -- "$BASE"' EXIT
PASS=0 FAIL=0

setup_test() {
    STATE_ROOT="$BASE/$TEST"
    SPOOL="$STATE_ROOT/pending" VERIFIED="$STATE_ROOT/verified" OWNERS="$STATE_ROOT/owners"
    LAST_BATCH="$STATE_ROOT/last-verified" LOG_ROOT="$STATE_ROOT/logs"
    LOG_FILE="$LOG_ROOT/run.log" RUN_ID=test-run RECORDER_SERIAL=test-recorder
    REMOTE_BASE="$STATE_ROOT/remote"
    REMOTE_DATA="$REMOTE_BASE/pegasus_harvester"
    mkdir -p "$SPOOL" "$VERIFIED" "$OWNERS" "$LOG_ROOT" "$REMOTE_DATA"
    touch "$LOG_FILE"
    runtime_defaults
    NETWORK_TIMEOUT_SECONDS=10
    PEGASUS_BIN="$ROOT/tests/fake-harvester.sh" DEVICE=/dev/never-used CLOCK_PRESENT=no
    HARVEST_USED_SECONDS=0 FAULT=none
    export MOCK_HARVEST_MODE=ok
}

cloud() {
    printf '%s\n' "$*" >>"$STATE_ROOT/cloud-calls"
    if [[ $FAULT == copy && $1 == copy ]]; then return 9; fi
    if [[ $FAULT == check && $1 == check && $3 == "$REMOTE_DATA" ]]; then return 9; fi
    if [[ $FAULT == receipt && $1 == copyto ]]; then return 9; fi
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
    printf 'EXECUTE=auto\n' >"$STATE_ROOT/config.txt"
    printf 'EXECUTE=ssh\nUNKNOWN=bad\n' >"$REMOTE_BASE/config.txt"
    RCLONE_REMOTE=unused
    load_runtime_config
    [[ $EXECUTE == auto && $(<"$STATE_ROOT/config.txt") == EXECUTE=auto ]]
}
test_success_roundtrip() {
    batch
    upload_batch "$SPOOL/2025-01-01"
    [[ -f $VERIFIED/2025-01-01.json && -d $LAST_BATCH && ! -d $SPOOL/2025-01-01 ]]
    cloud check "$LAST_BATCH/dropbox.sum" "$REMOTE_DATA" --checkfile Dropbox --one-way
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
    cloud check "$LAST_BATCH/dropbox.sum" "$REMOTE_DATA" --checkfile Dropbox --one-way
}
test_native_name_collision_stops() {
    mkdir "$STATE_ROOT/a" "$STATE_ROOT/b"
    printf one >"$STATE_ROOT/a/shared.log"
    printf two >"$STATE_ROOT/b/shared.log"
    claim_paths "$STATE_ROOT/a" 2025-01-01
    expect_failure claim_paths "$STATE_ROOT/b" 2025-01-02
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
test_no_retention() {
    RETAIN_LAST_BATCH=no
    batch
    upload_batch "$SPOOL/2025-01-01"
    [[ ! -d $LAST_BATCH && ! -d $SPOOL/2025-01-01 && -f $VERIFIED/2025-01-01.json ]]
}
test_keep_last_only() {
    batch
    upload_batch "$SPOOL/2025-01-01"
    harvest_day 1735776000 1735862400 incremental none 5
    upload_batch "$SPOOL/2025-01-02"
    [[ $(jq -r .day "$LAST_BATCH/meta.json") == 2025-01-02 ]]
    [[ -f $VERIFIED/2025-01-01.json && -f $VERIFIED/2025-01-02.json &&
       ! -d $LAST_BATCH.previous ]]
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
    expect_failure bash "$ROOT/tele1.sh"
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
