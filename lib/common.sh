#!/usr/bin/env bash
# Shared primitives. Logs go to stderr, never to command-substitution results.
log() {
    local message
    message="$(date -u +%FT%TZ) $*"
    printf '%s\n' "$message" >&2
    if [[ -n ${LOG_FILE:-} ]]; then
        printf '%s\n' "$message" >>"$LOG_FILE" || true
    fi
}
die() { log "ERROR: $*"; return 1; }
uptime_seconds() { local value rest; read -r value rest </proc/uptime; printf '%s\n' "${value%%.*}"; }

atomic_install() {
    # Source must be complete and on the same filesystem as the destination.
    local src=$1 dst=$2
    sync -f "$src" || return 1
    mv -fT -- "$src" "$dst" || return 1
    sync -f "$(dirname -- "$dst")"
}

check_private_file() {
    local file=$1 mode owner
    [[ -f $file && ! -L $file ]] || return 1
    mode=$(stat -c %a -- "$file") || return 1
    owner=$(stat -c %u -- "$file") || return 1
    [[ $owner == "$EUID" ]] && (( (8#$mode & 077) == 0 ))
}

init_workspace() {
    STATE_ROOT="/var/lib/tele1/$STATION_NAME"
    SPOOL="$STATE_ROOT/pending"
    VERIFIED="$STATE_ROOT/verified"
    OWNERS="$STATE_ROOT/owners"
    LAST_BATCH="$STATE_ROOT/last-verified"
    LOG_ROOT="/var/log/tele1/$STATION_NAME"
    mkdir -p -- "$SPOOL" "$VERIFIED" "$OWNERS" "$LOG_ROOT"
    RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    LOG_FILE="$LOG_ROOT/$RUN_ID.log"
    touch "$LOG_FILE"
    REMOTE_BASE="$RCLONE_REMOTE:$DROPBOX_ROOT/tele/$STATION_NAME"
    REMOTE_DATA="$REMOTE_BASE/pegasus_harvester"
}

check_dependencies() {
    local cmd
    for cmd in jq rclone timeout flock lsblk readlink findmnt sha256sum date sync curl ss ps; do
        command -v "$cmd" >/dev/null || { die "Missing dependency: $cmd"; return 1; }
    done
    check_private_file "$RCLONE_CONFIG" || { die "Unsafe/missing rclone config"; return 1; }
    export RCLONE_CONFIG
}

disk_has_reserve() {
    local available
    available=$(df -Pk "$STATE_ROOT" | awk 'NR==2 {print $4}') || return 1
    [[ $available =~ ^[0-9]+$ ]] && (( available >= MIN_FREE_MIB * 1024 ))
}

# All network operations are bounded. Never echo a credential-bearing command.
cloud() {
    timeout --signal=TERM --kill-after=10 "$NETWORK_TIMEOUT_SECONDS" \
        rclone "$@" --contimeout 15s --timeout 45s --retries 2 \
        --low-level-retries 3 --transfers 2 --checkers 2 \
        --dropbox-batch-mode sync
}
