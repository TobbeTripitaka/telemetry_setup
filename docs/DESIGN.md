# TELE v4 candidate: design and review

This document records the implementation decisions after reviewing the GitHub
baseline and the supplied scripts. It distinguishes local software validation
from the device and service testing still required before field use.

## Agreed operating contract

- **Power:** weekly BIOS wake-up; USB 5 V energizes the Starlink relay; no new
  external power controller. Normal completion and failures should power off.
- **Budgets:** native harvesting gets at most 3,600 cumulative seconds plus
  termination grace. The independent emergency timer requests poweroff at four
  hours from boot, including during remote sessions.
- **Maintenance:** only `ssh`/`vnc` modes wait after the collection/report stages.
  Default is 600 idle seconds. Detected active connections keep resetting the
  countdown; the emergency timer still wins.
- **Data:** up to about 50 MB/day, about three years retained by the recorder;
  waveform, SOH, legacy SOH and logs, without a PSF image.
- **Storage:** native Harvester paths inside a station-specific Dropbox prefix;
  no wrapping archive/run directory. Keep completed pending exports and,
  optionally, the last verified daily batch locally.
- **Features:** remote Dropbox settings, Tailscale SSH, VNC, Starlink diagnostics,
  and an email attempt each run. Camera is not in the runtime path.

## Corrections to the earlier discussion

- **Shutdown on failure is required**, not a design defect for this application.
  The defects were late installation of the exit trap and inadequate protection
  against a stuck process. The initial `INT TERM EXIT` trap in the supplied
  `tele.sh` was commented out, not an active first trap.
- **The old `PEGASUS_BIN` path was a GUI launch target.** It was not necessarily
  wrong for the old Puppeteer workflow. The replacement deliberately uses the
  verified bundled native `.../build/Release/harvester`.
- **“Since last” was not implemented in `tele.sh`.** Configuration passed a
  mode to JavaScript, which selected the GUI button. It was not tied to Dropbox
  verification. The replacement owns per-day upload acknowledgments.
- **`-safe` is not read-only mode.** The user's native output includes
  `flush-harvesting-history`. No erase/format/init command is introduced, but the
  Harvester can update its own recorder history.
- **Sensor bounds alone are insufficient for all data types.** The candidate
  queries volume IDs 1–7 and uses the union of available positive time bounds.
  Metadata-only volumes and missing-volume messages require device validation.
- **File durations need explicit testing.** The pasted CLI help says the
  harvest default is one hour while the default path contains a day number.
  The candidate explicitly requests `-d=24` and does not override `-p`.

## Pipeline and transaction boundary

The lowercase `station` setting in `/etc/tele/config.txt` supplies the upload
and local-state label. Node configuration contains hardware identity and the
Dropbox remote/root, not the station label. The station's downloaded `config.txt`
must declare the same label; a missing/mismatched label is rejected before the
cache or active settings are changed.

This resolves the initial config-location lookup without letting a misplaced
remote file switch destinations and reuse checkpoints from a different station.
See `docs/RENAME.md` before changing an installed station's paths.

```text
boot timer active
  -> field service / exclusive lock
  -> local identity and safe config
  -> Starlink diagnostics
  -> verify/retry complete pending exports
  -> identify recorder and inspect available volumes
  -> for each required UTC day:
       isolated native export
       exit/status checks and disk reserve checks
       freeze Dropbox-compatible file hashes
       mark local batch ready
       copy missing/changed files (or force requested transfer)
       verify remote hashes against the frozen manifest
       publish small receipts
       atomically acknowledge day locally
       retain last daily batch / remove older verified payload
  -> log upload and email attempt
  -> optional bounded SSH/VNC maintenance
  -> final log snapshot
  -> systemd poweroff
```

An interrupted native export has no ready batch or acknowledgment. Its scratch
payload is discarded on recovery after saving the diagnostic log, and its day
is re-harvested. A completed export whose upload or verification failed remains
pending. A crash after Dropbox accepted data but before the local acknowledgment
causes a retry; content comparison avoids unnecessary normal retransmission.

Rclone's Dropbox backend supports its content hash; verification uses an
explicit Dropbox hash manifest rather than a size-only check. The candidate
uses synchronous Dropbox batching, not asynchronous upload acceptance
([rclone Dropbox integrity behaviour](https://rclone.org/dropbox/)).
These checks verify transferred bytes, not scientific signal validity.

No remote deletion or recorder deletion is performed. Dropbox extra files are
left alone through one-way verification; the candidate is not a destructive mirror.
One-way checking only requires source files to exist and match remotely
([rclone check](https://rclone.org/commands/rclone_check/)).

## Module responsibilities

- **`tele.sh`:** short orchestration, exclusive lock, stage status, best-effort
  failure notification, maintenance entry. Shutdown is owned outside the script.
- **`common.sh`:** stderr logging, atomic durable replacements, command bounds,
  dependency/private-file checks and free-space threshold.
- **`config.sh`:** allow-listed literal parsing; no `source`/`eval`. Rejects
  duplicate/unknown settings and impossible dates. Last validated remote config
  survives a bad or failed download.
- **`hardware.sh`:** whole-disk by-id and serial verification, refusal of the OS
  disk, recorder identity binding, metadata and volume range inspection.
- **`harvest.sh`:** isolated daily exports, all enabled types, exit/message checks,
  bounded child process, disk monitoring, ready markers, resumable requests.
- **`upload.sh`:** immutable-manifest checks, native path collision guard,
  content-aware upload, remote verification, acknowledgments and retention.
- **`notification.sh`:** bounded read-only Starlink gRPC request, immutable log
  snapshots, retry of previous logs, private curl credential file, status email.
- **`remote.sh`:** conservative SSH/Tailscale/VNC connection detection and
  idle-window reset; no package installation during a collection run.
- **`systemd/`:** boot-time emergency guard, collector cleanup poweroff, and
  private virtual-desktop VNC service template.

The old postaction module was unused by the main script and duplicated incompatible
mode names. Its cleanup search could include the data directory itself. It is
removed instead of retaining another deletion/control path.

## Important limits and unresolved checks

- **No software-only power guarantee:** kernel failure, a stalled poweroff, or
  firmware leaving USB powered cannot be ruled out without physical testing.
  The user cannot add an independent hardware cutoff.
- **Native path collisions:** daily waveform files are expected, but native SOH,
  metadata and log naming still need inspection. A path reused by different days
  is rejected rather than overwriting a potentially longer earlier file. This
  intentionally blocks collection until the format is understood.
- **Cross-day timing:** exact endpoint inclusion, records straddling midnight,
  linear time correction, and late GPS/metadata changes require real miniSEED
  comparison. A two-day overlap is not proof that arbitrarily old corrections
  will be detected; use `reconcile` for historical repair.
- **Meaning of “all”:** it covers the recorder's currently retained history,
  not already overwritten recordings. Volume-range advance is warned about.
  The candidate does not reconstruct files from the remote receipts automatically;
  missing local state instead leads to re-harvest with hash-based transfer skipping.
- **One station writer:** different computers must use distinct station prefixes.
  The local lock does not coordinate two independent computers writing one prefix.
- **Fresh station prefix for tests:** legacy archives are not unpacked/migrated,
  and existing unverified daily files must not be assumed complete. Test against
  an isolated Dropbox station prefix before production reconciliation.
- **Local retention:** “last batch” means one daily chunk, not the whole weekly
  upload. It is configurable on/off in this candidate.
- **Notifications:** best effort and bounded; unavailable network or an emergency
  poweroff can prevent email. An abrupt whole-system failure cannot be reported
  by the failed machine.
- **VNC behaviour:** a private virtual Xfce desktop is proposed; it is not an
  exact clone of the old physical-screen x11vnc experience.
- **Session detection:** conservative process/socket checks include idle transport
  connections. They are not a universal authentication-aware session API and
  must be validated with installed OpenSSH, Tailscale and VNC versions.
- **Files not available:** the original CLI PDF and vendor `.deb` were not present.
  The supplied terminal help and successful recorder output informed the adapter.

## Code-version policy

Use a reviewed branch and a tagged, tested release with an exact commit/checksum.
Never update an inaccessible field node directly from a moving `main` branch.
Keep recorder progress, pending files and secrets outside versioned code.
The future installer must support rollback of code without rolling back upload
acknowledgments or deleting pending data.

No GitHub commit, push, pull request, live Dropbox write, device read/write, email,
poweroff, or field deployment was performed during this candidate's local tests.
