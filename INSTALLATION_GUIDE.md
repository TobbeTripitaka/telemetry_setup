# TELE1 v3.0 – Installation Guide

This guide covers:

- Fresh installation on a new Shuttle SPCEL 03 (or similar)
- Migration from TELE1 v0.2.0 to v0.3.0
- Verification and troubleshooting steps

---

## 1. Prerequisites

### 1.1 Hardware

- Shuttle SPCEL 03 (or similar x86 Linux machine)
- Pegasus data logger connected via USB
- Starlink router (optional but recommended)
- Stable power supply (with ability to power down safely)

### 1.2 Operating system

- Ubuntu 20.04 LTS or newer (server or desktop)
- User account `tele` (or equivalent) with home directory `/home/tele`

### 1.3 Packages

Install required packages:

```
sudo apt update
sudo apt install -y
bash curl jq git nodejs npm chromium-browser
openssh-server systemd
```

Confirm versions:

```
bash --version
curl --version
jq --version
node --version
chromium-browser --version
systemctl --version
```

### 1.4 Pegasus Harvester

The Pegasus Harvester binary must be installed and executable at:

```
/opt/PegasusHarvester/pegasus-harvester
```

If it lives elsewhere, adjust `PEGASUS_BIN` in `tele1.sh`.

---

## 2. Directory Structure

On the target machine (as user `tele`):

```
mkdir -p /home/tele/tele/{lib,js,log/computer,data/pegasus,config,state}
```

Final layout:

```
/home/tele/tele/
tele1.sh
credentials.txt
lib/
common.sh
hardware.sh
config.sh
harvest.sh
upload.sh
notification.sh
postaction.sh
dropbox_uploader.sh
js/
pegasus_harvest.js
starlink_get_json.js
log/
computer/
data/
pegasus/
config/
state/
```

---

## 3. Deploying Scripts

All script files should be owned by `tele` and executable.

### 3.1 Main script

Copy the main script:

```
cp tele1.sh /home/tele/tele/tele1.sh
chmod 755 /home/tele/tele/tele1.sh
chown tele:tele /home/tele/tele/tele1.sh
```

If you are upgrading from v0.2.0, back up the old script first:

```
cp /home/tele/tele/tele1.sh /home/tele/tele/tele1_v2_backup.sh
```

### 3.2 Libraries

Copy all library scripts:

```
cp common.sh hardware.sh config.sh harvest.sh notification.sh camera.sh remote.sh
/home/tele/tele/lib/

cp upload_updated.sh /home/tele/tele/lib/upload.sh
cp postaction.sh /home/tele/tele/lib/postaction.sh
cp dropbox_uploader.sh /home/tele/tele/lib/dropbox_uploader.sh

chmod 755 /home/tele/tele/lib/.sh
chown tele:tele /home/tele/tele/lib/.sh
```

### 3.3 JavaScript helpers

```
cp pegasus_harvest.js starlink_get_json.js /home/tele/tele/js/
chown tele:tele /home/tele/tele/js/*.js
```

---

## 4. Credentials and Secrets

All credentials are kept in `credentials.txt` next to `tele1.sh`.

### 4.1 Create credentials file

As user `tele`:

```
cat > /home/tele/tele/credentials.txt <<"EOF"
Email credentials

EMAIL_TO="recipient@example.com"
EMAIL_FROM="yourgmail@example.com"
EMAIL_PASSWORD="your_app_specific_password"
Optional overrides:
EMAIL_TIMEOUT=120

EOF

chmod 600 /home/tele/tele/credentials.txt
chown tele:tele /home/tele/tele/credentials.txt
```

Notes:

- Use a Gmail app-specific password, not your normal password.
- `notification.sh` expects these variables to be set and will exit with a clear message if they are missing.

### 4.2 Dropbox uploader

`dropbox_uploader.sh` uses `~/.dropbox_uploader` for its own token.

As user `tele`:

```
cd /home/tele/tele/lib
chmod +x dropbox_uploader.sh
./dropbox_uploader.sh
```

Follow the interactive instructions, which create `~/.dropbox_uploader`.

Test:

```
./dropbox_uploader.sh list /
```

---

## 5. Systemd Service

`tele1.service` runs TELE1 as a one-shot service with a 2-hour timeout and automatic power-down.

### 5.1 Install service file

```
sudo cp tele1.service /etc/systemd/system/tele1.service
sudo chmod 644 /etc/systemd/system/tele1.service
sudo systemctl daemon-reload
sudo systemctl enable tele1.service
```

Check for errors:

```
sudo systemd-analyse verify /etc/systemd/system/tele1.service
```

### 5.2 Manual start via systemd

```
sudo systemctl start tele1.service
sudo systemctl status tele1.service
journalctl -u tele1.service -f
```

The service:

- Runs `/home/tele/tele/tele1.sh` as user `tele`
- Waits up to 7500 seconds (~2 hours plus buffer)
- Targets `poweroff.target` on success or failure

---

## 6. Configuration (config.txt)

Configuration for post-actions is stored in Dropbox as `config.txt`. It is downloaded *after* the upload stage and interpreted by `postaction.sh`.

### 6.1 Minimal config

Create a local `config.txt` (for reference):

```
EXECUTE = simple
STANDBY = 0
```

Upload this file to Dropbox using `dropbox_uploader.sh` or the web UI.

Example using the uploader:

```
/home/tele/tele/lib/dropbox_uploader.sh upload config.txt /config.txt
```

### 6.2 Parameters

- `EXECUTE` (required)
  - `simple` – email + shutdown
  - `remote` – enable SSH, wait, shutdown
  - `clean` – cleanup, shutdown
  - `update` – placeholder

- `STANDBY` (for `remote` only)
  - Number of seconds to wait with SSH enabled
  - Example: `STANDBY = 3600` for one hour

If `config.txt` is missing or invalid, defaults are used:

- `EXECUTE=simple`
- `STANDBY=0`

---

## 7. Quick Start – Fresh Installation

This section assumes no previous TELE1 install.

### Step 1 – Create user and directories

```
sudo adduser --disabled-password --gecos "" tele
sudo -u tele mkdir -p /home/tele/tele/{lib,js,log/computer,data/pegasus,config,state}
```

### Step 2 – Install packages

Follow section 1.3 to install required packages.

### Step 3 – Install Pegasus harvester

Place the Pegasus Harvester binary at:

```
/opt/PegasusHarvester/pegasus-harvester
```

### Step 4 – Deploy TELE1 scripts

As root or your admin user, copy scripts into `/home/tele/tele` as described in sections 3.1–3.3.

Ensure ownership is `tele:tele` and scripts are executable.

### Step 5 – Configure Dropbox uploader

As user `tele`:

```
cd /home/tele/tele/lib
./dropbox_uploader.sh
```

Complete the OAuth steps and test:
```
./dropbox_uploader.sh list /
```

### Step 6 – Configure credentials

Create `/home/tele/tele/credentials.txt` with email settings as in section 4.1.

### Step 7 – Install systemd service

Copy `tele1.service` into `/etc/systemd/system/` and enable it as in section 5.1.

### Step 8 – Create initial config.txt in Dropbox

Create a local file:
```
EXECUTE = simple
STANDBY = 0
```

Upload to Dropbox:
```
/home/tele/tele/lib/dropbox_uploader.sh upload config.txt /config.txt
```

### Step 9 – First test run (manual)

Run directly:
```
sudo -u tele /home/tele/tele/tele1.sh
```

Monitor log:
```
tail -f /home/tele/tele/log/computer/tele1_*.log
```

Check for:

- Harvest attempts and result
- Upload success/failure
- Email status
- No unhandled errors

### Step 10 – Systemd test

Run via systemd:
```
sudo systemctl start tele1.service
sudo systemctl status tele1.service
journalctl -u tele1.service -f
```

Confirm:

- `tele1.sh` runs as user `tele`
- Log file is created and populated
- Email is sent
- System powers down at the end (if not blocked by other services)


---

## 8. Migration from TELE1 v0.2.0

If you already have TELE1 v0.2.0 installed, follow this section.

### 8.1 Backup existing installation

cd /home/tele/tele
tar -czf tele1_v2_backup_$(date +%Y%m%d).tar.gz tele1.sh lib/ js/ config/ state/ log/


### 8.2 Deploy new scripts

- Rename existing `tele1.sh` to `tele1_v2.sh` (for safety):

mv /home/tele/tele/tele1.sh /home/tele/tele/tele1_v2.sh


- Copy in the new `tele1.sh`, libraries, and JS files as outlined in sections 3.1–3.3.

The following v2.0 files remain usable:

- `lib/common.sh`
- `lib/hardware.sh`
- `lib/harvest.sh`
- `lib/notification.sh`
- `js/pegasus_harvest.js`
- `js/starlink_get_json.js`
- `dropbox_uploader.sh`

### 8.3 Install systemd service

If v2.0 used cron only, you can keep the cron job or move to systemd. For v3.0, systemd is recommended.

Install `tele1.service` as in section 5.1.

### 8.4 Update credentials

Create `credentials.txt` as described earlier if it does not exist.

Remove any hard-coded credentials from older copies of `notification.sh`. Ensure the new `notification.sh` is in place and uses environment variables only.

### 8.5 Create new config.txt in Dropbox

Instead of the old multi-parameter config from v2.0, create a simple one:

EXECUTE = simple
STANDBY = 0


Upload to `/config.txt` in Dropbox.

### 8.6 Test run

Run TELE1 manually and via systemd as in section 7. Confirm:

- Data is still harvested correctly
- Uploads go to the expected Dropbox folders
- Email content is sensible
- Power-down occurs as expected

Once satisfied, disable any old cron jobs that run the previous `tele1.sh`.

---

## 9. Verification Checklist

Before relying on TELE1 in the field, confirm:

- [ ] `tele1.sh` runs without syntax errors:
      `bash -n /home/tele/tele/tele1.sh`
- [ ] All library scripts source cleanly:
      `bash -c 'source /home/tele/tele/lib/common.sh'`
- [ ] Pegasus harvest completes at least once
- [ ] `dropbox_uploader.sh` can list and upload files
- [ ] Email notifications arrive reliably
- [ ] System powers down via `tele1.service`
- [ ] `EXECUTE=simple` behaves as intended
- [ ] `EXECUTE=remote`, `STANDBY=60` enables SSH and delays shutdown
- [ ] `EXECUTE=clean` removes old data and logs as expected

---

## 10. Troubleshooting

### 10.1 tele1.sh fails immediately

Check:
```
bash -n /home/tele/tele/tele1.sh
```

Look at:
```
tail -n 50 /home/tele/tele/log/computer/tele1_*.log
```

Common causes:

- Missing libraries in `/home/tele/tele/lib`
- Missing `credentials.txt`
- Wrong ownership or permissions

### 10.2 Systemd service failing

Check:

sudo systemctl status tele1.service
journalctl -u tele1.service -n 50 --no-pager


Verify:

- `WorkingDirectory` in `tele1.service` is `/home/tele/tele`
- `ExecStart` points to `/home/tele/tele/tele1.sh`
- User `tele` exists and can run the script manually

### 10.3 No data in Dropbox

Confirm:

/home/tele/tele/lib/dropbox_uploader.sh list /


Check network:
```
ping -c 1 8.8.8.8
```

Check TELE1 logs for `upload_harvest_data` and `upload_log_file` messages.

### 10.4 No email

Confirm credentials in `credentials.txt` and test with a minimal curl command as described in the README.

---

## 11. Notes on Australian Co

- Times and scheduling examples assume local time configured correctly
- Ensure time synchronisation (e.g. `systemd-timesyncd` or `ntp`) to keep timestamps accurate
- Power policy should align with local site requirements (e.g. solar/battery systems)

---

## 12. Where to Next?

- See `README.md` for a complete overview of features and behaviour
- See `VISUAL_SUMMARY.txt` for diagrams and flowcharts

This concludes the installation guide for TELE1 v0.3.0. Let me know if something is missing. 

Toby