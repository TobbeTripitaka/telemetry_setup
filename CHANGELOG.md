# Changelog

## 4.1.1 (November 2026)
- `sudo tele-maintenance on|off|status` keeps the computer on for upgrades at any
  moment, also in the middle of a run. The poweroff steps of `tele.service`,
  `tele-poweroff.service` and the emergency timer now act only while
  `/etc/tele/FIELD_ENABLED` exists; `systemctl disable` alone never stopped an
  armed run.
- The telemetry logs of a recorder (receipts, harvest log, conflict lists) are now in
  `pegasus_harvester/<serial>/tele_logfiles/`, next to its data; one
  `instrument/<serial>_<UTC>_digitizer-info.txt` is saved per run. Run logs of the
  computer stay in `tele/<station>/tele_logfiles/`.
- The per-day log line counts data, logs and soh files, so a missing SOH export is
  visible.
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
