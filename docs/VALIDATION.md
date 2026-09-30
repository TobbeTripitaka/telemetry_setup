# TELE v4 validation and field-release gates

Local tests cannot establish that Pegaqus exports complete scientific
data or that the Shuttle powers off reliably. Treat this checklist as a release
gate, not optional documentation.

## Local verification

`tests/run.sh` uses synthetic native-command outputs and real local rclone
transfers with Dropbox-compatible hashes. It does not send network traffic or
run any systemd poweroff service. The fixtures are not genuine miniSEED.

Covered cases include:

- **Configuration:** no execution of injected shell, duplicate/unknown key
  rejection, hard bounds, date validation, request IDs, and rejection of a
  partially valid remote config without corrupting the cached one.
- **Station paths:** required lowercase `station` in local config, safe label
  validation, isolated local/remote namespaces, and rejection of missing or
  mismatched remote/cached station labels without redirecting uploads.
- **Project naming:** renamed entry point remains executable and systemd
  collector/timer references agree with the TELE paths.
- **Acquisition:** complete exports, native errors despite status output,
  timeout, low disk reserve, missing optional clock volume, union of SOH/log/data
  bounds, exact command arguments, and no custom `-p`.
- **Storage integrity:** local tampering, extra local files, symbolic links and
  case-folding collisions are rejected; native cross-day path reuse is blocked.
- **Recovery:** upload/verification/receipt failures do not acknowledge the day;
  pending data survives; subsequent retries work without the recorder; incomplete
  scratch is never uploaded and is reclaimed after saving diagnostics.
- **Efficiency:** unchanged local test-backend contents are not replaced on
  normal reconciliation; forced reupload passes `--ignore-times`; old verified
  days are skipped; a new full-scan request revisits them.
- **Retention:** keep only the last verified daily batch or disable retention;
  unrelated remote files survive; previous run logs are retried.
- **Remote windows:** auto mode skips waiting; detected SSH/Tailscale/VNC sessions
  defer normal shutdown; the idle countdown restarts after disconnect.

Static validation: Bash syntax and ShellCheck warnings/errors, excluding
SC2034 for intentional cross-module globals. Unit files can be parsed with
`systemd-analyze verify`; this sandbox does not have the final installation
path or TigerVNC, so executable-availability warnings are expected. Static
parsing is not a test of actual timer firing, service termination or poweroff.

## Bench preparation

Use the test Shuttle and a separate Dropbox prefix, not the deployed field
station's existing data. Keep physical access and mains power available.
Do not enable the field poweroff units on your ordinary workstation.

Record:

```bash
cat /etc/os-release
uname -m
lsblk -o NAME,TYPE,TRAN,SERIAL,LABEL,MOUNTPOINTS
ls -l /dev/disk/by-id/
```

Then, using the verified native executable:

```bash
/opt/PegasusHarvester/resources/app/node_modules/@nanometrics/pegasus-harvest-lib/build/Release/harvester version -all
```

The version command should not access the recorder. Any subsequent device
operation must use the newly confirmed whole-disk identity, not an old `/dev/sdX`.
Obtain the original CLI PDF and the approved vendor package/version.

## Recorder acceptance

- **Identity:** confirm one correct Pegasus and reject no-device, wrong-serial,
  multiple-device and system-disk targets.
- **Volume inspection:** capture IDs 1–7, missing-volume exit status/messages,
  metadata-only volumes and oldest/newest bounds for all output types.
- **Native paths:** harvest two consecutive days separately and together,
  including waveform, SOH, legacy SOH and logs. Compare full relative file lists.
  Establish whether any same path contains different partial contents across days.
- **Scientific completeness:** compare sample counts, channel IDs, sample rates,
  timestamps, gaps and overlaps against the vendor GUI/reference export with an
  independent miniSEED reader. Hash equality alone is insufficient for this.
- **Boundaries:** test exact midnight, records crossing midnight, earliest/latest
  samples, current partial day, and time-correction changes.
- **No-data interval:** distinguish an empty successful interval from a failed
  read. Confirm the expected success messages for the installed native version.
- **Interruption:** kill a short test export, restart and prove no scratch was
  uploaded and the same day is recovered completely.
- **Budget:** test with shortened timeouts, not a one-hour wait, and ensure no
  orphaned native child process remains.

## Dropbox and failure acceptance

- **Verification:** upload real daily files and independently compare Dropbox
  hashes/downloaded bytes; confirm all three data categories reach native paths.
- **Idempotence:** repeat reconciliation and inspect real rclone transferred-byte
  counters. Reupload with a fresh ID must actually retransmit.
- **Partial upload:** disconnect Starlink mid-upload, reboot and recover without
  treating a partial/failed file as verified.
- **State loss:** copy state aside on the bench, remove local progress in a test
  instance, and verify reconciliation restores coverage without deleting remote data.
- **Backlog:** test several days and a historical scan across more than one run.
- **Disk failure:** simulate low space and a failed acknowledgment write. Pending
  data must remain and the run must still reach shutdown.
- **Error reporting:** no recorder, invalid configuration, unavailable Dropbox,
  expired auth and SMTP failure must produce honest status and bounded behaviour.

## Power and remote-access acceptance

- **Early failures:** missing credentials, missing module, invalid config,
  nonexistent Harvester and failed dependency checks must not leave the field
  computer powered indefinitely.
- **Stall:** deliberately stall the collector in a harmless bench fixture. With
  a shortened emergency timer, show that poweroff occurs independently.
- **USB relay:** physically confirm Starlink loses power after shutdown, including
  failed runs. Check BIOS USB standby-power and wake settings.
- **Normal modes:** auto powers off without maintenance waiting. SSH/VNC modes
  wait 600 idle seconds after the work and notification stages.
- **Session matrix:** test OpenSSH, built-in Tailscale SSH, non-interactive file
  transfers, SSH tunnels, VNC, multiple users, idle sessions and abrupt disconnects.
- **Countdown reset:** connect just before expiry, remain connected past it,
  disconnect, then verify a fresh idle window.
- **Emergency cap:** a connected user cannot keep the computer awake beyond the
  configured boot-time emergency deadline.
- **Weekly wake:** demonstrate a full BIOS wake, collection, shutdown and next
  scheduled wake cycle before deployment.

Only after these pass should the automated installer be written and field
activation approved. Tests cannot eliminate the residual risk of an OS/kernel
freeze without an independent physical power controller.
