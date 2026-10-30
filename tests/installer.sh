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
    system_updates() { echo updates >>"$calls"; }
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
    [[ $(<"$calls") == $'preflight\nfetch\nupdates\npackages\nlinux\ntailscale\nconfig\nservices\nchecks\nstarlink' ]]
}
test_updates_disable_background_updates() {
    source "$ROOT/INSTALL.sh"
    WORK="$BASE/updates-work"; mkdir -p "$WORK"
    APT_NO_AUTO_CONF="$BASE/99tele-no-automatic-updates"
    local calls="$BASE/update-calls"
    declare -gA SETUP=()
    apt-get() { echo "apt-get $*" >>"$calls"; }
    snap() { echo "snap $*" >>"$calls"; }
    systemctl() { echo "systemctl $*" >>"$calls"; }
    timeout() { while [[ $1 == -* || $1 =~ ^[0-9]+$ ]]; do shift; done; "$@"; }
    system_updates
    grep -q 'upgrade --with-new-pkgs' "$calls" &&
    grep -q 'snap refresh --hold' "$calls" &&
    grep -q 'disable --now apt-daily.timer' "$calls" &&
    grep -q 'disable --now apt-daily-upgrade.timer' "$calls" &&
    grep -q 'Unattended-Upgrade "0"' "$APT_NO_AUTO_CONF"
}
test_updates_can_be_left_alone() {
    source "$ROOT/INSTALL.sh"
    WORK="$BASE/updates-work2"; mkdir -p "$WORK"
    APT_NO_AUTO_CONF="$BASE/99tele-untouched"
    local calls="$BASE/update-calls2"
    declare -gA SETUP=([SYSTEM_UPGRADE]=no [DISABLE_AUTO_UPDATES]=no)
    apt-get() { echo "apt-get $*" >>"$calls"; }
    snap() { echo "snap $*" >>"$calls"; }
    systemctl() { echo "systemctl $*" >>"$calls"; }
    system_updates
    [[ ! -e $calls && ! -e $APT_NO_AUTO_CONF ]]
}
test_recorder_may_be_left_to_automatic_detection() {
    setup_validation
    unset 'SETUP[RECORDER_DEVICE]' 'SETUP[RECORDER_SERIAL]'
    validate_setup
}
test_half_a_recorder_pin_is_rejected() {
    setup_validation
    unset 'SETUP[RECORDER_SERIAL]'
    set +e; (set -e; validate_setup) >/dev/null 2>&1; local rc=$?; set -e
    [[ $rc != 0 ]]
}
test_operator_password_rules() {
    local pw
    for pw in 'short' 'has space1' 'has:colon1'; do
        setup_validation
        SETUP[OPERATOR_PASSWORD]=$pw
        set +e; (set -e; validate_setup) >/dev/null 2>&1; local rc=$?; set -e
        [[ $rc != 0 ]] || return 1
    done
    setup_validation
    SETUP[OPERATOR_PASSWORD]=tele99
    validate_setup
}
test_computer_name_rules() {
    local name
    for name in 'Tele9' 'tele_9' '-tele' 'tele-'; do
        setup_validation
        SETUP[COMPUTER_NAME]=$name
        set +e; (set -e; validate_setup) >/dev/null 2>&1; local rc=$?; set -e
        [[ $rc != 0 ]] || return 1
    done
    setup_validation
    SETUP[COMPUTER_NAME]=tele9
    validate_setup
}
test_local_data_and_legacy_retain_key() {
    setup_validation
    validate_setup
    [[ $LOCAL_DATA_VALUE == keep ]]
    SETUP[RETAIN_LAST_BATCH]=no
    validate_setup
    [[ $LOCAL_DATA_VALUE == clean ]]
    SETUP[LOCAL_DATA]=keep
    validate_setup
    [[ $LOCAL_DATA_VALUE == keep ]]
    SETUP[LOCAL_DATA]=maybe
    set +e; (set -e; validate_setup) >/dev/null 2>&1; local rc=$?; set -e
    [[ $rc != 0 ]]
}
test_harvester_package_found_next_to_credentials() {
    setup_validation
    unset 'SETUP[PEGASUS_BIN]'
    mkdir -p "$BASE/pkg"
    CONFIG="$BASE/pkg/setup.conf"; touch "$CONFIG"
    printf deb >"$BASE/pkg/PegasusHarvester-1.2.deb"
    SETUP[HARVESTER_SHA256]=$(printf 'a%.0s' {1..64})
    validate_setup
    [[ $(get HARVESTER_DEB) == "$BASE/pkg/PegasusHarvester-1.2.deb" ]]
}
test_bare_harvester_filename_resolves_next_to_credentials() {
    setup_validation
    mkdir -p "$BASE/pkg2"
    CONFIG="$BASE/pkg2/setup.conf"; touch "$CONFIG"
    printf deb >"$BASE/pkg2/my.deb"
    SETUP[HARVESTER_DEB]=my.deb
    SETUP[HARVESTER_SHA256]=$(printf 'b%.0s' {1..64})
    validate_setup
    [[ $(get HARVESTER_DEB) == "$BASE/pkg2/my.deb" ]]
}
test_computer_account_and_autologin_configuration() {
    source "$ROOT/INSTALL.sh"
    WORK="$BASE/acct-work"; mkdir -p "$WORK"
    GDM_DIR="$BASE/acct/gdm3" LIGHTDM_DIR="$BASE/acct/lightdm" DCONF_DIR="$BASE/acct/dconf"
    HOSTS_FILE="$BASE/acct/hosts" HOME_BASE="$BASE/acct/home"
    mkdir -p "$GDM_DIR" "$HOME_BASE/tele9"
    printf '[daemon]\n#AutomaticLoginEnable = true\n#AutomaticLogin = old\nWaylandEnable=false\n' >"$GDM_DIR/custom.conf"
    printf '127.0.0.1 localhost\n127.0.1.1 oldname\n' >"$HOSTS_FILE"
    USER_NAME=tele9 COMPUTER_NAME=tele9 OPERATOR_PASSWORD=tele99
    declare -gA SETUP=()
    local calls="$BASE/acct-calls"
    hostnamectl() { echo "hostnamectl $*" >>"$calls"; }
    id() { if [[ $1 == -gn ]]; then echo tele9; else return 0; fi; }
    getent() { echo "tele9:x:1000:1000::/home/tele9:/bin/bash"; }
    useradd() { echo "useradd $*" >>"$calls"; }
    usermod() { echo "usermod $*" >>"$calls"; }
    chpasswd() { cat >>"$calls"; }
    dconf() { echo "dconf $*" >>"$calls"; }
    chown() { :; }
    install() { if [[ $1 == -d && $2 == -o ]]; then command install -d -m 700 "${@:7}"; else command install "$@"; fi; }
    set_computer_name
    set_operator_account
    set_autologin
    grep -q 'hostnamectl set-hostname tele9' "$calls"
    grep -qx 'tele9:tele99' "$calls"
    grep -q 'usermod -aG sudo tele9' "$calls"
    grep -qx '127.0.1.1 tele9' "$HOSTS_FILE"
    grep -qx 'AutomaticLoginEnable=true' "$GDM_DIR/custom.conf"
    grep -qx 'AutomaticLogin=tele9' "$GDM_DIR/custom.conf"
    grep -qx 'WaylandEnable=false' "$GDM_DIR/custom.conf"
    [[ $(grep -c AutomaticLogin "$GDM_DIR/custom.conf") == 2 ]]
    grep -qx 'lock-enabled=false' "$DCONF_DIR/db/local.d/00-tele-field"
    grep -q 'dconf update' "$calls"
    [[ -f $HOME_BASE/tele9/.config/gnome-initial-setup-done ]]
}
test_autologin_can_be_switched_off() {
    source "$ROOT/INSTALL.sh"
    GDM_DIR="$BASE/off/gdm3"; mkdir -p "$GDM_DIR"
    declare -gA SETUP=([AUTOLOGIN]=no)
    set_autologin
    [[ ! -s $GDM_DIR/custom.conf ]]
}
make_test_bundle() {
    local name=$1 out="$BASE/bundle-$1"
    mkdir -p "$out"
    printf 'station=%s\nCOMPUTER_NAME=%s\n# HARVESTER_URL=https://example.invalid/x.deb\nHARVESTER_SHA256=old\n' "$name" "$name" >"$out/in.conf"
    printf 'fake deb' >"$out/PegasusHarvester-test.deb"
    "$ROOT/scripts/make-bundle.sh" --setup "$out/in.conf" --deb "$out/PegasusHarvester-test.deb" \
        --out "$out" >"$out/log" 2>&1
    (cd "$out" && unzip -q "$name.zip")
}
test_bundle_contents_and_integrity_check() {
    make_test_bundle bt1
    local dir="$BASE/bundle-bt1/bt1"
    [[ -f $dir/INSTALL.sh && -f $dir/lib/workflow.sh && -f $dir/REVISION &&
       -f $dir/MANIFEST.sha256 && -f $dir/README-TECHNICIAN.txt && -f $dir/PegasusHarvester-test.deb ]]
    [[ ! -d $dir/log && ! -d $dir/state ]]
    [[ $(stat -c %a "$dir/setup.conf") == 600 ]]
    grep -qx 'HARVESTER_DEB=PegasusHarvester-test.deb' "$dir/setup.conf"
    grep -qx "HARVESTER_SHA256=$(sha256sum "$dir/PegasusHarvester-test.deb" | cut -d' ' -f1)" "$dir/setup.conf"
    [[ $(grep -c '^HARVESTER_SHA256=' "$dir/setup.conf") == 1 ]]
    ! grep -q 'sha256 old' "$dir/setup.conf"
    # The bundle must not carry the secrets into the manifest or the code tree.
    ! grep -q 'setup.conf' "$dir/MANIFEST.sha256"
    source "$ROOT/INSTALL.sh"
    SCRIPT_DIR=$dir
    (verify_bundle) >/dev/null
}
test_damaged_bundle_is_refused() {
    make_test_bundle bt2
    local dir="$BASE/bundle-bt2/bt2"
    printf '\n# tampered\n' >>"$dir/lib/common.sh"
    source "$ROOT/INSTALL.sh"
    SCRIPT_DIR=$dir
    set +e; (set -e; verify_bundle) >/dev/null 2>&1; local rc=$?; set -e
    [[ $rc != 0 ]]
}
test_bundle_with_placeholders_is_refused() {
    local out="$BASE/bundle-ph"; mkdir -p "$out"
    printf 'station=ph\nEMAIL_PASSWORD=REPLACE_WITH_SECRET\n' >"$out/in.conf"
    printf deb >"$out/a.deb"
    set +e
    "$ROOT/scripts/make-bundle.sh" --setup "$out/in.conf" --deb "$out/a.deb" --out "$out" >"$out/log" 2>&1
    local rc=$?; set -e
    [[ $rc != 0 && ! -e $out/ph.zip ]]
    ! grep -q 'SECRET' "$out/log"
}
test_apt_never_waits_on_the_terminal() {
    source "$ROOT/INSTALL.sh"
    WORK="$BASE/watch-work"; mkdir -p "$WORK"; WATCH_INTERVAL=0.1
    local capture="$BASE/apt-run"
    timeout() {
        { printf 'args:%s\n' "$*"; printf 'needrestart:%s/%s\n' "$NEEDRESTART_MODE" "$NEEDRESTART_SUSPEND"
          printf 'frontend:%s\n' "$DEBIAN_FRONTEND"; printf 'stdin:'; cat; printf '\n'; } >"$capture"
    }
    echo "would-be-keyboard-input" | apt_install curl >/dev/null
    # A bare `timeout` would leave apt in a background process group (silently
    # stopped when anything reads the terminal); stdin must also be closed.
    grep -q '^args:--foreground -k 30 1800 apt-get' "$capture"
    grep -q 'install -y curl' "$capture"
    grep -qx 'needrestart:a/1' "$capture"
    grep -qx 'frontend:noninteractive' "$capture"
    grep -qx 'stdin:' "$capture"
}
test_watched_streams_output_and_returns_status() {
    source "$ROOT/INSTALL.sh"
    WORK="$BASE/watch-work2"; mkdir -p "$WORK"; WATCH_INTERVAL=0.1
    local text rc
    text=$(watched 10 'say hello' bash -c 'echo line-one; echo line-two >&2; exit 0')
    [[ $text == *line-one* && $text == *line-two* ]]
    set +e; text=$(watched 10 'fails' bash -c 'echo boom; exit 3'); rc=$?; set -e
    [[ $rc == 3 && $text == *boom* && $text == *"exited with status 3"* ]]
}
test_watched_stops_a_command_at_its_time_limit() {
    source "$ROOT/INSTALL.sh"
    WORK="$BASE/watch-work3"; mkdir -p "$WORK"; WATCH_INTERVAL=0.1
    local text rc started=$SECONDS
    set +e; text=$(watched 1 'sleeper' sleep 30); rc=$?; set -e
    [[ $rc == 124 && $text == *"did not finish within 1s"* ]]
    (( SECONDS - started < 15 ))
}
test_watched_gives_commands_no_keyboard() {
    source "$ROOT/INSTALL.sh"
    WORK="$BASE/watch-work4"; mkdir -p "$WORK"; WATCH_INTERVAL=0.1
    local text
    # A command that tries to read the terminal must see end-of-file, not wait.
    text=$(watched 10 'reads stdin' bash -c 'read -r line && echo "got:$line" || echo eof')
    [[ $text == *eof* ]]
}
test_stopped_process_is_resumed() {
    source "$ROOT/INSTALL.sh"
    sleep 30 & local pid=$!
    kill -STOP "$pid"; sleep 0.3
    [[ $(ps -o stat= -p "$pid") == T* ]]
    unstick "$pid" >/dev/null
    sleep 0.3
    local state; state=$(ps -o stat= -p "$pid")
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    [[ $state != T* ]]
}
test_watched_reports_a_silent_command() {
    source "$ROOT/INSTALL.sh"
    WORK="$BASE/watch-work5"; mkdir -p "$WORK"; WATCH_INTERVAL=0.2 STALL_SECONDS=1
    local text
    text=$(watched 10 'quiet job' bash -c 'sleep 3')
    [[ $text == *"no output from 'quiet job'"* && $text == *"PID"* ]]
}
test_upgrade_off_says_so() {
    source "$ROOT/INSTALL.sh"
    WORK="$BASE/upd-work"; mkdir -p "$WORK"
    APT_NO_AUTO_CONF="$BASE/99tele-off"
    declare -gA SETUP=([SYSTEM_UPGRADE]=no [DISABLE_AUTO_UPDATES]=no)
    local text; text=$(system_updates)
    [[ $text == *"SYSTEM_UPGRADE=no: skipping"* ]]
}
test_harvester_version_check_ignores_exit_status() {
    source "$ROOT/INSTALL.sh"
    local fake="$BASE/fake-version.sh"
    printf '%s\n' '#!/usr/bin/env bash' 'echo "Versions:"' 'echo "    Harvester CL - v1.3.91 (Nanometrics)"' 'echo "Finished in [0 days 0 hrs 0 mins 0 secs]"' 'exit 1' >"$fake"
    chmod +x "$fake"
    BIN=$fake
    check_harvester_version >/dev/null
    printf '%s\n' '#!/usr/bin/env bash' 'echo "something else"' 'exit 0' >"$fake"
    set +e; (set -e; check_harvester_version) >/dev/null 2>&1; local rc=$?; set -e
    [[ $rc != 0 ]]
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
    SETUP[OPERATOR_PASSWORD]='test-only-pw'
    CONFIG="$BASE/cfg/setup.conf"; mkdir -p "$BASE/cfg"; touch "$CONFIG"
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
