#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/starlink.sh"
case "${1:-status}" in
    status) starlink_rpc '{"get_status":{}}' ;;
    config) starlink_rpc '{"dish_get_config":{}}' ;;
    snow-melt) starlink_check_snow ;;
    snow-melt-off)
        [[ ${2:-} == --confirm ]] || { printf 'Changes the dish setting. Supply snow-melt-off --confirm to authorize this attempt.\n' >&2; exit 64; }
        starlink_set_snow_off ;;
    *) printf 'Usage: STARLINK.sh status|config|snow-melt|snow-melt-off --confirm\n' >&2; exit 64 ;;
esac
