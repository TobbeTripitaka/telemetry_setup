# TELE collector modules

I keep the run order in `tele.sh` and recorder-specific work outside it.
A new source should not need another special-case branch in the main script.

## Run sequence

1. Lock the station and load private local settings.
2. Read matching Dropbox settings and check upload capability.
3. Read Starlink diagnostics.
4. Validate profiles and run each source in an isolated subshell.
5. Upload logs and attempt a status email.
6. In field mode only, offer the configured maintenance window.
7. Exit; the field systemd service owns shutdown.

`--check` only inspects setup and records local diagnostic/state files.
`--once` performs real collection/upload/email without shutdown. Neither command
is allowed while the field service or emergency timer is active.

## Files and responsibilities

| Location | Responsibility |
|---|---|
| `tele.sh` | Readable high-level sequence |
| `lib/workflow.sh` | Run preparation, shared steps, reporting and exit handling |
| `lib/sources.sh` | Profile discovery, validation, isolated dispatch and shared budget |
| `modules/pegasus.sh` | Pegasus identity, pending retry and native daily collection |
| `lib/harvest.sh`, `lib/upload.sh` | Complete-batch creation, frozen manifests, verification and retention |
| `modules/example.sh.disabled` | A development template, deliberately not an enabled provider |
| `/etc/tele/sources.d/*.conf` | Root-owned 0600 literal source settings |

Modules are trusted application code installed with the release. A Dropbox
configuration cannot supply a module path, shell command or executable profile.

## Provider contract

Each `modules/<type>.sh` defines four functions, returning nonzero on failure:

```bash
provider_validate() { :; } # Validate SOURCE_SETTINGS and set driver variables.
provider_target()   { printf '%s\n' logger_data; } # One fixed outer directory.
provider_check()   { :; } # Bounded identity/range inspection, no collection.
provider_collect() { :; } # Retry pending, acquire, validate, upload, verify.
```

These illustrative no-op bodies are not suitable implementations. Follow the
disabled template, which fails until real behaviour has been added and tested.

- **Input:** `SOURCE_SETTINGS` is an associative array populated by a literal
  parser. Validate every supported key, reject unknown keys and check identity
  before opening a device.
- **State:** use the supplied `STATE_ROOT`, `SPOOL`, `VERIFIED`, `OWNERS`,
  `LAST_BATCH`, `REMOTE_DATA`, `LOG_ROOT` and `RUN_ID`. Do not build another
  station's paths or mutate global settings outside the source.
- **Deadlines:** use `source_timeout` for external device commands and `cloud`
  for rclone. These respect the source deadline and add a bounded kill grace.
  Native Pegasus export has its own bounded timeout.
- **Uploads:** keep incomplete acquisition separate from ready data; verify
  contents before acknowledging or deleting local payloads. Do not use cloud
  sync/delete as a shortcut.
- **Errors:** leave complete pending data retryable and return failure.
  Runtime source failures mark the station report partial while allowing the
  next source to run. Invalid/duplicate profiles stop source dispatch entirely.
- **Power:** never call shutdown, modify the emergency timer or start an
  indefinite maintenance loop from a provider.

The collector shares a one-hour default allowance among sources. Fair shares
are assigned from the remaining allowance so a large first recorder does not
consume the entire acquisition window. This is cooperative provider budgeting,
not a sandbox: a newly written driver must bound all its own operations. The
separate field-service/timer ceiling remains the shutdown fallback.

## Single and multiple Pegasus recorders

Without profiles, the existing node.conf recorder settings select the legacy
single source. Its upload/state locations stay unchanged.

With profiles, each source gets:

```text
/var/lib/tele/<station>/sources/<source-id>/
<dropbox_root>/tele/<station>/pegasus_harvester/<source-id>/<native paths>
```

The Harvester's internal paths are unchanged. IDs and recorder identities must
not collide, including case-insensitive destination names.

Drain and verify pending uploads before switching an existing single recorder
to a profile. That switch selects new local and remote namespaces; TELE does not
move old files, merge checkpoints or pretend the new destination is populated.

## Tests required for another provider

Test absent/wrong hardware, bounded hangs, interrupted acquisition, partial-file
rejection, content mismatch, failed uploads, retry without hardware, retention,
native path collisions, profile isolation and failure followed by another source.
Then test on the actual logger and power arrangement before field activation.

The current implemented provider is Pegasus. Neither the camera placeholder nor
the disabled example claims to support another device yet.
