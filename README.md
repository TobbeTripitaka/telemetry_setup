# TELE: remote seismic data collection

TELE collects data from seismic stations where power and internet access are
limited. It runs on an Ubuntu edge computer connected to a Nanometrics Pegasus
recorder and uses Starlink to upload data to Dropbox.

The BIOS wakes the computer, it harvests the recorder over USB, uploads the data to
Dropbox, sends a status email and switches off again. The recorder keeps recording
while the computer is off, so neither the computer nor Starlink runs all the time.

In order of importance:

1. **The computer always switches off** after a bounded time, even when the internet
   is poor, so the battery is not drained.
2. **All data reaches Dropbox sooner or later.** A day counts as done only when its
   files are verified in Dropbox; anything unfinished resumes at the next wake.
3. **It runs unattended and is maintainable:** one installer, one status email per
   run, and a settings file in Dropbox that the station reads at every wake.

The system has been running in Australia, and the Antarctic station has been
transmitting data since February 2026. This software version is still being tested
on hardware, so contact the author before using it at an unattended field site.

<img src="img/GRIT%20_Final.png" width="120" alt="GRIT project logo">

## What you get

The same seismic layout locally and in Dropbox. Paths are the ones written by the
Pegasus Harvester application, so network and station codes come from the recorder
and redeployments need no setting:

```text
Dropbox: <dropbox_root>/tele/<computer>/            Local: /home/<account>/data/Nanometrics/
  config.txt                  (your instructions to this computer)
  Nanometrics/
    2024/Z9/DMT5/HHE.D/Z9.DMT5..HHE.D.2024.061      waveforms, one file per channel and UTC day
    logs/2024/Z9/DMT5/LOG.D/Z9.DMT5..LOG.D.2024.061 recorder log, one file per day
    soh/2024/Z9/DMT5/VCO.D/Z9.DMT5..VCO.D.2024.061  state of health, one folder per type
    Z9.DMT5_20231229T033647Z.json                    deployment record (see below)
  tele_logfiles/              run logs; harvest/ holds one receipt per day
```

The deployment record is what the recorder stored at deployment (network, station,
channels, sensors, position). The Harvester application turns it into a StationXML
file of the same name; the command line cannot, so the `.json` is kept instead and
can be converted later.

## How a run works

1. Wait (bounded) for the network, read the settings from Dropbox, check Starlink.
2. Find the recorder, upload any complete day still waiting from an earlier run.
3. Save new deployment records.
4. For every UTC day not yet verified (oldest first): export data and logs with the
   native Harvester, add that day's state-of-health files, upload, verify the hashes
   in Dropbox, and only then record the day as done.
5. Upload the run log, send the status email, optionally wait for a maintenance
   login, then power off through systemd.

Facts about the recorder that shaped this (measured, see
[docs/DESIGN.md](docs/DESIGN.md)): state-of-health cannot be selected by time, so it
is read once per run and split by day; files are written without extension
(`-ext=0`) as the Harvester application does; a day window can also write a stub of
the neighbouring day, which is dropped; the same day exported twice has identical
samples but not always identical bytes.

## Quick start

| Who | Does what | Where |
|---|---|---|
| Project lead | Makes one folder per computer with the settings, passwords and the Harvester package | [Prepare a station](INSTALLATION.md#prepare-a-station) |
| Technician | Installs, tests one run, keeps the computer on for upgrades | [TECHNICIAN.md](TECHNICIAN.md) |
| Project lead | Sets the BIOS wake-up, tests the USB relay, switches field mode on | [BIOS wake-up and the USB relay](INSTALLATION.md#bios-wake-up-and-the-usb-relay) |

To keep a computer on for upgrades: `sudo tele-maintenance on`; to arm it again:
`sudo tele-maintenance off`.

## Repository

- `INSTALL.sh`: the one installer (packages, Harvester, rclone, Tailscale, services).
- `tele.sh` and `lib/`: the collector. `lib/harvest.sh` and `lib/upload.sh` hold the
  harvest and verified upload; `lib/deployments.sh` the deployment records.
- `systemd/`: the service and the independent emergency timer. `scripts/`: bundle
  maker and `tele-maintenance`.
- `tests/`: `bash tests/run.sh` and `bash tests/installer.sh` run the offline suites
  (synthetic Harvester, local rclone); `docs/DESIGN.md` lists what only hardware can
  prove.
- [CHANGELOG.md](CHANGELOG.md), [SHIPPING.md](SHIPPING.md) (preparing Ubuntu
  computers), [docs/STARLINK.md](docs/STARLINK.md).

If you build a station or find something that can be improved, please get in touch
or open an issue. Software: `4.2.0`. Record the Git revision as well.
