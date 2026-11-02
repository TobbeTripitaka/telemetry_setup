#!/usr/bin/env bash
# Keep this computer on for maintenance (upgrades, checks), or arm field mode again.
#
#   sudo tele-maintenance on      stay on: nothing powers the computer off by itself
#   sudo tele-maintenance off     arm field mode again for the NEXT boot
#   sudo tele-maintenance status  show what is armed
#
# "on" works at any moment, also in the middle of a field run: the power-off steps
# of the field service and of the emergency timer only act while the marker file
# /etc/tele/FIELD_ENABLED exists, and "on" removes it.
set -Eeuo pipefail
ETC=${TELE_ETC_DIR:-/etc/tele}
MARKER=$ETC/FIELD_ENABLED

[[ $EUID == 0 || -n ${TELE_ETC_DIR:-} ]] || { echo "Use sudo." >&2; exit 1; }

armed() { [[ -e $MARKER ]]; }

case ${1:-status} in
    on|hold)
        rm -f -- "$MARKER"
        systemctl disable tele.service tele-power-guard.timer >/dev/null 2>&1 || true
        echo "Maintenance mode: this computer will NOT power off by itself."
        echo "A field run that is in progress ends normally and leaves the computer on."
        echo "When you are done: sudo tele-maintenance off, then shut down (sudo poweroff)."
        ;;
    off|arm)
        [[ -f $ETC/node.conf && -f $ETC/config.txt ]] || { echo "TELE is not installed here." >&2; exit 1; }
        install -m 600 /dev/null "$MARKER"
        if ! systemctl enable tele-power-guard.timer tele.service >/dev/null 2>&1; then
            rm -f -- "$MARKER"
            echo "Could not enable the field service; field mode stays off." >&2
            exit 1
        fi
        echo "Field mode is armed for the NEXT boot: after each run the computer powers off."
        echo "The computer stays on now, because no timer is running in this boot."
        echo "Shut it down yourself when you are finished: sudo poweroff"
        ;;
    status)
        if armed; then echo "Field mode: ARMED (the computer powers off after each run and at the emergency limit)"
        else echo "Field mode: off (maintenance mode; the computer stays on)"; fi
        systemctl is-enabled tele.service tele-power-guard.timer 2>/dev/null | paste -sd' ' | sed 's/^/Enabled at boot: /' || true
        systemctl list-timers tele-power-guard.timer --no-pager 2>/dev/null | head -n 3 || true
        ;;
    *)
        echo "Usage: sudo tele-maintenance on | off | status" >&2
        exit 64
        ;;
esac
