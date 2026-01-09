#!/bin/bash

# remote.sh - Remote desktop and SSH connection info for TELE1
# Tobias Stål 2025

[[ -n "${REMOTE_LIB_LOADED:-}" ]] && return 0
readonly REMOTE_LIB_LOADED=1

readonly VNC_PASSWORD="YourSecureVNCPassword123" # CHANGE THIS!
readonly VNC_PORT=5900
readonly VNC_PASS_FILE="/tmp/x11vnc_tele.pass"
readonly VNC_INFO_FILE="/tmp/vnc_connection_info.txt"
readonly VNC_EXTEND_FLAG="/tmp/vnc_extend.flag"
readonly VNC_LOG_FILE="/tmp/x11vnc_tele.log"

################################################################################
# NETWORK UTILITIES
################################################################################

get_ipv6_address() {
    ip -6 addr show scope global | grep inet6 | grep -v "temporary" | awk '{print $2}' | cut -d/ -f1 | head -1
}

get_ipv4_address() {
    timeout 8 curl -s https://ipv4.icanhazip.com 2>/dev/null | tr -d '\n' || echo "N/A"
}

################################################################################
# CONNECTION INFO GENERATION
################################################################################

create_connection_info() {
    local wait_time="$1"
    local vnc_pw="$2"
    local ipv6=$(get_ipv6_address)
    local ipv4=$(get_ipv4_address)
    local uname=$(whoami)
    local hostname=$(hostname)

    cat > "$VNC_INFO_FILE" <<EOF
================================================================
TELE1 Remote Connection Information
================================================================

Generated: $(date '+%Y-%m-%d %H:%M:%S')
Wait time: ${wait_time} hour(s)
System: $hostname
User: $uname

================================================================
SSH CONNECTION
================================================================

IPv4 Address: $ipv4
IPv6 Address: ${ipv6:-N/A}
SSH Port: 22

SSH command (IPv4):
  ssh $uname@$ipv4

SSH command (IPv6):
  ssh $uname@[${ipv6:-N/A}]

SSH public key authentication recommended!

================================================================
VNC REMOTE DESKTOP
================================================================

VNC Port: $VNC_PORT
VNC Password: $vnc_pw

VNC connection string (IPv4):
  $ipv4:5900

VNC connection string (IPv6):
  [${ipv6:-N/A}]:5900

VNC clients: TightVNC, RealVNC, UltraVNC, Remmina (Linux)

NOTE: After establishing SSH tunnel (recommended):
  Local VNC connection: localhost:5900

================================================================
SESSION MANAGEMENT
================================================================

Session Duration: $wait_time hour(s)

To extend the session, create a file with additional hours:
  (This feature allows remote adjustment during active session)

To check if VNC is still running:
  ssh $uname@$ipv4 'pgrep -x x11vnc && echo VNC running'

To terminate VNC early:
  ssh $uname@$ipv4 'pkill -9 x11vnc'

================================================================
SECURITY NOTES
================================================================

1. Use SSH tunnel for secure VNC connection:

   SSH Tunnel (IPv4):
     ssh -L 5900:localhost:5900 $uname@$ipv4

   Then connect VNC client to: localhost:5900

2. SSH tunnel (IPv6):
     ssh -L 5900:localhost:5900 $uname@[${ipv6:-N/A}]

3. Change VNC password in lib/remote.sh before deploying!

4. Consider time-limited SSH keys for remote sessions

5. Monitor active sessions: ps aux | grep x11vnc

================================================================
TROUBLESHOOTING
================================================================

IPv6 not showing?
  - Check IPv6 connectivity: curl -6 https://ipv6.icanhazip.com
  - Or visit: https://test-ipv6.com

Can't connect via IPv4?
  - Verify network connectivity: ping -c 1 8.8.8.8
  - Check SSH is running: ssh -v $uname@$ipv4

VNC connection refused?
  - SSH tunnel established? Check port forwarding is active
  - DISPLAY=:0 set correctly? Check: echo \$DISPLAY on remote
  - Try forcing: export DISPLAY=:0 before VNC start

Port already in use?
  - Check: lsof -i :5900
  - Kill if needed: kill -9 <PID>

================================================================
EOF
}

################################################################################
# VNC SERVER MANAGEMENT
################################################################################

check_vnc_dependencies() {
    log_info "Checking VNC dependencies..."

    if ! command -v x11vnc &> /dev/null; then
        log_warn "x11vnc not found. Installing..."
        if ! sudo apt-get update && sudo apt-get install -y x11vnc; then
            log_error "Failed to install x11vnc"
            return 1
        fi
    fi

    log_info "VNC dependencies satisfied"
    return 0
}

start_ssh_server() {
    log_info "Ensuring SSH server is running..."

    if ! systemctl is-active --quiet ssh; then
        log_info "Starting SSH service..."
        if ! sudo systemctl enable --now ssh; then
            log_error "Failed to start SSH service"
            return 1
        fi
    fi

    log_info "SSH server is active"
    return 0
}

detect_xauthority() {
    for path in "/run/user/$(id -u)/gdm/Xauthority" "$HOME/.Xauthority"; do
        if [[ -f "$path" ]]; then
            echo "$path"
            return 0
        fi
    done

    echo "guess"
    return 0
}

start_vnc_server() {
    local pass_file="$1"

    # Kill any existing x11vnc processes
    pkill -9 x11vnc 2>/dev/null
    sleep 2

    local xauth_path=$(detect_xauthority)

    export DISPLAY=":0"

    local vnc_cmd="x11vnc -display :0 -forever -rfbauth $pass_file -rfbport ${VNC_PORT} -bg -o $VNC_LOG_FILE"

    [[ "$xauth_path" == "guess" ]] || vnc_cmd="$vnc_cmd -auth $xauth_path"

    eval $vnc_cmd

    sleep 3

    local vnc_pid=$(pgrep -x x11vnc)

    if [[ -n "$vnc_pid" ]]; then
        log_info "x11vnc started successfully (PID: $vnc_pid)"
        return 0
    fi

    log_error "Failed to start x11vnc server"
    return 1
}

stop_vnc_server() {
    log_info "Stopping VNC server..."
    pkill -9 x11vnc 2>/dev/null
    log_info "VNC server stopped"
}

################################################################################
# CONNECTION INFO UPLOAD (RCLONE-BASED)
################################################################################

upload_connection_info() {
    log_info "Uploading connection info to ${RCLONE_REMOTE}:/ ..."

    if [[ ! -f "$VNC_INFO_FILE" ]]; then
        log_error "Connection info file not found: $VNC_INFO_FILE"
        return 1
    fi

    # Upload via rclone to Dropbox root
    if timeout 60 rclone copy "$VNC_INFO_FILE" "${RCLONE_REMOTE}:/" \
        --progress \
        --transfers 1 \
        --checkers 1 \
        --retries 2 \
        --verbose 2>> "$RCLONE_LOG_PATH"; then

        log_info "SUCCESS: Connection info uploaded to ${RCLONE_REMOTE}:/tele1_vnc_access.txt"
        return 0
    else
        local exit_code=$?
        log_warn "FAILED: Connection info upload failed (exit code: $exit_code)"
        return 1
    fi
}

################################################################################
# NOTIFICATION INTEGRATION
################################################################################

send_vnc_notification() {
    log_info "Sending remote connection notification email..."

    if [[ ! -f "$VNC_INFO_FILE" ]]; then
        log_error "Connection info file not found: $VNC_INFO_FILE"
        return 1
    fi

    local subject="TELE1 Remote Access: SSH + VNC Connection Details"
    local body=$(cat "$VNC_INFO_FILE")

    if send_email_with_attachment "$subject" "$body" "$VNC_INFO_FILE"; then
        log_info "Notification sent successfully"
        return 0
    else
        log_warn "Failed to send notification email"
        return 1
    fi
}

################################################################################
# SESSION MANAGEMENT
################################################################################

wait_for_vnc_session() {
    local wait_hours="$1"
    local check_interval=300
    local total_seconds=$((wait_hours * 3600))
    local elapsed=0

    rm -f "$VNC_EXTEND_FLAG"

    while [[ $elapsed -lt $total_seconds ]]; do
        # Session extension
        if [[ -f "$VNC_EXTEND_FLAG" ]]; then
            local extend_hours=$(cat "$VNC_EXTEND_FLAG" 2>/dev/null | tr -d '[:space:]')

            if [[ "$extend_hours" =~ ^[0-9]+$ ]] && [[ $extend_hours -gt 0 ]]; then
                log_info "Session extended by ${extend_hours} hour(s)"
                total_seconds=$((total_seconds + extend_hours * 3600))
                rm -f "$VNC_EXTEND_FLAG"
            fi
        fi

        local vnc_pid=$(pgrep -x x11vnc)

        if [[ -z "$vnc_pid" ]]; then
            log_warn "VNC server died unexpectedly. Restarting..."
            start_vnc_server "$VNC_PASS_FILE"
        fi

        local sleep_time=$check_interval
        local remaining=$((total_seconds - elapsed))

        [[ $remaining -lt $sleep_time ]] && sleep_time=$remaining

        sleep "$sleep_time"

        elapsed=$((elapsed + sleep_time))

        if [[ $((elapsed % 3600)) -lt $check_interval ]]; then
            log_info "Session: $((elapsed/3600))/$((total_seconds/3600)) hours elapsed"
        fi
    done

    log_info "Session timeout reached"
    return 0
}

################################################################################
# MAIN VNC MODE HANDLER
################################################################################

handle_vnc_mode() {
    local wait_time="${1:-2}"

    log_info "========================================"
    log_info " ENTERING REMOTE MODE"
    log_info "========================================"
    log_info "Wait time: ${wait_time} hour(s)"

    save_state "REMOTE_MODE_STARTED" "$(date)"

    export DISPLAY=":0"

    check_vnc_dependencies || {
        log_error "VNC dependency failure"
        return 1
    }

    start_ssh_server || log_warn "SSH unavailable"

    x11vnc -storepasswd "$VNC_PASSWORD" "$VNC_PASS_FILE" 2>/dev/null

    start_vnc_server "$VNC_PASS_FILE" || {
        log_error "VNC startup failed"
        return 1
    }

    create_connection_info "$wait_time" "$VNC_PASSWORD"

    upload_connection_info

    send_vnc_notification

    wait_for_vnc_session "$wait_time"

    stop_vnc_server

    rm -f "$VNC_PASS_FILE" "$VNC_INFO_FILE" "$VNC_EXTEND_FLAG"

    save_state "REMOTE_MODE_COMPLETED" "$(date)"

    log_info "========================================"
    log_info " REMOTE MODE COMPLETE"
    log_info "========================================"

    return 0
}

################################################################################
# EXPORT FUNCTIONS
################################################################################

export -f get_ipv6_address get_ipv4_address
export -f create_connection_info
export -f check_vnc_dependencies start_ssh_server detect_xauthority
export -f start_vnc_server stop_vnc_server
export -f upload_connection_info send_vnc_notification
export -f wait_for_vnc_session handle_vnc_mode
