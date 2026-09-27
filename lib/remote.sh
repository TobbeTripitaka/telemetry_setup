#!/usr/bin/env bash
# Conservative session detection: a connection counts as busy even if idle.
# The boot timer is the backstop for stale sessions/transport connections.
remote_session_active() {
    local processes connections
    processes=$(ps -eo args=) || return 0  # Unknown means preserve access.
    if grep -Eq '(^|/)(sshd|sshd-session): .*@|(^|/)tailscaled be-child ssh' <<<"$processes"; then
        return 0
    fi
    # Also protects tunnels without a shell and established VNC connections.
    connections=$(ss -Htn state established "( sport = :22 or sport = :$VNC_PORT )") || return 0
    [[ -n $connections ]]
}

maintenance_window() {
    [[ $EXECUTE == ssh || $EXECUTE == vnc ]] || return 0
    local vnc_started=no last_idle now
    if [[ $EXECUTE == vnc ]]; then
        # Separately provisioned desktop service; never install packages at runtime.
        if timeout -k 5 30 systemctl start "$VNC_SERVICE"; then
            vnc_started=yes
        else
            log "VNC service unavailable; preserving the SSH maintenance window"
        fi
    fi
    log "Maintenance window active: mode=$EXECUTE idle=${MAINTENANCE_IDLE_SECONDS}s"
    last_idle=$(uptime_seconds)
    while :; do
        now=$(uptime_seconds)
        if remote_session_active; then
            last_idle=$now
        elif (( now - last_idle >= MAINTENANCE_IDLE_SECONDS )); then
            break
        fi
        sleep 2
    done
    if [[ $vnc_started == yes ]]; then
        timeout -k 5 30 systemctl stop "$VNC_SERVICE" || return 1
    fi
    log "Maintenance window closed"
}
