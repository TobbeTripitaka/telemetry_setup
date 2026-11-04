# TELE installation and operation guide

This guide is for the project lead. The technician uses [TECHNICIAN.md](TECHNICIAN.md).
Every command block says where it runs.

## Contents

- [Prepare a station](#prepare-a-station)
- [What the installer does](#what-the-installer-does)
- [Settings in Dropbox](#settings-in-dropbox)
- [Field mode and keeping a computer on](#field-mode-and-keeping-a-computer-on)
- [Checking a station](#checking-a-station)
- [BIOS wake-up and the USB relay](#bios-wake-up-and-the-usb-relay)
- [Troubleshooting](#troubleshooting)

## Prepare a station

One folder per computer, made on your own computer (Mac or Linux), never on the
station. It contains the committed code, the filled setup file (passwords), the
Nanometrics `.deb` and a checksum list.

1. Copy `credentials.example.txt` to `<computer>.conf` and fill in every
   `REPLACE_WITH` value. The file explains Dropbox (token), Gmail (app password) and
   Tailscale (auth key). `station=` is a short station name, for example `cad4`; it
   selects the Dropbox folder. The computer is never renamed and keeps its login
   account. `LOCATION` is a free label such as `Mt Strathcona CAD4`.
2. Build the folder:

```bash
# Run on: YOUR computer, inside the repository checkout.
scripts/make-bundle.sh --setup tele2.conf --deb pegasus-harvester_2.3.27_amd64.deb --encrypt
```

3. Send the zip (and the passphrase by another channel) to the technician.

## What the installer does

`sudo bash INSTALL.sh` runs unattended and can be repeated. In order:

1. Checks the setup file and the internet connection.
2. Installs packages, the Nanometrics Harvester (checksum verified), rclone, mosh
   and Tailscale; turns automatic updates off.
3. Sets the password of the technician account, automatic login without a password,
   UTC, backup DNS servers, and creates `/home/<account>/data/Nanometrics`.
4. Installs TELE to `/opt/tele/current` with its settings in `/etc/tele`, the
   systemd service, the emergency timer and the `tele-maintenance` command.
5. Tests the Dropbox upload and the email, writes `INSTALL-REPORT.txt` and restarts
   the computer one minute later. It does not switch on field mode.

`sudo bash INSTALL.sh --enable-field` arms field mode for the next boot.

## Settings in Dropbox

The station reads `tele/<computer>/config.txt` at every wake. Useful keys:

| Key | Meaning |
|---|---|
| `EXECUTE` | `ssh` waits for a maintenance login after the run; `auto` powers off at once |
| `MAINTENANCE_IDLE_SECONDS` | how long that wait lasts without a login (default 600) |
| `RUN_LIMIT_SECONDS` | hard limit of one run since boot (default 7200) |
| `HARVEST_BUDGET_SECONDS` | time for exporting data (default 3600) |
| `NETWORK_WAIT_SECONDS` | how long to wait for Starlink and Dropbox (default 1200) |
| `START_DATE` | first UTC day to collect; older recorder history is skipped |
| `LOCAL_DATA` | `keep` the local copy (oldest verified days are removed only when disk space is low) or `clean` it after upload |
| `HARVEST_MODE` | `incremental` (default), `reconcile` (resumable full scan, needs `REQUEST_ID`), `reupload` (new `REQUEST_ID`), `range` (`FROM_DATE`, `TO_DATE`) |

## Field mode and keeping a computer on

Field mode means: after every run systemd powers the computer off, and an
independent timer does the same four hours after boot (`EMERGENCY_SECONDS`) even if
the collector hangs. Both act only while `/etc/tele/FIELD_ENABLED` exists.

```bash
# Run on: the station computer.
sudo tele-maintenance on       # stay on, also during a run; nothing powers it off
sudo tele-maintenance status
sudo tele-maintenance off      # arm field mode for the next boot, then: sudo poweroff
```

`systemctl disable` alone does not stop a service that is already armed or running;
use `tele-maintenance on`. The four-hour limit is a shutdown request, not a physical
power cut: a frozen kernel or firmware is not covered.

## Checking a station

```bash
# Run on: the station computer.
sudo /opt/tele/current/tele.sh --status    # folders, days done, pending, mode
sudo /opt/tele/current/tele.sh --check     # settings and connections, no harvest
sudo /opt/tele/current/tele.sh --once      # one real run, does not power off
```

Per-day line in the run log: `Verified in Dropbox: 2024-03-01 (data 3, logs 1, soh 28, other 0;
40 MiB, 30 s)`. `soh 0` is normal for days before the recorder's SOH volume starts.
Logs are in `/var/log/tele/<computer>/` and in Dropbox `tele_logfiles/`; one receipt
per day (`json`, `dropbox.sum`, `harvest.log`) is in `tele_logfiles/harvest/`.

## BIOS wake-up and the USB relay

Starlink is switched by a solid-state relay that follows the computer's USB 5 V; there
is no software relay command, so what the USB port does after shutdown matters.

- **Relay port:** on the Shuttle SPCEL03 the USB 2 port kept supplying power after
  shutdown; a USB 3 port released the relay. Test the actual port on every computer:
  run, shut down fully (not suspend, DC supply connected), wait a minute and confirm
  that the relay released and Starlink lost power. Label the working port.
- **BIOS:** press F2 at start, enable the RTC alarm wake-up (weekly schedule) and
  check the ignition-key setting if a switch is used. Record the firmware version.
  Check whether the RTC alarm is UTC. Restart-after-power-return is a separate
  setting; test both if the station depends on both.
- **Wake test:** set a short interval, shut down normally and watch the next power-on.
  Do not leave a battery-powered unit unattended before the relay release and the
  next scheduled wake have both been seen.
- **Not yet proven on hardware in this version:** BIOS wake in UTC and the physical
  relay cutoff.

## Troubleshooting

- **Typing freezes over SSH on Starlink:** use `mosh <account>@<tailscale address>`.
  Log in as the technician account that ran the installer.
- **Uploads are slow or partial:** read the run log. Complete days stay on the
  computer and resume at the next run; they are never marked done before Dropbox
  verification. Check the Starlink dish view and `docs/STARLINK.md`.
- **No state-of-health for old days:** the recorder's SOH volume starts later than its
  waveform volume (for the test recorder, 5 February 2024).
- **The computer powered off when you wanted it on:** see
  [Field mode and keeping a computer on](#field-mode-and-keeping-a-computer-on); log
  in within four hours of boot and run `sudo tele-maintenance on`.
