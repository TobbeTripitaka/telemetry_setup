# Design notes and what only hardware can prove

## Operating contract

- **Power:** weekly BIOS wake-up; USB 5 V energizes the Starlink relay; no separate
  power controller. Normal completion, failure and the emergency timer all end in a
  systemd poweroff, but only while `/etc/tele/FIELD_ENABLED` exists
  (`tele-maintenance on` removes it).
- **Time:** a run is limited by `RUN_LIMIT_SECONDS` (default 2 h); the emergency timer
  requests poweroff 4 h after boot. Harvest, network wait and maintenance window have
  their own budgets inside the run limit.
- **Truth about progress:** a day is recorded as done only after its files are
  verified by Dropbox content hash. Complete exports waiting for upload stay in
  `/var/lib/tele/<computer>/sources/<serial>/pending` and are retried at every run,
  also without the recorder connected.
- **Data volume:** about 40 to 50 MB per day; the recorder holds years.

## Measured facts about the Pegasus and its command-line Harvester (2.3.27)

Measured on a recorder with data from December 2023 to 2026 and compared with the
Pegasus Harvester application on the same computer.

1. **Use the whole device** (`/dev/sdb`), not the partition (`/dev/sdb1`); the
   partition is rejected as "not FAT32".
2. **Time windows work for data and logs.** A window of exactly one UTC day gives the
   same samples as the application (21 600 000 samples for a 100 Hz channel, identical
   sum, start and end). The bytes differ because the records are packed differently,
   so files are compared by content, never by byte for byte against the application.
3. **A day window also writes a short log stub for the neighbouring day.** Its own
   window exports that day complete, so `prune_other_days` drops files whose
   `.YYYY.JJJ` ending is not the exported day.
4. **State-of-health cannot be selected by time.** `-l` fails with "Lower bound not
   found" unless it equals the very first record, and an upper bound alone is
   ignored. The harvest still ends `COMPLETED(0)` with zero files, which is why this
   went unnoticed. TELE exports all SOH once per run into a work folder and gives
   each day its files (`.YYYY.JJJ`). The SOH volume is a fixed 572 MiB, so this is
   bounded; the time it takes on the Atom computer is to be measured.
5. **SOH types:** the command line writes 28 types (the application writes 25;
   `AGL`, `APT` and `VPO` are extra). All are kept.
6. **File names:** without `-ext=0` the command line appends `.mseed` and `.txt`; the
   application does not. TELE passes `-ext=0`.
7. **StationXML:** not written by the command line. At deployment the recorder stores
   a JSON record (gzip, base64) in its operation log (volume 5). `read-volume -id=5`
   prints it; the message times match the XML file names. TELE saves each as
   `NN.SSSS_<UTC>Z.json`. The application builds the 175 kB XML from this record plus
   its own sensor-response library.
8. **Harvest history:** each harvest, also from the command line, is written into the
   recorder (`show-history`, volumes 1, 2 and 7) with its page range. TELE does not
   depend on it; it keeps its own list of verified days.
9. **Volumes 8 to 10** exist in newer Harvester versions only; this recorder and
   version have volumes 1 to 7.

## Remaining checks on hardware

Not provable with the offline tests (`bash tests/run.sh`, `bash tests/installer.sh`),
which use a synthetic Harvester and local rclone:

- a real one-day export compared with the application for the same day (names,
  `soh/`, `logs/`) after the `-ext=0` and SOH changes;
- the time of the whole-volume SOH export on the field computer;
- Dropbox recovery after a link drop-out in the middle of a day;
- SSH/mosh sessions, VNC if used, the email on a poor link;
- BIOS wake in UTC, the USB relay cutoff, and a full wake, run and poweroff cycle
  with `tele-maintenance on` and `off`.

## Decisions

- No renaming: the computer keeps its own name and account; `station=` only selects
  the Dropbox folder and local state.
- The seismic tree is shared by all recorders of a computer; network and station
  codes in the paths keep them apart.
- Native names only; TELE adds files (`.json` records, `tele_logfiles/`) and never
  changes Harvester output.
