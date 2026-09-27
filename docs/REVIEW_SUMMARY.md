# TELE1 native-CLI candidate: review summary

Prepared 27 September 2026 from GitHub main commit
`be9934be982b0f6027a2f2fa072d49a3b39eb0e5`.
Candidate version: **4.0.0-alpha.1**. Local branch: `work/native-cli-review`.
This is implemented locally and tested with mocks; it is not field-approved.

## Recommended option names

- **`incremental`:** normal weekly collection, retry pending work, skip identical
  uploaded content.
- **`reconcile`:** recheck the entire retained recorder history, sending only
  missing or changed files.
- **`reupload`:** deliberately send everything again. A request ID makes a large
  operation resumable rather than restarting it from the beginning every week.
- **`range`:** repair specified whole UTC days, preserving native output paths.

The two full-history choices requested are `reconcile` and `reupload`.
Local retention is independent: `RETAIN_LAST_BATCH=yes` or `no`, default `yes`.
“Last batch” currently means the last verified daily export, not all seven days
of a weekly run.

## Implemented locally

- **Collection:** native Harvester invocation, all enabled data types, whole-disk
  by-id/serial identification, daily files with no custom path pattern, no PSF image.
- **Safety:** allow-listed non-executable config, one-run lock, bounded commands,
  disk reserve monitoring, strict export status checks, and no recorder erasure.
- **Transfer:** frozen Dropbox-compatible hash manifests, content-aware copying,
  post-upload verification, durable per-day acknowledgments and resumable backlog.
- **Retention:** unverified completed batches survive; verified older payloads
  are removed locally; incomplete scratch is never uploaded and is re-harvested.
- **Power:** normal/error exit requests poweroff through systemd. Independent
  four-hour boot timer remains active through collection and maintenance.
  Harvesting has a one-hour cumulative native-export budget plus termination grace.
- **Maintenance:** only `ssh`/`vnc` modes wait, default 10 idle minutes, reset by
  detected sessions. Stale sessions cannot bypass the emergency timer.
- **Features:** Tailscale/SSH session detection, private virtual VNC service
  template, non-browser Starlink diagnostics, log retry and bounded email attempts.
- **Simplicity:** short orchestrator, seven focused Bash modules, one config parser,
  and no project JavaScript/Puppeteer or obsolete postaction module.
- **Version management:** candidate version, documented release/rollback policy,
  protected external state/credentials, and updated configuration examples.

## Verification completed

- **Automated tests:** 43 passed, zero failed. These use a synthetic native
  Harvester and real local rclone hash/copy operations, not real waveform data.
- **Static checks:** Bash syntax passed; ShellCheck warnings/errors passed with
  only intentional cross-module unused-global reporting excluded (SC2034).
- **Patch hygiene:** `git diff --check` passed.
- **Systemd parsing:** no unit-syntax errors were reported, but executable
  availability checks complained about the not-yet-installed application path
  and TigerVNC. No real service activation, timer firing or shutdown was tested.

Coverage includes shell-injection rejection, configuration fallback, timeouts,
low disk space, corrupted/extra local files, partial exports, failed copies,
failed verification, failed receipt publication, restart/retry without a recorder,
duplicate-transfer avoidance, forced reupload flags, retention, native path
collisions, volume range union, and remote idle-window reset.

## Required before field use

- **Original documentation/package:** the Harvester CLI PDF was not available
  in this fork's attachments. The adapter uses the pasted native help and output.
  The vendor `.deb` source/version is still unresolved.
- **Native export validation:** confirm daily waveform/SOH/log paths, midnight
  boundaries, time correction, complete sample coverage, empty intervals and exact
  success/missing-volume messages. The candidate blocks ambiguous cross-day file
  collisions rather than risking overwriting a fuller file.
- **Live Dropbox:** validate hashes and interruption recovery against a separate
  test station prefix, not the production station.
- **Ubuntu/Shuttle:** test vendor compatibility on the requested latest LTS,
  VNC, real SSH/Tailscale sessions, poweroff, USB relay release and the next BIOS wake.
- **Residual power risk:** software cannot guarantee power removal if the kernel
  or shutdown itself freezes. The four-hour value is a poweroff-request deadline,
  not an independent physical battery cutoff.
- **Installer:** intentionally not built yet. It comes after the acceptance gates,
  with version pinning, credential import, rollback and explicit field activation.

No GitHub commit/push/PR, real Dropbox upload, email, recorder access, or live
computer shutdown was performed. The complete changes are provided as a Git
patch; review and bench testing should precede publication or deployment.
