# TELE1 v4 installation status

This candidate is not yet approved for an unattended field installation.
The automatic installer is intentionally deferred until real-device collection,
Dropbox verification, remote access, and power-down tests pass, as requested.
The previous v3 installation guide remains available in Git history at
`be9934be982b0f6027a2f2fa072d49a3b39eb0e5`.

## Intended target

The user selected the latest Ubuntu LTS and the existing Shuttle platform with
BIOS wake-up. Ubuntu currently lists 26.04.1 LTS; compatibility with the specific
Nanometrics package must be tested rather than assumed ([Ubuntu releases](https://releases.ubuntu.com/)).

The older guide identifies a Shuttle SPCEL03 and a USB-controlled Starlink
power relay. BIOS wake-up and USB power-off behaviour must be checked physically:
software cannot confirm that the USB rail actually loses power in the selected
firmware configuration. Do not remotely upgrade the deployed computer as part
of this candidate.

## Required components

- **Collection:** Bash, coreutils, util-linux, findutils, grep, sed, awk, jq,
  iproute2, procps, rclone and the vendor-provided native Harvester.
- **Email:** curl and CA certificates; Gmail app-password credentials in a
  root-owned mode-0600 file, not ordinary account passwords in arguments.
- **Starlink:** grpcurl with local access to `192.168.100.1:9200`; `get_status`
  is read-only, but firmware support must be tested ([Starlink query example](https://rcastellotti.dev/posts/development-of-a-framework-for-retrieval-of-parameters-of-the-starlink-dish)).
- **Remote access:** Tailscale and SSH access rules. Tailscale's built-in SSH
  differs from ordinary OpenSSH over the tailnet, so both session-detection paths
  require testing ([Tailscale SSH documentation](https://tailscale.com/docs/features/tailscale-ssh)).
- **VNC:** candidate template for TigerVNC standalone server, Xfce and
  dbus-run-session. It provides a private virtual desktop, not screen sharing
  of the physical GNOME desktop. This avoids relying on an Xorg GNOME session;
  Ubuntu 26.04's GNOME desktop is Wayland-only ([Ubuntu desktop change](https://www.theregister.com/software/2026/04/24/ubuntu-resolute-raccoon-drops-xorg-keeps-x11-apps-alive/5225331)).

The `tele1-vnc@tele.service` template expects a `tele` user, `/home/tele`, and a
TigerVNC password file at `/etc/tele1/vnc/tele.passwd` readable only by that user.
It binds to loopback on port 5901. Use an SSH tunnel over Tailscale; do not expose
VNC publicly. Exact command options/package versions still need target testing.

## Proposed installed layout

```text
/opt/tele1/releases/<tested-version>/
/opt/tele1/current -> releases/<tested-version>
/etc/tele1/node.conf
/etc/tele1/credentials.txt
/etc/tele1/rclone.conf
/etc/tele1/vnc/tele.passwd
/etc/tele1/FIELD_ENABLED
/var/lib/tele1/<station_name>/
/var/log/tele1/<station_name>/
```

`node.conf` fixes station identity, the Dropbox remote/root, a stable whole-disk
`/dev/disk/by-id` path, and the expected USB disk serial. Identify them on the
actual computer. Do not copy `/dev/sdb` from a previous session into automation.
Node and credential examples are under `config/`; their private installed
versions must be root-owned with mode 0600.

## Shutdown protection

The service templates are deliberately not installed/enabled by any script in
this candidate. Installing and enabling them on a workstation could power that
workstation off. Only explicitly approved field deployment should create the
`FIELD_ENABLED` marker and enable both the collector and independent boot timer.

- **Normal/error exit:** `tele1.service` requests poweroff through `ExecStopPost`.
- **Stalled collector:** `tele1-power-guard.timer` independently requests
  poweroff four hours after boot; collector `RuntimeMaxSec` is an additional limit.
- **Per-harvest timeout:** one-hour cumulative native export budget, with a
  bounded termination grace period.
- **Emergency limit:** administrator-controlled systemd drop-in, with
  `OnBootSec` and `RuntimeMaxSec` updated together. Do not let a malformed
  Dropbox config disable the local battery-protection ceiling.

This is a shutdown-request deadline, not a hardware power-cut guarantee.
A complete OS/kernel freeze or stalled shutdown can defeat software safeguards.
The standard systemd runtime hardware watchdog reboots, rather than guarantees
poweroff; it must not be presented as an equivalent battery cutoff
([systemd watchdog documentation](https://manpages.debian.org/bookworm/systemd/systemd-system.conf.5.en.html)).

## What the future single-file installer still needs

- **Vendor package:** its acquisition method, distribution permission, version
  and checksum. The GitHub repo does not supply a Nanometrics installer.
- **Credentials bundle:** email settings plus authorized Dropbox refresh-token
  configuration and Tailscale enrollment material. An email/password alone is
  not sufficient for initial Dropbox OAuth authorization ([rclone Dropbox setup](https://rclone.org/dropbox/)).
- **Non-secret station settings:** unique station name, Dropbox root, disk
  identity, and maintenance choices can live in that same private setup input.
  The installer can split them into protected runtime files.
- **Version controls:** tested pins, idempotent setup, rollback, service
  validation, and an explicit lab-versus-field activation step.
- **BIOS:** a documented physical setup/check remains necessary unless a
  supported firmware-management interface is established.

The installer should not install browsers/Node for TELE1, automatically upgrade
the OS, publish secrets to GitHub/Dropbox, start an unbounded GUI, or enable field
shutdown on the installation workstation.
