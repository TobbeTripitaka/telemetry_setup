# TELE1 v3.0

Automated telemetry collection and upload system for Pegasus data loggers and Starlink internet connections on a Shuttle SPCEL 03 (or similar Linux host).

This version focuses on a simpler configuration model, robust shutdown behaviour, and clearer documentation.

---

## 1. Purpose

TELE1 automates:

- Harvesting data from a Pegasus data logger
- Collecting basic Starlink diagnostics
- Compressing and uploading data and logs to Dropbox
- Sending a status email with a log attachment
- Powering down the computer safely after completion

It is intended for unattended operation at remote sites with limited power and intermittent connectivity.

---

## 2. Key Features (v3.0)

- **Data-first execution**: Harvest and upload before configuration-driven post-actions
- **Simple configuration**: Two primary options – `EXECUTE` and `STANDBY`
- **Post-action modes**:
  - `simple` – email and power down
  - `remote` – enable SSH, wait, then power down
  - `clean` – delete old data/logs, then power down
  - `update` – reserved for future update automation
- **Guaranteed shutdown**:
  - Internal timeout (1 hour 50 minutes) with cleanup and power-down
  - Systemd timeout (2 hours) as a last resort
- **Data compression**: Harvest data compressed to `tar.gz` before upload
- **Email reporting**: Status email summarising harvest and upload results
- **Dropbox integration**: Data and logs uploaded via `dropbox_uploader.sh`
- **SSH support**: Optional SSH daemon enablement for remote access
- **Cleanup tools**: Automatic removal of old harvests and logs
- **Extensive logging**: Detailed log file for each run in `log/computer/`

---

## 3. Architecture Overview

### 3.1 Components

- `tele1.sh`
  - Main orchestration script
  - Controls stages, logging, and shutdown

- `lib/common.sh`
  - Logging functions
  - State management
  - Utility helpers

- `lib/hardware.sh`
  - Hardware presence checks
  - Network checks
  - System information

- `lib/config.sh` (legacy)
  - Legacy configuration parsing (v2.0 style)
  - Left for compatibility but not used for v3.0 post-actions

- `lib/harvest.sh`
  - Pegasus harvester automation
  - Starlink router scraping via Node/Chromium (through JS scripts)

- `lib/upload.sh` (from `upload_updated.sh`)
  - Data compression
  - Data and log upload to Dropbox

- `lib/notification.sh`
  - Starlink diagnostics collection
  - Status report building
  - Email sending, using Gmail over `curl`

- `lib/postaction.sh`
  - New in v3.0
  - Downloads and parses `config.txt` from Dropbox
  - Executes EXECUTE/ STANDBY-driven actions

- `js/pegasus_harvest.js`
  - Node.js script to drive Pegasus web UI and download data

- `js/starlink_get_json.js`
  - Node.js script to query Starlink status JSON

- `dropbox_uploader.sh`
  - Third-party Dropbox uploader script

- `tele1.service`
  - Systemd service unit, type `oneshot`

- `credentials.txt`
  - Local file containing email credentials and other secrets in this format:


```
# /home/tele/tele/credentials.txt

EMAIL_TO="YOUR_TO_ADDRESS"
EMAIL_FROM="YOUR_FROM_ADDRESS"
EMAIL_PASSWORD="YOUR_APP_PASSWORD"
```


---

## 4. Execution Flow (v3.0)

The v3.0 flow is:

1. **System preparation**
   - Check dependencies
   - Ensure directories exist
   - Open log file
   - Gather system info

2. **Hardware checks**
   - USB devices present
   - Pegasus binary available
   - Network interfaces present

3. **Data collection**
   - Collect Starlink diagnostics
   - Run Pegasus harvest (with retry logic)
   - Track harvest directory, file count, and size

4. **Compression**
   - Compress harvest directory to `tar.gz`
   - Record archive size and file count in state

5. **Upload**
   - Upload compressed data to Dropbox
   - Upload log file to Dropbox
   - Update state for data and log upload

6. **Configuration (post-upload)**
   - Download `config.txt` from Dropbox
   - Parse `EXECUTE` and `STANDBY`
   - Load defaults if download fails

7. **Post-action**
   - Based on `EXECUTE`, run one of:
     - `simple`: nothing extra – email and shutdown
     - `remote`: enable SSH and wait `STANDBY` seconds
     - `clean`: delete old data and logs
     - `update`: placeholder

8. **Notification**
   - Build a status report from state
   - Format subject and body
   - Send email with log attachment
   - Create local notification file if email fails

9. **Shutdown**
   - Clean temporary files
   - Power down via systemd or direct `poweroff -f` as fallback

---

## 5. Configuration

All secrets are stored in `credentials.txt` which sits next to `tele1.sh`.

### 5.1 Credentials file

Create `/home/tele/tele/credentials.txt`:

