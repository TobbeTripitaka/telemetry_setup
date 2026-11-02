# Changelog

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
