#!/usr/bin/env bash
# Mocked installer orchestration only: no apt, services, network or field hardware.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT
PASS=0 FAIL=0
test_plan_without_config_or_root() {
    bash "$ROOT/INSTALL.sh" --mode plan >"$BASE/plan"
    grep -q 'PLAN ONLY' "$BASE/plan"
    grep -q 'next boot: no' "$BASE/plan"
}
test_unknown_option_fails() {
    if bash "$ROOT/INSTALL.sh" --nonsense >"$BASE/error" 2>&1; then return 1; fi
}
test_no_config_in_auto_fails() {
    if bash "$ROOT/INSTALL.sh" --mode auto >"$BASE/error" 2>&1; then return 1; fi
}
test_literal_setup_not_executed() {
    source "$ROOT/INSTALL.sh"
    CONFIG="$BASE/literal"
    printf 'EMAIL_PASSWORD=$(touch %s/INJECTED)\n' "$BASE" >"$CONFIG"
    chmod 600 "$CONFIG"
    parse_setup
    [[ $(get EMAIL_PASSWORD) == "\$(touch $BASE/INJECTED)" && ! -e $BASE/INJECTED ]]
}
test_duplicate_key_rejected() {
    printf 'station=one\nstation=two\n' >"$BASE/duplicate"
    chmod 600 "$BASE/duplicate"
    if bash -c 'source "$1/INSTALL.sh"; CONFIG=$2; parse_setup' _ "$ROOT" "$BASE/duplicate"; then return 1; fi
}
test_public_setup_rejected() {
    printf 'station=one\n' >"$BASE/public"
    chmod 644 "$BASE/public"
    if bash -c 'source "$1/INSTALL.sh"; CONFIG=$2; parse_setup' _ "$ROOT" "$BASE/public"; then return 1; fi
}
test_auto_stage_order_no_field() {
    source "$ROOT/INSTALL.sh"
    CONFIG="$BASE/mock-config"
    printf 'station=one\n' >"$CONFIG"
    chmod 600 "$CONFIG"
    local calls="$BASE/stages"
    preflight() { echo preflight >>"$calls"; }
    fetch_release() { SHA='test'; echo fetch >>"$calls"; }
    install_packages() { echo packages >>"$calls"; }
    linux_settings() { echo linux >>"$calls"; }
    install_tailscale() { echo tailscale >>"$calls"; }
    install_release_and_config() { echo config >>"$calls"; }
    install_services() { echo services >>"$calls"; }
    check_connections() { echo checks >>"$calls"; }
    check_starlink() { echo starlink >>"$calls"; }
    enable_field() { echo FIELD >>"$calls"; }
    main --config "$CONFIG" --mode auto
    trap - EXIT
    [[ $(<"$calls") == $'preflight\nfetch\npackages\nlinux\ntailscale\nconfig\nservices\nchecks\nstarlink' ]]
}
test_stage_failure_stops_before_activation() {
    # A fresh strict shell is essential: an if-function context masks errexit.
    set +e
    bash -c '
        set -Eeuo pipefail
        source "$1/INSTALL.sh"
        MODE=auto
        failing_stage() { false; touch "$2"; }
        step "simulated failure" failing_stage _ "$2"
        touch "$2"
    ' _ "$ROOT" "$BASE/SHOULD_NOT_EXIST"
    local rc=$?
    set -e
    [[ $rc != 0 && ! -e $BASE/SHOULD_NOT_EXIST ]]
}
setup_validation() {
    source "$ROOT/INSTALL.sh"
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    WORK="$BASE/validation-$BASHPID"
    mkdir -p "$WORK"
    SETUP[station]=bench01
    SETUP[DROPBOX_ROOT]='/Research Team/Project'
    SETUP[EMAIL_FROM]=station@example.com
    SETUP[EMAIL_TO]=operator@example.com
    SETUP[EMAIL_PASSWORD]='test-only-placeholder'
    SETUP[ENABLE_VNC]=no
    SETUP[PEGASUS_BIN]=$ROOT/tests/fake-harvester.sh
    SETUP[RECORDER_DEVICE]=/dev/disk/by-id/usb-recorder
    SETUP[RECORDER_SERIAL]='test-recorder'
    SETUP[DROPBOX_TOKEN_JSON]='{"access_token":"test-only","refresh_token":"test-only"}'
}
test_valid_setup_preserves_team_path() {
    setup_validation
    validate_setup
    [[ $DROPBOX_ROOT == '/Research Team/Project' && $BIN == "$ROOT/tests/fake-harvester.sh" ]]
}
test_setup_allows_distinct_recorders() {
    setup_validation
    SETUP[SOURCES_JSON]='[{"id":"one","device":"/dev/disk/by-id/usb-one","serial":"one"},{"id":"two","device":"/dev/disk/by-id/usb-two","serial":"two"}]'
    validate_setup
    [[ $(jq length "$WORK/sources.json") == 2 ]]
}
test_setup_rejects_colliding_profiles() {
    setup_validation
    SETUP[SOURCES_JSON]='[{"id":"North","device":"/dev/disk/by-id/usb-one","serial":"one"},{"id":"north","device":"/dev/disk/by-id/usb-two","serial":"two"}]'
    set +e
    (set -e; validate_setup)
    local rc=$?
    set -e
    [[ $rc != 0 ]]
}
test_setup_rejects_partition_device() {
    setup_validation
    SETUP[RECORDER_DEVICE]=/dev/disk/by-id/usb-recorder-part1
    set +e
    (set -e; validate_setup)
    local rc=$?
    set -e
    [[ $rc != 0 ]]
}
test_setup_requires_refresh_token() {
    setup_validation
    SETUP[DROPBOX_TOKEN_JSON]='{"access_token":"test-only"}'
    set +e
    (set -e; validate_setup)
    local rc=$?
    set -e
    [[ $rc != 0 ]]
}
test_setup_requires_vendor_checksum() {
    setup_validation
    SETUP[HARVESTER_DEB]=/not-installed.deb
    set +e
    (set -e; validate_setup)
    local rc=$?
    set -e
    [[ $rc != 0 ]]
}
test_setup_rejects_inconsistent_vnc() {
    setup_validation
    SETUP[EXECUTE]=vnc
    set +e
    (set -e; validate_setup)
    local rc=$?
    set -e
    [[ $rc != 0 ]]
}
test_setup_requires_exact_vnc_password_length() {
    setup_validation
    SETUP[ENABLE_VNC]=yes
    SETUP[VNC_PASSWORD]=toolongpassword
    set +e
    (set -e; validate_setup)
    local rc=$?
    set -e
    [[ $rc != 0 ]]
}
test_documented_installer_example_parses() {
    source "$ROOT/INSTALL.sh"
    CONFIG="$BASE/example-private.txt"
    install -m 600 "$ROOT/credentials.example.txt" "$CONFIG"
    parse_setup
    [[ $(get EMAIL_PASSWORD) == REPLACE_WITH_YOUR_16_CHARACTER_GOOGLE_APP_PASSWORD &&
       $(get TAILSCALE_AUTH_KEY) == tskey-REPLACE_WITH_YOUR_GENERATED_DEVICE_AUTH_KEY &&
       $(get VNC_PASSWORD) == REPLACE_WITH_YOUR_8_CHARACTER_VNC_PASSWORD ]]
}
test_unmodified_installer_example_cannot_deploy() {
    setup_validation
    CONFIG="$BASE/unmodified-private.txt"
    install -m 600 "$ROOT/credentials.example.txt" "$CONFIG"
    declare -gA SETUP=()
    parse_setup
    set +e
    (set -e; validate_setup)
    local rc=$?
    set -e
    [[ $rc != 0 ]]
}
test_email_only_example_parses() {
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    read_kv "$ROOT/config/credentials.txt.example" credential_key
    [[ $EMAIL_FROM == REPLACE_WITH_SENDER@gmail.com &&
       $EMAIL_TO == REPLACE_WITH_REPORT_RECIPIENT@example.com &&
       $EMAIL_PASSWORD == REPLACE_WITH_YOUR_16_CHARACTER_GOOGLE_APP_PASSWORD ]]
}
for test in $(declare -F | awk '$3 ~ /^test_/ {print $3}' | sort); do
    set +e
    (set -Eeuo pipefail; "$test") >"$BASE/$test.out" 2>&1
    rc=$?
    set -e
    if ((rc==0)); then printf 'PASS %s\n' "$test"; PASS=$((PASS+1))
    else printf 'FAIL %s\n' "$test"; cat "$BASE/$test.out"; FAIL=$((FAIL+1)); fi
done
printf '\n%d installer tests passed; %d failed\n' "$PASS" "$FAIL"
[[ $FAIL == 0 ]]
