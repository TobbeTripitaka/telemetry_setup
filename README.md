# TELE1: native-CLI collection candidate

Version **4.0.0-alpha.1**, based on GitHub commit
`be9934be982b0f6027a2f2fa072d49a3b39eb0e5`.
This is a bench-test candidate, not a field-approved release. Do not replace a
working remote installation until the hardware acceptance checklist passes.

TELE1 copies Nanometrics Pegasus data to Dropbox on a weekly BIOS wake-up. The
computer's USB 5 V operates the Starlink power relay; turning the computer off
also turns Starlink off. Battery protection takes precedence over finishing
an upload or sending an email.

## What changed

- **Native collection:** Bash calls the bundled native `harvester`, not the
  Electron GUI. The project's JavaScript and Puppeteer helpers are removed.
  Do not remove the vendor's `node_modules` directory: the native binary resides there.
- **Integrity:** isolated daily exports, frozen Dropbox-compatible hashes,
  post-upload verification, and progress updates only after verification.
- **Recovery:** completed pending exports survive shutdown and are retried
  before accessing the recorder. Failed/incomplete scratch is never uploaded.
- **Power:** systemd powers off on collector exit, including failure; a separate
  boot timer requests emergency shutdown after four hours, even during SSH/VNC.
- **Remote access:** `auto`, `ssh`, and `vnc` post-run modes; 600-second idle
  maintenance window only for `ssh`/`vnc`, reset while sessions are detected.
- **Diagnostics:** Starlink `grpcurl` query, Dropbox logs, and a bounded email
  attempt each completed run; best-effort notification on abnormal exit.
- **Configuration:** literal allow-listed `key=value` data, never sourced shell.

## Dropbox layout

```text
<dropbox_root>/tele/<station_name>/
  config.txt
  pegasus_harvester/
    <native Harvester directories and filenames, unchanged>
  tele_logfiles/
    <run logs and diagnostics>
    harvest/
    receipts/<recorder_serial>/
  <future_extension>/
```

The script does not add a run-date folder around the native data and never
sets `-p`. It requests `-d=24` for daily waveform files. The precise native
SOH/log output names and cross-day behaviour must be confirmed on the recorder.
No PSF image, recorder erasure, remote deletion, or `rclone sync` is used.

## Collection modes

| Mode | Purpose |
|---|---|
| `incremental` | Normal weekly operation: fill unverified days and revisit recent/open days; skip unchanged remote contents. |
| `reconcile` | Re-export the retained recorder history; upload only missing or changed content. |
| `reupload` | Re-export the retained history and force transfer of every file for a new request. |
| `range` | Repair specified whole UTC days; upload missing or changed content. |

`reconcile`, `reupload`, and `range` require a `REQUEST_ID`. Reuse that ID across
weekly wakes to resume a long request; change it to initiate another request.
Already completed old days are skipped for the same request. A small overlap
and any previously open day are revisited, without repeatedly forcing identical
transfers after the request has acknowledged that day.

Example station `config.txt`:

```ini
EXECUTE=ssh
MAINTENANCE_IDLE_SECONDS=600
HARVEST_MODE=incremental
HARVEST_BUDGET_SECONDS=3600
RETAIN_LAST_BATCH=yes
```

To reconcile the whole recorder:

```ini
EXECUTE=auto
HARVEST_MODE=reconcile
REQUEST_ID=full-check-2026-09
```

To deliberately send everything again, use `HARVEST_MODE=reupload` and a new
request ID. A full-history request can span several weekly wakes; it does not
override the battery deadline.

## Local storage and versions

Completed but unverified exports remain in `pending/`. By default, the most
recent verified **daily** batch remains in `last-verified/`; older verified data
is removed locally. Set `RETAIN_LAST_BATCH=no` to disable that extra copy.
Small daily receipts, native-path ownership records, validated configuration,
and recent diagnostic logs remain. These are recovery metadata, not a second
complete seismic archive.

Deploy only a tested Git tag or exact commit, never an automatic `git pull` from
`main` on each wake. Logs identify the application version; hardware validation
must also record the vendor Harvester and rclone versions. The later installer
should use versioned release directories and an atomic `current` symlink.
State and credentials must stay outside the application checkout.

## Verification and installation status

Run the non-hardware tests:

```bash
bash tests/run.sh
shellcheck -S warning -e SC2034 tele1.sh lib/common.sh lib/config.sh \
  lib/hardware.sh lib/harvest.sh lib/upload.sh lib/notification.sh \
  lib/remote.sh scripts/*.sh tests/*.sh
```

SC2034 is excluded because the sourced modules deliberately share globals.
The tests use a synthetic Harvester and real local rclone hash/copy operations.
They never access the recorder, Dropbox, SMTP, or poweroff.

Read [the design and limitations](docs/DESIGN.md),
[the acceptance checklist](docs/VALIDATION.md), and
[the installation status](INSTALLATION.md) before proceeding.
Camera remains an unused placeholder.
