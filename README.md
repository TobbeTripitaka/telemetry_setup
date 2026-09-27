# TELE1: remote seismic data collection

I built TELE1 to collect data from seismic stations where power and internet
access are limited. It runs on an Ubuntu computer connected to a Nanometrics
Pegasus recorder and uses Starlink to upload data to Dropbox.

The idea is simple: wake the computer, collect and upload the data, send a status
email, then switch off again. The Pegasus continues recording while the computer
is off, so there is no need to leave the computer and Starlink running all week.

The system has been running in Australia, and the Antarctic station has been
transmitting data since February 2026. I am still testing this software update,
so please contact me before using it at an unattended field site.

<img src="img/GRIT%20_Final.png" width="120" alt="GRIT project logo">

## Hardware and setup

My setup uses a Shuttle SPCEL03, a Starlink Mini and a USB-controlled relay.
The BIOS wakes the computer once a week. USB 5 V operates the relay, so Starlink
powers up with the computer and switches off when the computer shuts down.

<img src="img/photo_4.JPG" width="650" alt="TELE1 test setup with the computer, Pegasus recorder and Starlink antenna in the enclosure">

Test setup. Photo: Tobias Stål.

The full [installation and field deployment guide](INSTALLATION.md) includes
the hardware choices, supplier links, photographs, Ubuntu setup, credentials,
remote access and testing instructions. Start there if you are building a station.

## How it works

TELE1 uses Bash to call the native Pegasus Harvester and rclone for Dropbox
transfers. It exports waveform miniSEED, SOH, legacy SOH and logs without creating
a large PSF image.

Each run:

1. Loads the station settings and checks its configuration.
2. Collects Starlink diagnostics and retries complete pending uploads.
3. Identifies the recorder using its whole-disk by-id path and serial.
4. Exports the required UTC days into separate local working directories.
5. Uploads files and verifies their Dropbox-compatible content hashes.
6. Records progress only after verification.
7. Uploads logs, attempts a status email and opens a maintenance window if requested.
8. Powers down.

An unfinished export is not uploaded as if it were complete. Completed exports
that have not been verified in Dropbox stay on the computer for another attempt,
and that retry does not depend on the recorder still being connected.

By default, the last verified daily batch is also kept locally. Older verified
payloads are removed, while the small progress records and recent logs remain.

## Dropbox layout

Each station has its own directory and configuration:

```text
<dropbox_root>/tele/<station_name>/
  config.txt
  pegasus_harvester/
    <native Harvester directories and filenames>
  tele_logfiles/
    <run logs and diagnostics>
    harvest/
    receipts/<recorder_serial>/
  <future_extension>/
```

The Harvester's file paths are left unchanged. The script requests daily waveform
files with `-d=24` and does not replace the native path pattern with `-p`.

There is no recorder-erasure command or Dropbox deletion in the collection
workflow. Native SOH/log naming and files crossing day boundaries still need
checking with the actual recorder before deployment.

## Collection modes

Most runs should use `incremental`. The other modes are there for checking or
repairing the archive without changing the normal folder structure.

| Mode | What it does |
|---|---|
| `incremental` | Collects unverified days and revisits recent/open days, skipping identical uploaded contents. |
| `reconcile` | Re-exports the recorder's retained history and uploads only missing or changed files. |
| `reupload` | Re-exports the retained history and deliberately sends every file again for a new request. |
| `range` | Repairs a specified range of whole UTC days, uploading missing or changed contents. |

`reconcile`, `reupload` and `range` need a `REQUEST_ID`. Keep the same ID while
a large request is being completed across several wakes, and use a new ID when
you want to start another request.

## Station configuration

The station reads its own `config.txt` from Dropbox. Settings are parsed as
literal values, not executed as shell commands.

For normal weekly collection:

```ini
EXECUTE=auto
HARVEST_MODE=incremental
HARVEST_BUDGET_SECONDS=3600
RETAIN_LAST_BATCH=yes
```

To leave time for SSH access after collection:

```ini
EXECUTE=ssh
HARVEST_MODE=incremental
MAINTENANCE_IDLE_SECONDS=600
RETAIN_LAST_BATCH=yes
```

To check the full recorder archive without unnecessarily sending matching
files again:

```ini
EXECUTE=auto
HARVEST_MODE=reconcile
REQUEST_ID=full-check-2026-09
```

Use `EXECUTE=vnc` for the private virtual desktop, or `HARVEST_MODE=reupload`
with a new request ID to force a full retransmission. The installation guide
lists all settings, valid values and date-range examples.

Passwords, Dropbox tokens, device paths and executable paths do not belong in
the Dropbox configuration. Private credentials and local station identity are
kept separately on the computer.

## Power and remote access

Battery protection is important here. A failed upload or stuck process must not
leave the computer and Starlink running indefinitely.

- **Harvesting:** the default budget is one hour of cumulative native export
  time, with a bounded termination grace period.
- **Normal shutdown:** the systemd service requests poweroff when the collector
  exits, including after a failure.
- **Emergency shutdown:** a separate timer requests poweroff four hours after
  boot, including during a remote session.
- **Maintenance:** `ssh` and `vnc` modes wait for 10 idle minutes by default after
  the work is finished. Detected connections reset that countdown.
- **Auto mode:** finishes the work and reporting without a maintenance wait.

I use Tailscale for remote access and a private VNC desktop when a graphical
session is useful. VNC is reached through an SSH tunnel rather than a public port.

There is no independent hardware power-cut timer in this setup. The software
timer protects against a stalled collection script, but it cannot guarantee
shutdown if Ubuntu or the firmware itself freezes.

## Testing and deployment

The automated suite has 43 tests covering configuration, acquisition failures,
hash verification, retries, retention and maintenance timing. It uses a synthetic
Harvester and real local rclone file operations, not a real recorder or live Dropbox.

On an Ubuntu development or bench machine with the dependencies installed:

```bash
bash tests/run.sh
shellcheck -S warning -e SC2034 tele1.sh lib/common.sh lib/config.sh \
  lib/hardware.sh lib/harvest.sh lib/upload.sh lib/notification.sh \
  lib/remote.sh scripts/*.sh tests/*.sh
```

SC2034 is excluded because the sourced Bash modules share configuration variables.
These tests do not access the recorder, send email or shut down the computer.

Before field use, check real miniSEED completeness, Dropbox interruption recovery,
SSH/VNC sessions, BIOS wake-up and the physical USB-relay shutdown. Starting the
field service is different from running the tests: it can power the computer off.

Use a tested release or exact Git commit for each station. Do not automatically
pull `main` on every wake, and keep credentials, pending data and progress records
outside the application checkout.

## Documentation and next steps

- **[Installation guide](INSTALLATION.md):** hardware, photos, suppliers and the
  complete setup procedure.
- **[Design notes](docs/DESIGN.md):** collection, verification and recovery behaviour.
- **[Test checklist](docs/VALIDATION.md):** checks to complete before deployment.

Once the setup is properly tested, I want to add an installer that downloads the
software from GitHub and handles the Ubuntu configuration using one private
station-settings file. Camera and other sensor integrations can be added later;
the camera module is currently just a placeholder.

If you build a station or find something that can be improved, please get in
touch or open an issue in this repository. I would like to keep the setup
practical, easy to understand and reliable enough to leave in the field.

Software: `4.0.0-alpha.1`. Updated: 27 September 2026.
