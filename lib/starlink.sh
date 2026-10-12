#!/usr/bin/env bash
# Local gRPC only. No Starlink account password, cloud-login scraping or bypass.
starlink_rpc() {
    local request=$1
    timeout --signal=TERM --kill-after=5 25 grpcurl -plaintext -emit-defaults -max-time 20 \
        -d "$request" "${STARLINK_ADDRESS:-192.168.100.1:9200}" SpaceX.API.Device.Device/Handle
}

starlink_snow_mode() {
    # Missing/unrecognized field is UNKNOWN, never proof that heating is off.
    jq -er '
      .dishGetConfig.dishConfig.snowMeltMode //
      .dish_get_config.dish_config.snow_melt_mode //
      .dishSetConfig.updatedDishConfig.snowMeltMode //
      .dish_set_config.updated_dish_config.snow_melt_mode |
      if . == 2 or . == "ALWAYS_OFF" then "ALWAYS_OFF"
      elif . == 1 or . == "ALWAYS_ON" then "ALWAYS_ON"
      elif . == 0 or . == "AUTO" then "AUTO"
      else error("Snow-melt mode absent or unknown") end'
}

starlink_check_snow() {
    local response mode
    response=$(starlink_rpc '{"dish_get_config":{}}') || return 1
    mode=$(starlink_snow_mode <<<"$response") || return 1
    printf '%s\n' "$mode"
}

starlink_set_snow_off() {
    local mode response
    mode=$(starlink_check_snow) || { die "Cannot read snow-melt configuration"; return 1; }
    [[ $mode != ALWAYS_OFF ]] || { log "Snow melt already Off (readback verified)"; return 0; }
    # Existence of this RPC does not imply the firmware permits local writes.
    response=$(starlink_rpc '{"dish_set_config":{"dish_config":{"snow_melt_mode":"ALWAYS_OFF","apply_snow_melt_mode":true}}}') ||
        { die "Local write refused/unavailable. Use the authenticated Starlink app; no bypass attempted."; return 1; }
    jq -e '(.dishSetConfig.error // .dish_set_config.error // "") == ""' <<<"$response" >/dev/null || return 1
    mode=$(starlink_check_snow) || return 1
    [[ $mode == ALWAYS_OFF ]] || { die "Write did not produce Off on readback"; return 1; }
    log "Snow melt reads Off now. Recheck after a power cycle and firmware updates."
}
