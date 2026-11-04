# Changelog

## 4.2.0 (November 2026)

Harvest, measured against the Pegasus Harvester application (see docs/DESIGN.md)
- Files are written without extension (`-ext=0`), exactly as the application does.
- State-of-health is now collected. The native time window silently returned no SOH
  files; it is exported once per run without bounds and split by day. The per-day log
  line counts data, logs and soh files.
- Files of a neighbouring day (a log stub that a day window also writes) are dropped,
  so the conflict, owner and second-version bookkeeping is gone.
- Deployment records: each deployment message in the recorder's operation log is
  saved as `NN.SSSS_<UTC>Z.json` in the root of the Nanometrics tree. The command
  line cannot write the StationXML.

Layout
- One seismic tree, same locally (`/home/<account>/data/Nanometrics`, created by
  the installer) and in Dropbox (`tele/<computer>/Nanometrics`): year, network,
  station, channel, plus `logs/` and `soh/`. No per-recorder folder.
- Receipts and run logs are in `tele/<computer>/tele_logfiles/` (`harvest/` for the
  per-day receipts).

Installer
- The computer is never renamed and keeps its login account. The rename step,
  `COMPUTER_NAME`, `RENAME_FROM`, account creation and the Desktop copy are removed
  (the old keys are ignored if present). `station=` is only the key for the Dropbox
  folder and local state, independent of the computer name. `LOCATION` is the free
  label, for example "Mt Strathcona CAD4".
- The internet check accepts any answer from github.com, archive.ubuntu.com or
  Dropbox and shows curl's error if all fail.

Power and documentation
- `sudo tele-maintenance on|off|status` keeps the computer on for upgrades at any
  moment, also in the middle of a run. Poweroff by `tele.service`,
  `tele-poweroff.service` and the emergency timer happens only while
  `/etc/tele/FIELD_ENABLED` exists; `systemctl disable` alone never stopped an armed
  run.
- New one-page TECHNICIAN.md (also in the bundle as README-TECHNICIAN.txt). README,
  INSTALLATION and docs/DESIGN rewritten and shortened; the manual-procedure chapters
  of the old guide are replaced by what INSTALL.sh does.

## 4.1.1 (November 2026)
- `tele.sh --status`: a read-only overview of the data folders, days waiting, uploaded
  and kept, the latest log and the Dropbox path; the layout is documented.
- The log line for each uploaded day shows files, MiB and seconds, so a slow link can
  be told from a big day.
- Four parallel Dropbox transfers and checks instead of two: on a link with high
  latency the time per day drops roughly in proportion.
- A transfer that fails because the link drops out now waits for Dropbox to return
  (up to four minutes, three attempts) and resumes with the files still missing,
  instead of ending the run. A dead link still ends the run at the usual limits.
- The installer adds backup DNS servers (1.1.1.1, 9.9.9.9) for links whose own
  resolver drops out (`DNS_BACKUP=no` to skip).
- The installer adds `mosh` for logins over a shaky link.

## 4.1.0 (November 2026)

Installer and bundle
- One zipped folder per unit; `sudo bash INSTALL.sh` does everything. It sets the
  computer name, account, password and automatic login (no password at login),
  checks the internet first, retries packages and downloads, and runs as long as it
  needs to.
- Optional `LOCATION` label, shown in every status email and in the report.
- Rename step (`RENAME_FROM`) for a unit that already holds data: local state and
  the Dropbox folder move to the new name, nothing is uploaded twice.
- Closing report (`INSTALL-REPORT.txt`, also in Dropbox), a setup email with the
  unit's name, location, password and Tailscale address, a restart one minute after
  success, and a copy of the bundle on the new account's Desktop.
- Recorder is found automatically; replacing it starts a clean per-serial folder.
- `apt autoremove` after the one-time Ubuntu upgrade; automatic updates off.

Field runs
- `RUN_LIMIT_SECONDS`: the whole run is bounded, so a patchy connection cannot
  drain the battery (the emergency timer remains the last resort).
- `START_DATE`: do not upload recorder history older than a chosen day.
- Fewer Dropbox round trips per day; days with nothing new need none.
- A log file re-exported with different content is kept as `<name>.conflict-<day>`;
  a repeat of the same fragment is not uploaded again.
- A damaged pending batch is set aside and re-exported instead of blocking.
- Email: three tries with the reason in the log (one try when Dropbox was already
  unreachable).
- Nanometrics exit status 1 is a normal result; 255 is a failure.

Repository
- Old field logs and the empty camera stub were removed; the changelog was added.
