# TELE1 – Remote Data Collection System

Automated seismic data collection, Starlink diagnostics, and cloud upload for unattended field deployments.

TELE1 runs on Ubuntu 20.04 LTS (tested on Shuttle SPCEL03) and harvests data from Pegasus instruments via a Starlink internet connection. Data is compressed and uploaded to Dropbox with email status notifications.

Designed for remote sites with minimal power and intermittent connectivity.

<img src="https://github.com/TobbeTripitaka/telemetry_setup/blob/main/img/GRIT%20_Final.png" width="150">

---

## Features

- **Automated data harvesting** – Pegasus data logger via USB
- **Starlink diagnostics** – Connection quality and signal metrics
- **Cloud upload** – Compressed archives to Dropbox via rclone
- **Email notifications** – Status reports with log attachments
- **Remote access** – Tailscale SSH for debugging and reconfiguration
- **Power management** – Automatic shutdown with configurable wait times
- **Data cleanup** – Optional automatic deletion of old harvests

---

## Execution Modes

Configure behaviour after upload via `config.txt` in Dropbox:

| Mode | Behaviour |
|------|-----------|
| `auto` | Harvest, upload, notify, power down immediately |
| `ssh` | Harvest, upload, notify, wait for SSH access, then power down |
| `clear` | As `auto`, plus delete all local data and logs |
| `vnc` | Reserved for future release |

For `ssh` mode, set `WAIT_TIME_SSH` (in hours) to control how long the system remains powered on.

---

## Installation

Full setup instructions in `INSTALLATION.md`, covering:

1. Ubuntu 20.04 LTS installation and timezone setup
2. User account creation (`tele` with autologin)
3. System package installation (rclone, Node.js, Tailscale, etc.)
4. BIOS configuration (RTC power-on for Shuttle SPCEL03)
5. Tailscale VPN setup for remote SSH access
6. Project structure deployment
7. Credentials and cloud storage configuration
8. System verification and testing

---

## Quick Start

### Prerequisites

- Ubuntu 20.04 LTS on x86-64 hardware
- Pegasus data logger connected via USB
- Starlink Mini or equivalent internet
- Dropbox account (free tier OK)
- Gmail account (for email notifications)

See INSTALLATION.md for:

- Step-by-step setup
- Verification checklist
- Troubleshooting guide
- All resource links

For issues or feedback, open a GitHub issue.

Version: 0.3.0 | Updated: 9 January 2026

