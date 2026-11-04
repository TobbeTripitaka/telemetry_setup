#!/usr/bin/env bash
# Synthetic outputs for orchestration tests. NOT genuine miniSEED or hardware.
set -euo pipefail
mode=${MOCK_HARVEST_MODE:-ok}
if [[ ${1:-} == volume-info ]]; then
    for arg in "$@"; do [[ $arg != -id=* ]] || id=${arg#*=}; done
    if [[ $id == 3 ]]; then printf 'volume id=3 not found\n'; exit 255; fi
    if [[ $mode == bad-volume ]]; then printf '<<<ERROR device read failed\n'; exit "${MOCK_SUCCESS_EXIT:-0}"; fi
    printf 'Volume %s info:\n' "$id"
    [[ $id != 4 ]] || exit "${MOCK_SUCCESS_EXIT:-0}"
    lower=1735689600000000000 upper=1735776000000000000
    [[ $id != 2 ]] || lower=1735603200000000000
    [[ $id != 5 ]] || upper=1735948800000000000
    printf '    lower time = %s (synthetic)\n    upper time = %s (synthetic)\n' "$lower" "$upper"
    exit "${MOCK_SUCCESS_EXIT:-0}"
fi
if [[ ${1:-} == read-volume ]]; then
    # Operation log with one deployment message: opaque_data is base64 of gzip of JSON.
    json='{"station":{"networkCode":"XX","stationCode":"TEST"},"deployment":{"name":"synthetic"}}'
    [[ -z ${MOCK_BAD_OPAQUE:-} ]] || json='not json'
    data=$(printf '%s' "$json" | gzip -c | base64 -w0)
    printf 'Message: {\n  "message": {\n        "timestamp": 1735700000496093750,\n        "opaque_size": %s,\n        "opaque_data": "%s",\n        "x": 1\n  }\n}\n' "${#data}" "$data"
    [[ $mode != bad-volume ]] || printf '<<<ERROR device read failed\n'
    exit "${MOCK_SUCCESS_EXIT:-0}"
fi
[[ ${1:-} == harvest ]] || exit 2
[[ -z ${MOCK_ARGUMENT_LOG:-} ]] || printf '%s\n' "$@" >"$MOCK_ARGUMENT_LOG"
soh=1 data=1
for arg in "$@"; do
    case "$arg" in
        -o=*) out=${arg#*=} ;;
        -l=*) lower=${arg#*=} ;;
        -harvestSoh=*) soh=${arg#*=} ;;
        -harvestData=*) data=${arg#*=} ;;
    esac
done
if [[ $mode == hang ]]; then sleep 30; exit 0; fi
mkdir -p "$out"
if [[ $mode != fail && $soh == 1 && $data == 0 ]]; then
    # State-of-health export: no time window, every day of the recorder.
    for d in 001 002; do
        mkdir -p "$out/soh/2025/XX/TEST/VCO.D"
        printf 'synthetic soh %s\n' "$d" >"$out/soh/2025/XX/TEST/VCO.D/XX.TEST..VCO.D.2025.$d"
    done
    printf "Operation 'harvest-soh' finished with status COMPLETED(0)\n"
    printf 'volume id=3 not found\nClock Status Volume not found - harvesting skipped\nFailed to harvest ClockStatus data!\n'
    exit "${MOCK_SUCCESS_EXIT:-0}"
fi
secs=$((lower / 1000000000))
day=$(date -u -d "@$secs" +%F) year=$(date -u -d "@$secs" +%Y) jday=$(date -u -d "@$secs" +%j)
if [[ -z ${MOCK_NO_WAVEFORM:-} ]]; then
    mkdir -p "$out/$year/XX/TEST/BHZ.D"
    printf 'synthetic waveform %s\n' "$day" >"$out/$year/XX/TEST/BHZ.D/XX.TEST..BHZ.D.$year.$jday"
fi
if [[ -n ${MOCK_LOG_CONTENT:-} ]]; then
    mkdir -p "$out/logs/$year/XX/TEST/LOG.D"
    printf '%s\n' "$MOCK_LOG_CONTENT" >"$out/logs/$year/XX/TEST/LOG.D/XX.TEST..LOG.D.$year.$jday"
fi
if [[ -n ${MOCK_PREVIOUS_DAY_STUB:-} ]]; then
    # Like the real tool: a short log stub for the day before the window.
    prev=$(date -u -d "@$((secs - 86400))" +%j)
    mkdir -p "$out/logs/$year/XX/TEST/LOG.D"
    printf 'stub\n' >"$out/logs/$year/XX/TEST/LOG.D/XX.TEST..LOG.D.$year.$prev"
fi
if [[ $mode == fail ]]; then printf '<<<ERROR synthetic read failure\n'; exit 255; fi
for op in harvest-logs harvest-data; do
    printf "Operation '%s' finished with status COMPLETED(0)\n" "$op"
done
printf 'volume id=3 not found\nClock Status Volume not found - harvesting skipped\n'
printf 'Failed to harvest ClockStatus data!\n'
exit "${MOCK_SUCCESS_EXIT:-0}"
