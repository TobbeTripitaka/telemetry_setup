#!/usr/bin/env bash
# Install TELE on the Ubuntu station, never on the administration Mac.
# No passwords on the command line. No eval/source of the setup file.
set -Eeuo pipefail
umask 077
export LC_ALL=C

usage() {
    printf '%s\n' \
      'Usage: sudo bash INSTALL.sh --config /root/tele-setup.conf [options]' \
      '   or, inside an unzipped TELE bundle:   sudo bash INSTALL.sh' \
      '       (uses setup.conf, the code and the Harvester .deb in the same folder)' \
      '  --mode confirm|auto|plan   Confirm each stage (default), no prompts, or no changes' \
      '  --ref REF                  Git revision/tag/branch; default main, resolved once' \
      '  --source-dir PATH          Use a clean, committed local Git checkout instead' \
      '  --enable-field             Enable collection/poweroff for NEXT boot only' \
      'Never run on a battery-powered station with its field service/timer active.'
}
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
INSTALL_LOG=/var/log/tele-install.log
say() {
    printf '%s\n' "$*"
    { printf '%s\n' "$*" >>"$INSTALL_LOG"; } 2>/dev/null || true
}
# Nothing the installer starts may ever ask a question: no debconf dialogs, no
# needrestart prompt, no changed-config-file prompt, no changelog pager.
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
export UCF_FORCE_CONFFOLD=1 APT_LISTCHANGES_FRONTEND=none PAGER=cat SYSTEMD_PAGER=
declare -gA SETUP=()
APT_NO_AUTO_CONF=/etc/apt/apt.conf.d/99tele-no-automatic-updates
UNIT_DIR=/etc/systemd/system
GDM_DIR=/etc/gdm3 LIGHTDM_DIR=/etc/lightdm DCONF_DIR=/etc/dconf HOSTS_FILE=/etc/hosts HOME_BASE=/home
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MODE=confirm MODE_SET=no CONFIG='' CONFIG_DIR='' PRIVATE_CONF='' BUNDLE=no
REF=main SOURCE_DIR='' ENABLE_FIELD=no WORK='' CURRENT_STAGE=arguments
cleanup() {
    local rc=$?
    trap - EXIT
    [[ -z $WORK ]] || rm -rf -- "$WORK"
    [[ -z $PRIVATE_CONF ]] || rm -f -- "$PRIVATE_CONF"
    if ((rc)); then
        say "Installation stopped at '$CURRENT_STAGE' (status $rc). No automatic rollback of packages/settings."
        say 'Nothing has been rebooted or powered off. Fix the failed stage and rerun.'
    fi
    exit "$rc"
}
step() {
    local title=$1 reply
    shift
    CURRENT_STAGE=$title
    say ""; say "== $title =="
    if [[ $MODE == confirm ]]; then
        read -r -p 'Run this stage? [y/N] ' reply </dev/tty || fail 'Confirmation requires a terminal'
        [[ $reply == y || $reply == Y ]] || fail 'Stage declined; installation stopped'
    fi
    # Do not use an if/|| wrapper here: it would disable Bash errexit in stages.
    "$@"
}
private_file() {
    [[ -f $1 && ! -L $1 ]] || fail "Not a regular private file: $1"
    [[ $(stat -c %u "$1") == "$EUID" ]] || fail "File must belong to the installing user/root: $1"
    local mode
    mode=$(stat -c %a "$1")
    (( (8#$mode & 077) == 0 )) || fail "Run chmod 600 on: $1"
}
parse_setup() {
    private_file "$CONFIG"
    [[ $(stat -c %s "$CONFIG") -le 65536 ]] || fail 'Setup file exceeds 64 KiB'
    local line key value
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z $line || $line == \#* ]] && continue
        [[ $line == *=* ]] || fail 'Setup uses literal KEY=value lines'
        key=${line%%=*}; value=${line#*=}
        [[ $key =~ ^([A-Z][A-Z0-9_]*|station)$ && -z ${SETUP[$key]+yes} ]] ||
            fail 'Invalid or duplicate setup key'
        case "$key" in
          station|DROPBOX_ROOT|RCLONE_REMOTE|RCLONE_CONFIG_FILE|DROPBOX_TOKEN_JSON|\
          EMAIL_FROM|EMAIL_TO|EMAIL_PASSWORD|RECORDER_DEVICE|RECORDER_SERIAL|SOURCES_JSON|\
          HARVESTER_DEB|HARVESTER_URL|HARVESTER_SHA256|PEGASUS_BIN|\
          OPERATOR_USER|TAILSCALE_AUTH_KEY|ENABLE_VNC|VNC_PASSWORD|\
          STARLINK_ADDRESS|STARLINK_SNOW_MELT|EMERGENCY_SECONDS|DISABLE_SLEEP|\
          SYSTEM_UPGRADE|DISABLE_AUTO_UPDATES|COMPUTER_NAME|OPERATOR_PASSWORD|AUTOLOGIN|LOCAL_DATA|\
          EXECUTE|HARVEST_BUDGET_SECONDS|MAINTENANCE_IDLE_SECONDS|RETAIN_LAST_BATCH|NETWORK_WAIT_SECONDS|\
          UPLOAD_TEST|EMAIL_TEST) ;;
          *) fail "Unknown setup key: $key" ;;
        esac
        [[ $value != *$'\r'* && $value != *$'\t'* ]] || fail "Invalid character in $key"
        SETUP[$key]=$value
    done <"$CONFIG"
}
get() { printf '%s' "${SETUP[$1]:-${2:-}}"; }
download() {
    timeout --foreground -k 10 300 curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 280 \
        "$1" --output "$2"
}
descendants() {
    # PIDs of $1 and everything below it.
    ps -eo pid=,ppid= | awk -v root="$1" '
        { p[$1] = $2 }
        END { for (i in p) { a = i; n = 0
                while (a != "" && a != root && a != 0 && a != 1 && n++ < 100) a = p[a]
                if (a == root) print i }
              print root }' | sort -un
}

unstick() {
    # A program that reads the terminal from the background is stopped silently
    # by the kernel (state T). Resume anything below $1 that is stopped.
    local pid resumed=''
    for pid in $(descendants "$1"); do
        if [[ $(ps -o stat= -p "$pid" 2>/dev/null) == T* ]]; then
            kill -CONT "$pid" 2>/dev/null && resumed="$resumed $pid"
        fi
    done
    [[ -z $resumed ]] || printf '%s' "$resumed"
}

process_report() {
    # What is it doing? State, CPU, what it waits for, command.
    local pids
    pids=$(descendants "$1" | paste -sd, -)
    ps -o pid,ppid,stat,etime,pcpu,wchan:22,args -p "$pids" 2>/dev/null | cut -c1-200
}

watched() {
    # usage: watched SECONDS LABEL command args...
    # Runs a long external command so that it can NEVER hang silently:
    #  - stdin is /dev/null and the command stays in this script's process group,
    #    so it cannot be stopped for reading the terminal;
    #  - output is shown as it arrives and kept in $INSTALL_LOG;
    #  - a heartbeat every minute says it is alive;
    #  - a process that was stopped anyway is resumed and reported;
    #  - after STALL_SECONDS without output a process report is printed;
    #  - the hard limit is enforced by timeout.
    local limit=$1 label=$2; shift 2
    local out pid start now printed=0 size last_growth last_beat last_report resumed rc=0
    local stall=${STALL_SECONDS:-300}
    out=$(mktemp "${WORK:-/tmp}/cmd.XXXXXX")
    start=$(date +%s); last_growth=$start last_beat=$start last_report=$start
    say "-> $label"
    timeout --foreground -k 30 "$limit" "$@" >"$out" 2>&1 </dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep "${WATCH_INTERVAL:-2}"
        now=$(date +%s)
        size=$(stat -c %s "$out")
        if ((size > printed)); then
            tail -c +$((printed + 1)) "$out" | tee -a "$INSTALL_LOG" 2>/dev/null || true
            printed=$size last_growth=$now
        fi
        resumed=$(unstick "$pid")
        if [[ -n $resumed ]]; then
            say "NOTE: process(es)$resumed had been stopped by the terminal; resumed. Please report this."
        fi
        if ((now - last_beat >= 60)); then
            say "   ... still working on '$label' ($((now - start))s)"
            last_beat=$now
        fi
        if ((now - last_growth >= stall && now - last_report >= stall)); then
            say "   ... no output from '$label' for $((now - last_growth))s. What it is doing:"
            process_report "$pid" | tee -a "$INSTALL_LOG" 2>/dev/null || true
            last_report=$now
        fi
    done
    wait "$pid" || rc=$?
    size=$(stat -c %s "$out")
    if ((size > printed)); then
        tail -c +$((printed + 1)) "$out" | tee -a "$INSTALL_LOG" 2>/dev/null || true
    fi
    rm -f -- "$out"
    if ((rc == 124 || rc == 137)); then
        say "FAILED: '$label' did not finish within ${limit}s and was stopped."
    elif ((rc)); then
        say "FAILED: '$label' exited with status $rc. Full output: $INSTALL_LOG"
    fi
    return "$rc"
}

apt_run() {
    # usage: apt_run SECONDS apt-get-arguments...
    local limit=$1; shift
    watched "$limit" "apt-get $*" apt-get -o DPkg::Lock::Timeout=300 \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}
apt_install() { apt_run 1800 install -y "$@"; }
preflight() {
    [[ $EUID == 0 ]] || fail 'Run with sudo on Ubuntu'
    [[ -f /etc/os-release && -d /run/systemd/system ]] || fail 'Ubuntu with systemd is required'
    # This is an OS-owned file, not a downloaded/user-provided configuration.
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ $ID == ubuntu && $VERSION_ID =~ ^(22.04|24.04|26.04)$ ]] ||
        fail 'Supported target versions: Ubuntu 22.04, 24.04 or 26.04 LTS'
    CODENAME=$VERSION_CODENAME
    ARCH=$(dpkg --print-architecture)
    [[ $ARCH == amd64 || $ARCH == arm64 ]] || fail 'Supported architecture: amd64/arm64; Harvester must also support it'
    if systemctl is-active --quiet tele.service || systemctl is-active --quiet tele-power-guard.timer; then
        fail 'Active field service/timer: arrange controlled bench maintenance first'
    fi
    [[ ! -e /etc/tele/FIELD_ENABLED ]] || fail 'Remove FIELD_ENABLED only in controlled bench maintenance first'
    local startup conflicts='' paths=()
    for startup in /etc/rc.local /etc/crontab /etc/cron.d /var/spool/cron/crontabs \
                   /etc/xdg/autostart /home/*/.config/autostart /root/.config/autostart; do
        [[ ! -e $startup ]] || paths+=("$startup")
    done
    if ((${#paths[@]})); then
        conflicts=$(grep -RIlE 'tele1?\.sh|tele1?\.service' "${paths[@]}" || true)
    fi
    [[ -z $conflicts ]] || fail "Review/remove duplicate TELE startup hooks before installation: $conflicts"
    if systemctl is-enabled --quiet tele1.service; then
        fail 'Legacy tele1.service is enabled; review it in controlled maintenance first'
    fi
    exec 8>/run/lock/tele-install.lock
    flock -n 8 || fail 'Another installer is running'
    exec 9>/run/lock/tele.lock
    flock -n 9 || fail 'Another TELE run is active'
    WORK=$(mktemp -d /var/tmp/tele-install.XXXXXX)
}
require_internet() {
    # Fail early and clearly: everything below downloads packages.
    local try
    for try in 1 2 3 4 5 6; do
        if curl --silent --head --fail --connect-timeout 15 --max-time 25 \
            --proto '=https' https://github.com >/dev/null 2>&1; then
            return 0
        fi
        ((try == 6)) || sleep 10
    done
    fail "No internet: this computer cannot reach github.com.
  Connect the cable or Wi-Fi (or power up Starlink and wait a few minutes), then rerun.
  To find the cause, run:  ping -c 2 1.1.1.1   and   resolvectl status
  Pings work but names do not resolve: the DNS server is wrong or down;
  set another one with  sudo resolvectl dns <interface> 1.1.1.1  and rerun."
}
fetch_release() {
    require_internet
    apt_run 900 update
    apt_install ca-certificates curl jq
    if [[ $BUNDLE == yes ]]; then
        verify_bundle
        SHA=$(<"$SCRIPT_DIR/REVISION")
        mkdir "$WORK/source"
        # Code only: the setup file (passwords) and the .deb never enter the release.
        (cd "$SCRIPT_DIR" && tar --exclude=./setup.conf --exclude='./*.deb' --exclude=./.git \
            --exclude=./MANIFEST.sha256 -cf - .) | tar -x -C "$WORK/source"
    else
        apt_install git
    fi
    if [[ $BUNDLE == yes ]]; then :
    elif [[ -n $SOURCE_DIR ]]; then
        [[ -z $(git -C "$SOURCE_DIR" status --porcelain) ]] || fail 'Local source checkout must be clean and committed'
        SHA=$(git -C "$SOURCE_DIR" rev-parse HEAD)
        git clone --no-hardlinks -- "$SOURCE_DIR" "$WORK/source"
        git -C "$WORK/source" checkout --detach "$SHA"
    else
        git init -q "$WORK/source"
        git -C "$WORK/source" remote add origin https://github.com/TobbeTripitaka/telemetry_setup.git
        timeout --foreground -k 10 300 git -C "$WORK/source" fetch --depth 1 origin "$REF"
        SHA=$(git -C "$WORK/source" rev-parse FETCH_HEAD)
        git -C "$WORK/source" checkout --detach "$SHA"
    fi
    SOURCE=$WORK/source
    [[ -f $SOURCE/lib/workflow.sh && -f $SOURCE/modules/pegasus.sh ]] ||
        fail 'Selected revision lacks this installer/runtime; choose the matching updated release'
    say "Pinned source revision: $SHA"
    # Trusted project code from the selected revision; setup.conf is never sourced.
    source "$SOURCE/lib/common.sh"
    source "$SOURCE/lib/config.sh"
    validate_setup
}
validate_setup() {
    valid_station "$(get station)" || fail 'A valid station is required'
    USER_NAME=$(get OPERATOR_USER tele)
    [[ $USER_NAME =~ ^[a-z_][a-z0-9_-]{0,30}$ && $USER_NAME != root ]] || fail 'Invalid OPERATOR_USER'
    COMPUTER_NAME=$(get COMPUTER_NAME)
    [[ -z $COMPUTER_NAME || $COMPUTER_NAME =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
        fail 'COMPUTER_NAME: lowercase letters, digits and hyphens only (for example tele9)'
    OPERATOR_PASSWORD=$(get OPERATOR_PASSWORD)
    [[ -z $OPERATOR_PASSWORD || $OPERATOR_PASSWORD =~ ^[^[:space:]:]{6,64}$ ]] ||
        fail 'OPERATOR_PASSWORD: 6-64 visible characters, no spaces and no colon'
    if [[ -z $OPERATOR_PASSWORD ]] && ! id "$USER_NAME" >/dev/null 2>&1; then
        fail "OPERATOR_PASSWORD is required to create the account '$USER_NAME'"
    fi
    LOCAL_DATA_VALUE=$(get LOCAL_DATA)
    if [[ -z $LOCAL_DATA_VALUE ]]; then
        [[ $(get RETAIN_LAST_BATCH yes) == no ]] && LOCAL_DATA_VALUE=clean || LOCAL_DATA_VALUE=keep
    fi
    [[ $LOCAL_DATA_VALUE =~ ^(keep|clean)$ ]] || fail 'LOCAL_DATA must be keep or clean'
    REMOTE=$(get RCLONE_REMOTE tele_dropbox)
    node_key RCLONE_REMOTE "$REMOTE" || fail 'Invalid remote name'
    node_key DROPBOX_ROOT "$(get DROPBOX_ROOT)" || fail 'Invalid Dropbox root'
    node_key STARLINK_ADDRESS "$(get STARLINK_ADDRESS 192.168.100.1:9200)" || fail 'Invalid Starlink address'
    local key
    for key in ENABLE_VNC DISABLE_SLEEP UPLOAD_TEST EMAIL_TEST \
               SYSTEM_UPGRADE DISABLE_AUTO_UPDATES AUTOLOGIN; do
        [[ $(get "$key" yes) =~ ^(yes|no)$ ]] || fail "$key must be yes/no"
    done
    [[ $(get STARLINK_SNOW_MELT read) =~ ^(read|off)$ ]] || fail 'STARLINK_SNOW_MELT must be read/off'
    integer_between "$(get EMERGENCY_SECONDS 14400)" 3600 86400 || fail 'Emergency limit: 3600..86400 seconds'
    runtime_defaults
    runtime_key EXECUTE "$(get EXECUTE auto)" || fail 'Invalid EXECUTE'
    runtime_key HARVEST_BUDGET_SECONDS "$(get HARVEST_BUDGET_SECONDS 3600)" || fail 'Invalid harvest budget'
    runtime_key MAINTENANCE_IDLE_SECONDS "$(get MAINTENANCE_IDLE_SECONDS 600)" || fail 'Invalid maintenance window'
    runtime_key NETWORK_WAIT_SECONDS "$(get NETWORK_WAIT_SECONDS 1200)" || fail 'NETWORK_WAIT_SECONDS: 0..3600'
    [[ $EXECUTE != vnc || $(get ENABLE_VNC yes) == yes ]] || fail 'EXECUTE=vnc requires ENABLE_VNC=yes'
    for key in EMAIL_FROM EMAIL_TO EMAIL_PASSWORD; do
        credential_key "$key" "$(get "$key")" || fail "Missing/invalid $key"
    done
    if [[ $(get ENABLE_VNC yes) == yes ]]; then
        [[ $(get VNC_PASSWORD) =~ ^[[:graph:]]{8}$ ]] || fail 'VNC_PASSWORD must be exactly 8 printable ASCII characters'
    fi
    [[ -z $(get RCLONE_CONFIG_FILE) || -z $(get DROPBOX_TOKEN_JSON) ]] ||
        fail 'Choose RCLONE_CONFIG_FILE OR DROPBOX_TOKEN_JSON, not both'
    if [[ -n $(get RCLONE_CONFIG_FILE) ]]; then private_file "$(get RCLONE_CONFIG_FILE)"
    elif [[ -n $(get DROPBOX_TOKEN_JSON) ]]; then
        printf '%s' "$(get DROPBOX_TOKEN_JSON)" | jq -e \
            'type=="object" and (.access_token|type=="string") and (.refresh_token|type=="string")' >/dev/null ||
            fail 'Supply the full rclone OAuth JSON, including refresh_token'
    else
        private_file /etc/tele/rclone.conf
    fi
    local config_dir deb found
    config_dir=${CONFIG_DIR:-$(dirname -- "$(readlink -f -- "$CONFIG")")}
    if [[ -n $(get HARVESTER_DEB) && $(get HARVESTER_DEB) != /* ]]; then
        # A bare file name means "next to the credentials file".
        SETUP[HARVESTER_DEB]="$config_dir/$(get HARVESTER_DEB)"
    fi
    if [[ -z $(get HARVESTER_DEB) && -z $(get HARVESTER_URL) &&
          ! -x $(get PEGASUS_BIN /opt/PegasusHarvester/resources/app/node_modules/@nanometrics/pegasus-harvest-lib/build/Release/harvester) ]]; then
        found=$(find "$config_dir" -maxdepth 1 -type f -iname '*harvester*.deb' | sort)
        if [[ -n $found && $(wc -l <<<"$found") == 1 ]]; then
            SETUP[HARVESTER_DEB]=$found
            say "Using the Nanometrics package found next to the setup file: $found"
        fi
    fi
    if [[ -n $(get HARVESTER_DEB) ]]; then
        [[ -f $(get HARVESTER_DEB) ]] || fail "Harvester package not found: $(get HARVESTER_DEB)"
    fi
    [[ -z $(get HARVESTER_DEB) || -z $(get HARVESTER_URL) ]] || fail 'Choose one Harvester package input'
    if [[ -n $(get HARVESTER_DEB) || -n $(get HARVESTER_URL) ]]; then
        [[ $(get HARVESTER_SHA256) =~ ^[a-fA-F0-9]{64}$ ]] || fail 'Harvester package requires trusted SHA256'
    fi
    if [[ -n $(get HARVESTER_URL) ]]; then
        [[ $(get HARVESTER_URL) =~ ^https://[A-Za-z0-9.-]+/[^?\#@[:space:]]+$ ]] ||
            fail 'Use a public HTTPS package URL without credentials/query; otherwise use a local .deb'
    fi
    BIN=$(get PEGASUS_BIN /opt/PegasusHarvester/resources/app/node_modules/@nanometrics/pegasus-harvest-lib/build/Release/harvester)
    [[ $BIN == /* && $BIN != *$'\n'* ]] || fail 'PEGASUS_BIN must be an absolute path'
    if [[ -z $(get HARVESTER_DEB) && -z $(get HARVESTER_URL) && ! -x $BIN ]]; then
        fail 'Supply the authorized Nanometrics .deb and SHA256, or install the native binary first'
    fi
    if [[ -n $(get SOURCES_JSON) ]]; then
        printf '%s' "$(get SOURCES_JSON)" >"$WORK/sources.json"
        jq -e 'type=="array" and length>0 and length<=16 and
            all(.[]; (keys|sort)==["device","id","serial"] and
                (.id|test("^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")) and
                (.serial|test("^[A-Za-z0-9][A-Za-z0-9_.-]*$")) and
                (.device|test("^/dev/disk/by-id/[A-Za-z0-9_.:+-]+$")) and
                (.device|test("-part[0-9]+$")|not)) and
            ([.[].id]|length)==([.[].id|ascii_downcase]|unique|length) and
            ([.[].serial]|length)==([.[].serial|ascii_downcase]|unique|length)' "$WORK/sources.json" >/dev/null ||
            fail 'Invalid/duplicate recorder profiles in SOURCES_JSON'
    elif [[ -n $(get RECORDER_DEVICE) || -n $(get RECORDER_SERIAL) ]]; then
        [[ $(get RECORDER_DEVICE) =~ ^/dev/disk/by-id/[A-Za-z0-9_.:+-]+$ &&
           ! $(get RECORDER_DEVICE) =~ -part[0-9]+$ &&
           $(get RECORDER_SERIAL) =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ||
            fail 'RECORDER_DEVICE and RECORDER_SERIAL must be given together (whole-disk by-id path), or leave both empty for automatic detection'
    fi
}
verify_bundle() {
    # Detect a damaged or partly copied bundle before anything is installed.
    [[ -f $SCRIPT_DIR/MANIFEST.sha256 && -f $SCRIPT_DIR/REVISION ]] ||
        fail 'This folder is not a complete TELE bundle (MANIFEST.sha256 or REVISION missing)'
    (cd "$SCRIPT_DIR" && sha256sum --check --quiet MANIFEST.sha256) ||
        fail 'The bundle is damaged or was modified: copy/unzip it again'
    [[ $(<"$SCRIPT_DIR/REVISION") =~ ^[0-9a-f]{40}$ ]] || fail 'Invalid REVISION in bundle'
    say "Bundle verified. TELE revision $(<"$SCRIPT_DIR/REVISION")"
}
verified_deb() {
    local base=$1 package=$2 manifest=$3 expected actual
    download "$base/$package" "$WORK/$package"
    download "$base/$manifest" "$WORK/$manifest"
    expected=$(awk -v name="$package" '$2==name || $2=="*"name {print $1}' "$WORK/$manifest")
    [[ $expected =~ ^[a-fA-F0-9]{64}$ ]] || fail "No unique checksum for $package"
    actual=$(sha256sum "$WORK/$package"); actual=${actual%% *}
    [[ ${actual,,} == "${expected,,}" ]] || fail "Checksum failed: $package"
    chmod 644 "$WORK/$package"
    apt_install "$WORK/$package"
}
system_updates() {
    # Field boots are short and battery-powered: background apt/snap updates
    # waste Starlink data and can delay poweroff by up to 30 minutes. Update
    # once here on the bench instead, then update deliberately at maintenance.
    if [[ $(get SYSTEM_UPGRADE yes) != yes ]]; then
        say 'SYSTEM_UPGRADE=no: skipping the Ubuntu and snap update (only the next steps run).'
    fi
    if [[ $(get SYSTEM_UPGRADE yes) == yes ]]; then
        apt_run 900 update
        apt_run 3600 -y upgrade --with-new-pkgs
        # Drop packages nothing needs any more (old kernels, headers). Tidiness
        # only, so a failure here is reported but never stops the installation.
        apt_run 1800 -y autoremove --purge ||
            say 'WARNING: apt autoremove did not finish; run it later: sudo apt autoremove --purge'
        if command -v snap >/dev/null; then
            watched 1800 'snap refresh' snap refresh ||
                say 'WARNING: snap refresh incomplete (close running apps such as Firefox and rerun later)'
        fi
        if [[ -e /var/run/reboot-required ]]; then
            say 'NOTE: Ubuntu requests a reboot. Finish installation, then reboot on the bench before field activation.'
        fi
    fi
    if [[ $(get DISABLE_AUTO_UPDATES yes) == yes ]]; then
        printf '%s\n' \
            '// TELE field station: no background package updates during short battery boots.' \
            '// Update on the bench: sudo apt update && sudo apt upgrade && sudo apt autoremove --purge && sudo snap refresh' \
            'APT::Periodic::Update-Package-Lists "0";' \
            'APT::Periodic::Download-Upgradeable-Packages "0";' \
            'APT::Periodic::AutocleanInterval "0";' \
            'APT::Periodic::Unattended-Upgrade "0";' >"$WORK/apt-no-auto.conf"
        install -m 644 "$WORK/apt-no-auto.conf" "$APT_NO_AUTO_CONF"
        local timer
        for timer in apt-daily.timer apt-daily-upgrade.timer fwupd-refresh.timer motd-news.timer; do
            if systemctl cat "$timer" >/dev/null 2>&1; then systemctl disable --now "$timer"; fi
        done
        if command -v snap >/dev/null; then
            timeout --foreground -k 10 120 snap refresh --hold ||
                say 'WARNING: snap refresh --hold failed; snaps may still update during field boots'
        fi
        say 'Automatic apt/snap updates are off. Update deliberately on the bench (see INSTALLATION.md).'
    fi
}
install_packages() {
    apt_install bash coreutils util-linux findutils grep sed gawk openssh-server \
        iproute2 procps usbutils file rsync tzdata dbus gnupg dconf-cli
    verified_deb https://github.com/rclone/rclone/releases/download/v1.75.2 \
        "rclone-v1.75.2-linux-$ARCH.deb" SHA256SUMS
    verified_deb https://github.com/fullstorydev/grpcurl/releases/download/v1.9.4 \
        "grpcurl_1.9.4_linux_$ARCH.deb" grpcurl_1.9.4_checksums.txt
    if [[ $(get ENABLE_VNC yes) == yes ]]; then
        apt_install xfce4 xfce4-terminal dbus-x11 tigervnc-standalone-server tigervnc-tools
    fi
    local package='' actual
    if [[ -n $(get HARVESTER_DEB) ]]; then
        cp -- "$(get HARVESTER_DEB)" "$WORK/harvester.deb"; package=$WORK/harvester.deb
    elif [[ -n $(get HARVESTER_URL) ]]; then
        download "$(get HARVESTER_URL)" "$WORK/harvester.deb"; package=$WORK/harvester.deb
    fi
    if [[ -n $package ]]; then
        actual=$(sha256sum "$package"); actual=${actual%% *}
        [[ ${actual,,} == "$(get HARVESTER_SHA256 | tr '[:upper:]' '[:lower:]')" ]] || fail 'Harvester checksum mismatch'
        [[ $(dpkg-deb -f "$package" Architecture) == "$ARCH" ||
           $(dpkg-deb -f "$package" Architecture) == all ]] || fail 'Harvester package architecture mismatch'
        chmod 644 "$package"; apt_install "$package"
    fi
    [[ -x $BIN ]] || fail 'Native Harvester is not executable at PEGASUS_BIN'
    check_harvester_version
}
check_harvester_version() {
    # The Nanometrics CLI can print everything correctly and still exit with
    # status 1, so judge this by what it reports, not by its exit status.
    local report
    report=$(timeout --foreground -k 5 30 "$BIN" version -all 2>&1 </dev/null) || true
    say "$report"
    [[ $report == *'Harvester CL - v'* ]] ||
        fail "The native Harvester did not report a version; run: $BIN version -all"
}
set_computer_name() {
    [[ -n $COMPUTER_NAME ]] || return 0
    hostnamectl set-hostname "$COMPUTER_NAME"
    if grep -qE '^127\.0\.1\.1[[:space:]]' "$HOSTS_FILE"; then
        sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1 $COMPUTER_NAME/" "$HOSTS_FILE"
    else
        printf '127.0.1.1 %s\n' "$COMPUTER_NAME" >>"$HOSTS_FILE"
    fi
    say "Computer name: $COMPUTER_NAME"
}
set_operator_account() {
    if ! id "$USER_NAME" >/dev/null 2>&1; then
        useradd --create-home --shell /bin/bash "$USER_NAME"
    fi
    [[ $(getent passwd "$USER_NAME" | cut -d: -f6) == "/home/$USER_NAME" ]] ||
        fail 'VNC unit requires operator home /home/OPERATOR_USER'
    if [[ -n $OPERATOR_PASSWORD ]]; then
        # printf is a shell builtin, so the password never appears in a process list.
        printf '%s:%s\n' "$USER_NAME" "$OPERATOR_PASSWORD" | chpasswd
    fi
    # Maintenance by SSH/VNC needs sudo with the account's own password. The TELE
    # services themselves run as root under systemd and never use sudo.
    usermod -aG sudo "$USER_NAME"
    say "Account '$USER_NAME' is ready."
}
set_autologin() {
    [[ $(get AUTOLOGIN yes) == yes ]] || return 0
    local touched=no conf="$GDM_DIR/custom.conf"
    if [[ -d "$GDM_DIR" ]]; then
        [[ -e $conf ]] || install -m 644 /dev/null "$conf"
        [[ -e $conf.tele-original ]] || cp -a -- "$conf" "$conf.tele-original"
        grep -vE '^[#[:space:]]*AutomaticLogin(Enable)?[[:space:]]*=' "$conf" >"$WORK/gdm.conf" || true
        if grep -q '^\[daemon\]' "$WORK/gdm.conf"; then
            sed -i "/^\[daemon\]/a AutomaticLoginEnable=true\nAutomaticLogin=$USER_NAME" "$WORK/gdm.conf"
        else
            printf '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=%s\n' "$USER_NAME" >>"$WORK/gdm.conf"
        fi
        install -m 644 "$WORK/gdm.conf" "$conf"
        touched=yes
    fi
    if [[ -d "$LIGHTDM_DIR" ]]; then
        install -d -m 755 "$LIGHTDM_DIR/lightdm.conf.d"
        printf '[Seat:*]\nautologin-user=%s\nautologin-user-timeout=0\n' "$USER_NAME" \
            >"$LIGHTDM_DIR/lightdm.conf.d/50-tele-autologin.conf"
        touched=yes
    fi
    # No lock screen, no screen blanking, no sleep from the desktop settings.
    install -d -m 755 "$DCONF_DIR/profile" "$DCONF_DIR/db/local.d"
    if ! grep -qx 'system-db:local' "$DCONF_DIR/profile/user" 2>/dev/null; then
        printf 'user-db:user\nsystem-db:local\n' >"$DCONF_DIR/profile/user"
    fi
    printf '%s\n' \
        '[org/gnome/desktop/screensaver]' 'lock-enabled=false' 'idle-activation-enabled=false' '' \
        '[org/gnome/desktop/session]' 'idle-delay=uint32 0' '' \
        '[org/gnome/settings-daemon/plugins/power]' \
        "sleep-inactive-ac-type='nothing'" "sleep-inactive-battery-type='nothing'" \
        >"$DCONF_DIR/db/local.d/00-tele-field"
    dconf update
    # Skip the first-run welcome wizard for this account.
    install -d -o "$USER_NAME" -g "$(id -gn "$USER_NAME")" -m 700 "$HOME_BASE/$USER_NAME/.config"
    printf 'yes\n' >"$HOME_BASE/$USER_NAME/.config/gnome-initial-setup-done"
    chown "$USER_NAME:$(id -gn "$USER_NAME")" "$HOME_BASE/$USER_NAME/.config/gnome-initial-setup-done"
    if [[ $touched == yes ]]; then
        say "Automatic login for '$USER_NAME' and no lock screen take effect at the next boot."
    else
        say 'WARNING: no GDM or LightDM found (server install?). Automatic login was not configured.'
    fi
}
linux_settings() {
    set_computer_name
    set_operator_account
    set_autologin
    timedatectl set-timezone UTC
    if [[ $(timedatectl show -p CanNTP --value) == no ]]; then
        apt_install systemd-timesyncd
        systemctl enable --now systemd-timesyncd
    fi
    timedatectl set-ntp true
    if [[ $(get DISABLE_SLEEP yes) == yes ]]; then
        systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
    fi
    systemctl enable --now ssh
    # Do not change firewalls, sudo policy, network routes or BIOS.
}
install_tailscale() {
    download "https://pkgs.tailscale.com/stable/ubuntu/$CODENAME.noarmor.gpg" "$WORK/tailscale.gpg"
    download "https://pkgs.tailscale.com/stable/ubuntu/$CODENAME.tailscale-keyring.list" "$WORK/tailscale.list"
    install -m 644 "$WORK/tailscale.gpg" /usr/share/keyrings/tailscale-archive-keyring.gpg
    install -m 644 "$WORK/tailscale.list" /etc/apt/sources.list.d/tailscale.list
    apt_run 900 update
    apt_install tailscale
    systemctl enable --now tailscaled
    if tailscale status --json >"$WORK/tailscale-status.json" &&
       jq -e '.BackendState=="Running"' "$WORK/tailscale-status.json" >/dev/null; then
        timeout --foreground -k 5 60 tailscale set --ssh=true
    else
        [[ -n $(get TAILSCALE_AUTH_KEY) ]] || fail 'TAILSCALE_AUTH_KEY required unless already enrolled'
        printf '%s' "$(get TAILSCALE_AUTH_KEY)" >"$WORK/tailscale.key"
        timeout --foreground -k 10 120 tailscale up --auth-key="file:$WORK/tailscale.key" --ssh
        rm -f "$WORK/tailscale.key"
    fi
}
install_release_and_config() {
    local version release key file
    version=$(<"$SOURCE/VERSION")
    [[ $version =~ ^[A-Za-z0-9_.-]+$ ]] || fail 'Invalid VERSION'
    release="/opt/tele/releases/$version-$SHA"
    install -d -m 755 /opt/tele/releases /etc/tele
    if [[ ! -d $release ]]; then
        mkdir "$WORK/release"
        if [[ $BUNDLE == yes ]]; then
            cp -a "$SOURCE/." "$WORK/release/"
        else
            git -C "$SOURCE" archive HEAD | tar -x -C "$WORK/release"
        fi
        chmod 755 "$WORK/release/tele.sh" "$WORK/release/scripts/"*.sh
        chown -R root:root "$WORK/release"
        cp -a "$WORK/release" "$release.install-$$"
        mv -T "$release.install-$$" "$release"
        chmod 755 "$release"
    fi
    # Preserve private settings for rollback; never erase pending/verified state.
    if [[ -f /etc/tele/node.conf ]]; then
        local backup
        backup="/var/backups/tele/$(date -u +%Y%m%dT%H%M%SZ)-$$"
        install -d -m 700 "$backup"
        cp -a /etc/tele/. "$backup/"
        say "Previous private settings saved in $backup"
    fi
    mkdir "$WORK/config"
    {
        printf 'RCLONE_REMOTE=%s\nDROPBOX_ROOT=%s\n' "$REMOTE" "$DROPBOX_ROOT"
        printf 'RCLONE_CONFIG=/etc/tele/rclone.conf\nSOURCE_PROFILES_DIR=/etc/tele/sources.d\n'
        printf 'PEGASUS_BIN=%s\nVNC_SERVICE=tele-vnc@%s.service\nVNC_PORT=5901\n' "$BIN" "$USER_NAME"
        printf 'STARLINK_ADDRESS=%s\nSTARLINK_EXPECT_SNOW_OFF=%s\n' "$STARLINK_ADDRESS" \
            "$([[ $(get STARLINK_SNOW_MELT read) == off ]] && printf yes || printf no)"
        if [[ ! -f $WORK/sources.json && -n $(get RECORDER_DEVICE) ]]; then
            printf 'RECORDER_DEVICE=%s\nRECORDER_SERIAL=%s\n' "$(get RECORDER_DEVICE)" "$(get RECORDER_SERIAL)"
        fi
    } >"$WORK/config/node.conf"
    {
        printf 'station=%s\nHARVEST_MODE=incremental\n' "$(get station)"
        printf 'EXECUTE=%s\n' "$(get EXECUTE auto)"
        printf 'HARVEST_BUDGET_SECONDS=%s\n' "$(get HARVEST_BUDGET_SECONDS 3600)"
        printf 'MAINTENANCE_IDLE_SECONDS=%s\n' "$(get MAINTENANCE_IDLE_SECONDS 600)"
        printf 'NETWORK_WAIT_SECONDS=%s\n' "$(get NETWORK_WAIT_SECONDS 1200)"
        printf 'LOCAL_DATA=%s\n' "$LOCAL_DATA_VALUE"
    } >"$WORK/config/config.txt"
    for key in EMAIL_FROM EMAIL_TO EMAIL_PASSWORD; do
        printf '%s=%s\n' "$key" "$(get "$key")"
    done >"$WORK/config/credentials.txt"
    if [[ -n $(get RCLONE_CONFIG_FILE) ]]; then
        # Capture selected remote privately; never print OAuth tokens.
        RCLONE_CONFIG=$(get RCLONE_CONFIG_FILE) timeout --foreground -k 5 60 \
            rclone --ask-password=false config show "$REMOTE" >"$WORK/config/rclone.conf"
        grep -Fxq "[$REMOTE]" "$WORK/config/rclone.conf" || fail 'Named remote not found'
    elif [[ -n $(get DROPBOX_TOKEN_JSON) ]]; then
        printf '[%s]\ntype = dropbox\ntoken = %s\n' "$REMOTE" "$(get DROPBOX_TOKEN_JSON)" >"$WORK/config/rclone.conf"
    else
        cp /etc/tele/rclone.conf "$WORK/config/rclone.conf"
    fi
    chmod 600 "$WORK/config/"*
    # Validate generated data before replacing the live files.
    (load_node_config "$WORK/config/node.conf"; load_local_config "$WORK/config/config.txt")
    for file in node.conf config.txt credentials.txt rclone.conf; do
        install -m 600 "$WORK/config/$file" "/etc/tele/.$file.new"
        mv -fT "/etc/tele/.$file.new" "/etc/tele/$file"
    done
    mkdir "$WORK/profiles"
    if [[ -f $WORK/sources.json ]]; then
        local id device serial
        while IFS=$'\t' read -r id device serial; do
            printf 'TYPE=pegasus\nRECORDER_DEVICE=%s\nRECORDER_SERIAL=%s\n' "$device" "$serial" \
                >"$WORK/profiles/$id.conf"
        done < <(jq -r '.[]|[.id,.device,.serial]|@tsv' "$WORK/sources.json")
    fi
    # Setup file is authoritative for profiles. Existing files were backed up.
    if [[ -d /etc/tele/sources.d ]]; then
        mv /etc/tele/sources.d "/etc/tele/sources.previous-$(date +%s)-$$"
    fi
    install -d -m 700 /etc/tele/sources.d
    for file in "$WORK/profiles/"*.conf; do
        [[ ! -f $file ]] || install -m 600 "$file" /etc/tele/sources.d/
    done
    # VNC runs as the operator, so it needs traversal/read access to release code.
    find "$release" -type d -exec chmod 755 {} +
    find "$release" -type f -exec chmod a+r {} +
    ln -s "$release" /opt/tele/.current-install-$$
    mv -fT /opt/tele/.current-install-$$ /opt/tele/current
    printf '%s\n' "$SHA" >/etc/tele/installed-revision
}
install_services() {
    # VNC is optional: its unit is only installed (and checked) when VNC is enabled,
    # because it needs tigervnc, which is not installed otherwise.
    local unit units=(tele.service tele-power-guard.timer tele-poweroff.service)
    [[ $(get ENABLE_VNC yes) != yes ]] || units+=(tele-vnc@.service)
    install -d -m 755 "$UNIT_DIR"
    for unit in "${units[@]}"; do
        install -m 644 "$SOURCE/systemd/$unit" "$UNIT_DIR/$unit"
    done
    install -d -m 755 "$UNIT_DIR/tele.service.d" "$UNIT_DIR/tele-power-guard.timer.d"
    printf '[Service]\nRuntimeMaxSec=%ss\n' "$(get EMERGENCY_SECONDS 14400)" \
        >"$UNIT_DIR/tele.service.d/limit.conf"
    printf '[Timer]\nOnBootSec=\nOnBootSec=%ss\n' "$(get EMERGENCY_SECONDS 14400)" \
        >"$UNIT_DIR/tele-power-guard.timer.d/limit.conf"
    if [[ $(get ENABLE_VNC yes) == yes ]]; then
        install -d -m 755 /etc/tele/vnc
        printf '%s\n' "$(get VNC_PASSWORD)" | tigervncpasswd -f >"$WORK/vnc.passwd"
        install -o "$USER_NAME" -g "$(id -gn "$USER_NAME")" -m 600 \
            "$WORK/vnc.passwd" "/etc/tele/vnc/$USER_NAME.passwd"
    elif [[ -e $UNIT_DIR/tele-vnc@.service ]]; then
        # A unit left from an earlier VNC installation would fail verification.
        rm -f -- "$UNIT_DIR/tele-vnc@.service"
    fi
    systemctl daemon-reload
    local files=()
    for unit in "${units[@]}"; do files+=("$UNIT_DIR/$unit"); done
    systemd-analyze verify "${files[@]}"
    # No --now: boot activation is a separate, last stage.
}
check_connections() {
    # Release lock only for the preflight entrypoint, then reacquire.
    flock -u 9
    /opt/tele/current/tele.sh --check
    flock -n 9 || fail 'Another TELE run started during checks'
    (
        source /opt/tele/current/tele.sh
        load_node_config /etc/tele/node.conf
        load_local_config /etc/tele/config.txt
        init_workspace
        load_credentials /etc/tele/credentials.txt
        check_dependencies
        # Listing errors are failures, never treated as "missing config".
        cloud mkdir "$REMOTE_BASE"
        cloud lsf "$REMOTE_BASE" --max-depth 1 --files-only >"$WORK/remote-files"
        if grep -Fxq config.txt "$WORK/remote-files"; then
            cloud copyto "$REMOTE_BASE/config.txt" "$WORK/remote-config"
            (runtime_defaults; read_kv "$WORK/remote-config" runtime_key; validate_runtime "$STATION_NAME") ||
                fail 'Existing remote config is invalid or belongs to another station; not overwritten'
            say 'Existing Dropbox config preserved (including its current collection/maintenance mode).'
        else
            cloud copyto /etc/tele/config.txt "$REMOTE_BASE/config.txt" --immutable
        fi
        if [[ $(get UPLOAD_TEST yes) == yes ]]; then
            printf 'TELE verified installation probe %s\n' "$SHA" >"$WORK/probe.txt"
            local_probe="$REMOTE_BASE/tele_logfiles/installation/$RUN_ID.txt"
            cloud copyto "$WORK/probe.txt" "$local_probe"
            cloud copyto "$local_probe" "$WORK/probe-return.txt"
            cmp "$WORK/probe.txt" "$WORK/probe-return.txt"
            say 'Small upload/download verification passed; probe retained with station logs.'
        fi
        if [[ $(get EMAIL_TEST yes) == yes ]]; then
            RUN_MODE=check
            send_notification INSTALLATION_CHECK || fail 'Test email failed'
        fi
    )
}
check_starlink() {
    if [[ $(get STARLINK_SNOW_MELT read) == off ]]; then
        STARLINK_ADDRESS=$STARLINK_ADDRESS /opt/tele/current/scripts/STARLINK.sh snow-melt-off --confirm
    else
        if ! STARLINK_ADDRESS=$STARLINK_ADDRESS /opt/tele/current/scripts/STARLINK.sh snow-melt; then
            say 'WARNING: Starlink local API unavailable. Resolve Ethernet routing/firmware access before field deployment.'
            [[ $ENABLE_FIELD != yes ]] || fail 'Starlink check failed; refusing field activation'
        fi
    fi
}
enable_field() {
    say 'Enabling shutdown-capable collection for the NEXT boot. No reboot is requested.'
    say "Emergency poweroff: $(get EMERGENCY_SECONDS 14400) seconds after boot, even with SSH/VNC."
    install -m 600 /dev/null /etc/tele/FIELD_ENABLED
    if ! systemctl enable tele-power-guard.timer tele.service; then
        rm -f /etc/tele/FIELD_ENABLED
        systemctl disable tele-power-guard.timer tele.service || true
        fail 'Field activation failed; activation marker removed'
    fi
}
main() {
    while (($#)); do
        case "$1" in
            --config|--mode|--ref|--source-dir)
                [[ $# -ge 2 ]] || fail "Missing value for $1"
                case "$1" in
                    --config) CONFIG=$2 ;; --mode) MODE=$2 MODE_SET=yes ;;
                    --ref) REF=$2 ;; --source-dir) SOURCE_DIR=$2 ;;
                esac
                shift 2 ;;
            --enable-field) ENABLE_FIELD=yes; shift ;;
            -h|--help) usage; return ;;
            *) fail "Unknown option: $1" ;;
        esac
    done
    [[ $MODE =~ ^(confirm|auto|plan)$ ]] || fail 'Mode must be confirm, auto or plan'
    [[ $REF =~ ^[A-Za-z0-9][A-Za-z0-9_./-]*$ ]] || fail 'Invalid Git ref'
    if [[ $MODE == plan ]]; then
        say 'PLAN ONLY: no downloads, configuration reads, root changes or network calls.'
        say '1. Check Ubuntu, locks and inactive field mode.'
        say '2. Install bootstrap tools, fetch one Git revision (or verify the bundle), validate private setup.'
        say '3. Update Ubuntu/snaps once; turn off automatic apt/snap updates for field boots.'
        say '3b. Install dependencies, pinned rclone/grpcurl and approved Harvester.'
        say '4. Set computer name, operator account and password, automatic login, no lock screen, UTC/NTP, optional sleep masks and SSH.'
        say '5. Install/enroll Tailscale with SSH enabled.'
        say '6. Back up private settings, deploy release, write configuration/profiles.'
        say '7. Install VNC and inactive systemd power-protection units.'
        say '8. Preflight recorder/Dropbox; preserve/create remote config; optional upload/email tests.'
        say '9. Read Starlink snow setting, or explicitly requested verified off attempt.'
        say "10. Field activation for next boot: $ENABLE_FIELD. No reboot/poweroff."
        return
    fi
    if [[ -z $CONFIG && -z $SOURCE_DIR && -f $SCRIPT_DIR/setup.conf && -f $SCRIPT_DIR/REVISION &&
          -f $SCRIPT_DIR/lib/workflow.sh ]]; then
        BUNDLE=yes
        # A technician run: no questions between stages unless asked for.
        [[ $MODE_SET == yes ]] || MODE=auto
    fi
    [[ -n $CONFIG || $BUNDLE == yes ]] || fail '--config is required (or run inside an unzipped TELE bundle)'
    trap cleanup EXIT
    if [[ $BUNDLE == yes ]]; then
        [[ $EUID == 0 ]] || fail 'Run with sudo:  sudo bash INSTALL.sh'
        # Files from a zip belong to the desktop user; work from a private root-owned copy.
        PRIVATE_CONF=$(mktemp /var/tmp/tele-setup.XXXXXX)
        install -m 600 -o root -g root "$SCRIPT_DIR/setup.conf" "$PRIVATE_CONF"
        CONFIG=$PRIVATE_CONF CONFIG_DIR=$SCRIPT_DIR
    fi
    parse_setup
    step 'Check station and acquire locks' preflight
    step 'Fetch and pin TELE; validate setup' fetch_release
    step 'Update Ubuntu once and turn off automatic updates' system_updates
    step 'Install application dependencies and native Harvester' install_packages
    step 'Configure Linux account, clock, sleep and SSH' linux_settings
    step 'Install and authorize Tailscale SSH' install_tailscale
    step 'Deploy TELE and private configuration' install_release_and_config
    step 'Install private VNC and power-protection services' install_services
    step 'Check recorder, Dropbox and email' check_connections
    step 'Check Starlink snow-melt configuration' check_starlink
    if [[ $ENABLE_FIELD == yes ]]; then step 'Enable field operation for next boot' enable_field; fi
    say "Installed TELE revision $SHA. No reboot or poweroff was requested."
    if [[ $BUNDLE == yes ]]; then
        say "This folder holds passwords (setup.conf). Delete it when the installation is accepted:"
        say "  sudo rm -rf '$SCRIPT_DIR'"
    fi
    say 'Verify BIOS wake, USB relay cutoff, native exports and remote access physically.'
    say 'Bench collection: sudo /opt/tele/current/tele.sh --once'
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
