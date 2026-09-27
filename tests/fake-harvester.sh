#!/usr/bin/env bash
# Synthetic outputs for orchestration tests. NOT genuine miniSEED or hardware.
set -euo pipefail
mode=${MOCK_HARVEST_MODE:-ok}
if [[ ${1:-} == volume-info ]]; then
    for arg in "$@"; do [[ $arg != -id=* ]] || id=${arg#*=}; done
    if [[ $id == 3 ]]; then printf 'volume id=3 not found\n'; exit 1; fi
    if [[ $mode == bad-volume ]]; then printf '<<<ERROR device read failed\n'; exit 0; fi
    printf 'Volume %s info:\n' "$id"
    [[ $id != 4 ]] || exit 0
    lower=1735689600000000000 upper=1735776000000000000
    [[ $id != 2 ]] || lower=1735603200000000000
    [[ $id != 5 ]] || upper=1735948800000000000
    printf '    lower time = %s (synthetic)\n    upper time = %s (synthetic)\n' "$lower" "$upper"
    exit 0
fi
[[ ${1:-} == harvest ]] || exit 2
[[ -z ${MOCK_ARGUMENT_LOG:-} ]] || printf '%s\n' "$@" >"$MOCK_ARGUMENT_LOG"
for arg in "$@"; do
    case "$arg" in
        -o=*) out=${arg#*=} ;;
        -l=*) lower=${arg#*=} ;;
    esac
done
if [[ $mode == hang ]]; then sleep 30; exit 0; fi
day=$(date -u -d "@$((lower / 1000000000))" +%F)
mkdir -p "$out/2025/XX/TEST/BHZ.D"
printf 'synthetic waveform %s\n' "$day" >"$out/2025/XX/TEST/BHZ.D/$day.mseed"
if [[ $mode == fail ]]; then printf '<<<ERROR synthetic read failure\n'; exit 1; fi
for op in harvest-logs harvest-soh harvest-data; do
    printf "Operation '%s' finished with status COMPLETED(0)\n" "$op"
done
printf 'volume id=3 not found\nClock Status Volume not found - harvesting skipped\n'
printf 'Failed to harvest ClockStatus data!\n'
