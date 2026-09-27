# TELE names and station configuration

The project and its runtime entry point are now TELE and `tele.sh`.
The GitHub repository remains `TobbeTripitaka/telemetry_setup`; this change does
not rename the repository or alter the Harvester's native filenames.

## Names and locations

| Item | TELE location |
|---|---|
| Main script | `tele.sh` |
| Collector service | `tele.service` |
| Emergency timer | `tele-power-guard.timer` |
| Emergency action | `tele-poweroff.service` |
| VNC template | `tele-vnc@.service` |
| Code | `/opt/tele/current` |
| Local configuration | `/etc/tele/node.conf` and `/etc/tele/config.txt` |
| Credentials | `/etc/tele/credentials.txt` and `/etc/tele/rclone.conf` |
| State | `/var/lib/tele/<station>/` |
| Logs | `/var/log/tele/<station>/` |
| Field activation | `/etc/tele/FIELD_ENABLED` |

The local and remote `config.txt` must contain the same required label:

```ini
station=station01
EXECUTE=auto
HARVEST_MODE=incremental
```

The script reads `/etc/tele/config.txt` first and derives
`<dropbox_root>/tele/station01/config.txt`, the upload destinations and local
state paths from it. Remote settings with a different or missing `station` are
ignored in favour of a matching valid cache or the local settings.

`station` is not a seismic metadata editor. It changes the outer station folder,
not miniSEED headers, network codes or the native Harvester subdirectories.

## Existing installations

Do this on the bench or during planned maintenance with physical recovery
available. No migration is run automatically on a field computer by this commit.

- **Stop competing launchers:** retire the installed `tele1.service`,
  `tele1-power-guard.timer`, poweroff and VNC units before enabling the TELE units.
  Stopping an active collector can request poweroff, so do not treat this as a
  harmless remote restart. Also check for a desktop launcher such as
  `/home/tele/.config/autostart/tele1.desktop` and any old cron entry.
- **Install a complete release:** use the renamed script and matching unit files
  together under `/opt/tele`; do not mix old/new module or service paths.
- **Move private settings deliberately:** transfer settings from `/etc/tele1`
  to `/etc/tele` with the documented ownership and permissions. Move
  `STATION_NAME` out of `node.conf` and put its value under lowercase `station`
  in `/etc/tele/config.txt`; the old node key is no longer accepted.
- **Add the remote label:** put the same `station` in the station's Dropbox
  `config.txt`. Without it, that remote file is rejected and local/matching
  cached settings are used.
- **Preserve state and logs:** move the matching station tree from
  `/var/lib/tele1` to `/var/lib/tele` and logs from `/var/log/tele1` to
  `/var/log/tele` only while no collector is running. Preserve ownership and
  retain pending payloads, acknowledgments, ownership records and recorder ID.
  Do not overwrite an already populated destination tree blindly.
- **Keep the destination identical during migration:** existing acknowledgments
  are reusable only if the recorder, station label, Dropbox remote and Dropbox
  root still refer to the same archive. The cloud `tele/<station>/` layout itself
  has not changed.
- **Keep valid rclone credentials:** `tele_dropbox` is the example remote name,
  not a compulsory rename of an already authorized remote. `RCLONE_REMOTE` must
  name the remote actually present in the protected rclone configuration.
- **Check activation last:** install/review both TELE shutdown units and their
  overrides, then explicitly activate the new field service after tests pass.
  Do not leave an old emergency timer armed alongside the new one.

## Intentionally changing a station label

A different label selects a different local state directory and Dropbox prefix.
Place a matching config at the new remote location and update the local
`station` before the next run.

Do not copy old verified acknowledgments into a new empty cloud namespace:
they would describe uploads to the old destination, not the new one. Start
with fresh state and reconcile the available recorder data, preserving any old
pending data until it has been safely recovered or deliberately migrated.
Do not rename a station during an active collection.
