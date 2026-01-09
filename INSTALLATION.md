# TELE1 Installation Guide

**Version:** 3.0 | **Last updated:** 9 January 2026 

This guide covers the complete setup of a TELE1 data collection node from bare Ubuntu 20.04 LTS to a field-ready (test) system. 

This system has been running successfully in Australia for several months and we're expanding testing to Antarctica in 2026. We'd like to share the project as it stands now and get your feedback.

TELE1 automates seismic data collection, gathers Starlink diagnostics, and uploads everything to Dropbox. It's designed to run unattended in remote locations with minimal power and connectivity.

---

## Table of Contents

1. [System Overview](#system-overview)
2. [Hardware Requirements](#hardware-requirements)
3. [Operating System Setup](#operating-system-setup)
4. [Package Installation](#package-installation)
5. [Network and Remote Access (Tailscale)](#network-and-remote-access-tailscale)
6. [Project Structure and Deployment](#project-structure-and-deployment)
7. [Credentials and Secrets](#credentials-and-secrets)
8. [Configuration](#configuration)
9. [Verification and Testing](#verification-and-testing)
10. [Troubleshooting](#troubleshooting)

---

## System Overview

TELE1 is an automated data collection and upload system designed for remote, unattended field deployments, primarily to harvest data from seismic recorders. It:

- Collects seismic data via Pegasus Harvester
- Gathers Starlink diagnostics
- Uploads compressed archives to Dropbox via rclone
- Sends status notifications via email
- Automatically powers down when complete

This guide describes the tested system: **Ubuntu 20.04 LTS** on a **Shuttle SPCEL03** edge computer with **Starlink Mini** internet connectivity.

---

## Hardware Requirements


<img src="https://github.com/TobbeTripitaka/telemetry_setup/blob/main/img/photo_4.JPG" width="400">
Test setup (_photo: Tobias Stål_)


### Shuttle SPCEL03 Edge Computer

The Shuttle SPCEL03 was selected for its RTC (real-time clock) power-on support and general spec/price considerations.

**Product page:**  
https://au.shuttle.com/products/productsDetail?pn=SPCEL02/03&c=edge-pc

**Key features:**
- x86-64 processor (supports Ubuntu 20.04 LTS)
- RTC wake-on-alarm capability
- Multiple USB and network ports
- Compact form factor suitable for field enclosures

### Starlink Mini Connectivity

For reliable internet in remote locations without traditional infrastructure.

**Product page:**  
https://www.jbhifi.com.au/products/starlink-mini

**Power management:** In the Starlink app, turn off the snow-melting feature to reduce power consumption.

<img src="https://github.com/TobbeTripitaka/telemetry_setup/blob/main/img/photo_1.JPG" width="400">
Test setup (_photo: Tobias Stål_)

**Power regulator (12V step-down for Starlink):**  
https://campervanbuilders.com.au/products/starlink-easy-12-volt-mini-booster?variant=49807162114354

### Pelican Case Enclosure

This case is big enough, in future I'll build in a smaller enclosure.

<img src="https://github.com/TobbeTripitaka/telemetry_setup/blob/main/img/photo_2.JPG" width="400">
Test setup (_photo: Tobias Stål_)


**Product page:**  
https://www.pelican.com/ca/it/product/cases/1200?sku=1200-000-150

The Pelican 1200 case accommodates the computer, relay, Starlink unit, and associated cabling. Starlink can be mounted inside the case (foam can be carefully modified if needed—the plastic housing is reasonably transparent to satellite signals).

### Solid-State Relay

For reliable power control and equipment switching.

**Recommended model:**  
RS Components – Solid State Relay (Part 9221978)  
https://au.rs-online.com/web/p/solid-state-relays/9221978?srsltid=AfmBOoqmeamFw7_ystevtvX469QxWLCAx3F5kNwPXLLa6v4AUEZ_Z2qg

Cheaper alternatives may work equally well.

### Connectors and Cabling

Waterproof connectors and submersible equipment:

**CTALS (Australia-based supplier):**  
https://www.ctals.com.au/collections/waterproof-submersible-products

---

## Operating System Setup

### Initial Installation

1. **Install Ubuntu 20.04 LTS** on the Shuttle SPCEL03.
   - Use the 64-bit server or desktop edition
   - Default partitioning is acceptable
   - Ensure internet connectivity during installation

2. **Configure Time (UTC)**

   Set the system clock to UTC for consistency with seismometer timestamps:

   ```bash
   timedatectl set-timezone UTC
   timedatectl status
   ```

   For detailed time configuration options, see:  
   https://help.ubuntu.com/community/UbuntuTime

3. **Create User Account**

   Create the `tele` user with sudo privileges:

   ```bash
   sudo adduser --disabled-password --gecos "TELE1 Data Collection" tele
   sudo usermod -aG sudo tele
   ```

4. **Enable Graphical Autologin**

   Enable automatic login for the `tele` user so the system boots directly into a session (no password prompt):

   https://help.ubuntu.com/stable/ubuntu-help/user-autologin.html.en

   This is essential for unattended field deployments.

5. **Configure Passwordless Shutdown**

   Allow the `tele` user to power off without entering a sudo password (required for automated shutdown):

   ```bash
   sudo visudo
   ```

   Add this line at the end of the file:

   ```
   tele ALL=(ALL) NOPASSWD: /sbin/poweroff, /usr/sbin/poweroff
   ```

   Save and exit (`Ctrl+X`, then `Y`, then `Enter` in nano).

### BIOS Configuration (Shuttle SPCEL03)

1. Restart the system and enter BIOS by pressing **F2** during boot.

2. Enable **RTC (Real-Time Clock) Power-On:**
   - Navigate to Power Management or similar section
   - Enable "RTC Alarm Wake-up" or "Power-on by RTC"

3. Set **Ignition Key** for phyisical power switch if required.

4. Save and exit BIOS.

These settings ensure the node can power up automatically when mains power is restored after a shutdown or power loss—critical for field operations.

---

## Package Installation

### System Package Updates

First, update the package manager cache:

```bash
sudo apt update
sudo apt upgrade -y
```

### Install Core Dependencies

Install all required system packages in one command:

```bash
sudo apt install -y \
  bash curl jq git nodejs npm chromium-browser \
  openssh-server openssh-client systemd build-essential \
  libssl-dev libffi-dev python3-dev usb-utils
```

**Purpose of each package:**

- `bash`, `curl`: Core utilities and HTTP client
- `jq`: JSON command-line processor (for parsing Starlink diagnostics)
- `git`: Version control (to clone TELE1 repository)
- `nodejs`, `npm`: Node.js runtime and package manager (for data collection scripts)
- `chromium-browser`: Required by Puppeteer for Starlink diagnostics
- `openssh-server`, `openssh-client`: SSH for remote access
- `systemd`: Already present; included for completeness
- `build-essential`, `libssl-dev`, `libffi-dev`, `python3-dev`: Build tools (for compiling dependencies)
- `usb-utils`: USB device utilities (for hardware detection)

### Install Pegasus Harvester

The Pegasus Harvester binary must be installed at `/opt/PegasusHarvester/pegasus-harvester` and be executable.

Obtain the binary from Nanometrics and:

```bash
sudo mkdir -p /opt/PegasusHarvester
sudo cp pegasus-harvester /opt/PegasusHarvester/pegasus-harvester
sudo chmod +x /opt/PegasusHarvester/pegasus-harvester
```

Verify installation:

```bash
/opt/PegasusHarvester/pegasus-harvester --version
```

### Install rclone (Dropbox Upload)

rclone is the modern cloud synchronisation tool that replaces the legacy `dropbox_uploader.sh`. It handles all uploads to Dropbox via a secure OAuth2 connection.

**Official documentation:**  
https://rclone.org/dropbox/

#### Install rclone

Install from the official script:

```bash
curl https://rclone.org/install.sh | sudo bash
```

Verify installation:

```bash
rclone version
```

Expected output: `rclone v1.xx.x` (or newer)

---

#### Configure rclone with Dropbox

rclone requires OAuth2 authentication with Dropbox. There are **two methods** depending on whether your TELE1 node has a graphical web browser available. The broswer setup is described here:

##### Direct Browser Authentication (Desktop/Lab Setup)

If you're configuring the node on a machine with a graphical desktop and web browser (e.g., during initial lab setup before field deployment):

1. **Start the configuration wizard:**

   ```bash
   rclone config
   ```

2. **Create a new remote:**

   ```
   e/n/d/r/c/s/q> n
   ```

3. **Name the remote:**

   ```
   name> tele1_dropbox
   ```

   **Important:** The name `tele1_dropbox` must match the `RCLONE_REMOTE` variable in `tele1.sh`.

4. **Choose Dropbox as the storage type:**

   ```
   Storage> dropbox
   ```

   (Type `dropbox` or select the number corresponding to Dropbox from the list, usually around option 13-14)

5. **Leave OAuth Client ID and Secret blank:**

   ```
   client_id> [press Enter]
   client_secret> [press Enter]
   ```

6. **Skip advanced configuration:**

   ```
   Edit advanced config? (y/n)
   y/n> n
   ```

7. **Use auto config (browser authentication):**

   ```
   Use web browser to automatically authenticate rclone with remote?
   * Say Y if the machine running rclone has a web browser you can use
   * Say N if running rclone on a (remote) machine without web browser access

   y/n> y
   ```

8. **Authorise in browser:**

   rclone will automatically open your default web browser and navigate to Dropbox's authorisation page. If the browser doesn't open automatically, copy the URL shown in the terminal (e.g., `http://127.0.0.1:53682/auth?state=xxxxxxxx`) and paste it into your browser.

   - Log in to your Dropbox account
   - Click **Allow** to grant rclone access to your Dropbox

9. **Confirm the configuration:**

   After authorisation, rclone will display your Dropbox account information. Confirm:

   ```
   y) Yes this is OK (default)
   e) Edit this remote
   d) Delete this remote
   y/e/d> y
   ```

10. **Exit the wizard:**

    ```
    e/n/d/r/c/s/q> q
    ```


---

#### Verify rclone Configuration

After configuration (via either method), verify that rclone can communicate with Dropbox:

1. **List configured remotes:**

   ```bash
   rclone listremotes
   ```

   **Expected output:**

   ```
   tele1_dropbox:
   ```

2. **Test the connection by listing files in your Dropbox root:**

   ```bash
   rclone ls tele1_dropbox:/
   ```

   If your Dropbox is empty, this will return nothing. If you have files, they'll be listed.

3. **Test upload with a dummy file:**

   ```bash
   echo "TELE1 rclone test" > /tmp/rclone_test.txt
   rclone copy /tmp/rclone_test.txt tele1_dropbox:/
   ```

4. **Verify the file was uploaded:**

   ```bash
   rclone ls tele1_dropbox:/
   ```

   You should see `rclone_test.txt` listed.

5. **Clean up test file:**

   ```bash
   rclone delete tele1_dropbox:/rclone_test.txt
   rm /tmp/rclone_test.txt
   ```

If all tests pass, rclone is correctly configured and ready for TELE1 operations.

**Note:** The rclone configuration is stored in `~/.config/rclone/rclone.conf`. This file contains your Dropbox OAuth token and should be kept secure (mode `0600` is automatically set by rclone).


---

## Network and Remote Access (Tailscale)

Remote access is essential for monitoring, debugging, and reconfiguring nodes in the field. TELE1 uses **Tailscale**, a zero-configuration VPN that handles NAT traversal and provides secure point-to-point connectivity without port forwarding.

**Overview:**  
https://tailscale.com/blog/free-plan

### Install Tailscale on the TELE1 Node (Ubuntu/Starlink)

1. Install Tailscale using the official script:

   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   ```

2. Bring the node online and enable Tailscale SSH:

   ```bash
   sudo tailscale up --ssh --authkey "tskey-xxxxxxxxxxxxxxxx"
   ```

   Replace `tskey-xxxxxxxxxxxxxxxx` with an auth key generated in the [Tailscale Admin Console](https://login.tailscale.com).

   This command:
   - Starts the Tailscale daemon
   - Joins the node to your tailnet using the auth key
   - Enables SSH access over Tailscale

3. Verify connectivity:

   ```bash
   sudo tailscale status
   ```

   Output will show your node's Tailscale IP (e.g., `100.116.108.33`).

### Install Tailscale on Admin Machine (macOS)

From your administration machine (e.g., your Mac), install Tailscale to access the remote node:

1. Install Tailscale via Homebrew:

   ```bash
   brew install --formula tailscale
   ```

2. Start the Tailscale daemon:

   ```bash
   sudo brew services start tailscale
   sudo tailscale up
   ```

   Follow the login prompt to join your tailnet.

3. Check connected nodes:

   ```bash
   tailscale status
   ```

### SSH Access to TELE1 Node

Once both machines are in the same tailnet (e.g.):

```bash
ssh tele@100.116.108.33
```

Or use the node hostname if available:

```bash
ssh tele@tele1-node
```

### Copy Files from Remote Node

Download logs or data from the field node:

```bash
scp -r tele@100.116.108.33:/home/tele/tele/log ~/backups/tele1_logs_$(date +%Y%m%d)
```

### End SSH Session

```bash
exit
```

---

## Project Structure and Deployment

### Directory Layout

TELE1 uses a specific directory structure. Create it now:

```bash
sudo -u tele mkdir -p /home/tele/tele/{lib,js,log/computer,data/pegasus,config,state}
```

The final layout:

```
/home/tele/tele/
├── tele1.sh                    # Main orchestration script
├── credentials.txt             # Email and storage credentials (NOT in git)
├── lib/
│   ├── common.sh               # Shared utilities (logging, retry, cleanup)
│   ├── hardware.sh             # Hardware checks and system info
│   ├── config.sh               # Configuration loading and validation
│   ├── harvest.sh              # Pegasus data collection
│   ├── upload.sh               # rclone-based upload to Dropbox
│   ├── notification.sh         # Email notifications
│   ├── camera.sh               # Camera capture (if equipped)
│   └── remote.sh               # SSH/VNC remote access modes
├── js/
│   ├── pegasus_harvest.js      # Pegasus automation helper
│   └── starlink_get_json.js    # Starlink diagnostics collection
├── log/                        # Execution logs 
├── data/
│   └── pegasus/                # Harvested data 
├── config/                     # Local config cache
└── state/                      # State tracking (.last_run_state)
```

### Obtain TELE1 Source Code

#### Option A: Clone from Git Repository (Preferred)

Clone the TELE1 repository to your workstation first, then deploy to the node:

```bash
cd ~/projects  # or wherever you keep code
git clone https://github.com/TobbeTripitaka/telemetry_setup.git
cd tele1
```

#### Option B: Manual Directory Setup

If not using git, create all scripts manually in `/home/tele/tele/lib` and `/home/tele/tele/js`.

### Deploy Scripts to TELE1 Node

Ensure all scripts are owned by the `tele` user and are executable.

**From your repository root:**

```bash
# Copy main script
cp tele1.sh /home/tele/tele/tele1.sh
chmod 755 /home/tele/tele/tele1.sh
chown tele:tele /home/tele/tele/tele1.sh

# Copy library scripts
cp lib/*.sh /home/tele/tele/lib/
chmod 755 /home/tele/tele/lib/*.sh
chown tele:tele /home/tele/tele/lib/*.sh

# Copy JavaScript helpers
cp js/*.js /home/tele/tele/js/
chown tele:tele /home/tele/tele/js/*.js
```

### Verify Script Syntax

Check for shell syntax errors:

```bash
bash -n /home/tele/tele/tele1.sh
bash -n /home/tele/tele/lib/common.sh
# ... check each lib/*.sh file
```

---

## Credentials and Secrets

### Overview

All credentials (email passwords, Dropbox tokens) are stored in `/home/tele/tele/credentials.txt`. This file is:

- Read by `tele1.sh` at startup
- NOT included in version control
- Restricted to `tele` user only (mode `0600`)

### Create Gmail App Password

Gmail blocks insecure login attempts. Create an app-specific password instead:

1. Go to https://myaccount.google.com
2. Select **Security** (left sidebar)
3. Scroll down to **App passwords**
   - If not visible, enable 2-step verification first
4. Select **Mail** and **Linux/Other (custom name)**
5. Google generates a 16-character password (e.g., `abcd efgh ijkl mnop`)
6. Copy this password (remove spaces)

**Important:** This is NOT your Gmail password. Use this app password in `credentials.txt`.

### Create Dropbox Account and Set Up rclone

#### 1. Create a Dropbox Account

Go to https://www.dropbox.com and create an account, suggest using teh gmail address for this station.

#### 2. Generate rclone Authorisation

On the TELE1 node, initialise rclone with your Dropbox account:

```bash
rclone config
```

Follow the interactive prompts:

- **Name for new remote:** Enter `tele1_dropbox`
- **Storage to configure:** Select `dropbox` (usually option 9 or 11)
- **Use auto config?** Select **N** (no), as the node may lack a browser
- **Result:** rclone will print a link to authorise manually

On your local machine (or any machine with a browser):

1. Open the link rclone printed
2. Authorise the rclone application to access your Dropbox
3. Return to the node terminal; rclone will complete the setup

Verify rclone configuration:

```bash
rclone listremotes
```

You should see `tele1_dropbox:` in the output.

Test the connection:

```bash
rclone ls tele1_dropbox:/
```

### Create credentials.txt

Create the credentials file on the TELE1 node:

```bash
cat > /home/tele/tele/credentials.txt <<'EOF'
# TELE1 Credentials
# DO NOT commit to version control
# Store securely and outside public repositories

# Email credentials (for notifications)
EMAIL_TO="your-receiving-email@example.com"
EMAIL_FROM="your-gmail-account@gmail.com"
EMAIL_PASSWORD="abcdefghijklmnop"          # Use app password, not Gmail password
EMAIL_TIMEOUT=120

# Optional: Dropbox remote name (must match rclone config)
# RCLONE_REMOTE is set in tele1.sh, but can be overridden here if needed
EOF
chmod 600 /home/tele/tele/credentials.txt
chown tele:tele /home/tele/tele/credentials.txt
```

**Important:**
- Never commit `credentials.txt` to version control
- The file is mode `0600` (readable by `tele` user only)
- Test email credentials by examining `/home/tele/tele/log/` after a test run

---

## Configuration

### Configuration Sources

TELE1 supports both remote (Dropbox-based) and local configuration:

1. **Remote config** (preferred): Downloaded from Dropbox at each run
2. **Local config** (fallback): Embedded in the node or provided via `config.txt`

### Execution Modes

The `EXECUTE` parameter controls the behaviour after data upload:

| Mode | Behaviour | Use Case |
|------|-----------|----------|
| `auto` | Harvest, upload, notify, power down immediately | Normal unattended operation |
| `ssh` | Harvest, upload, notify, then wait for SSH access before shutdown | Remote access/debugging window |
| `clear` | As `auto`, plus delete all data and logs after upload | Data wipe mode |
| `vnc` | **Not implemented in this version**; planned for future release | Remote graphical access |

### WAIT_TIME_SSH Parameter

When using `EXECUTE=ssh`, the `WAIT_TIME_SSH` parameter specifies how many **hours** the node will remain powered on, available for SSH access.

**Important:** The computer will consume power for the entire duration specified. For example:

- `WAIT_TIME_SSH=0.5` → Node available for 30 minutes
- `WAIT_TIME_SSH=2` → Node available for 2 hours
- `WAIT_TIME_SSH=0` → No wait; power down immediately after upload

Choose `WAIT_TIME_SSH` based on:
- Your field site's battery/solar capacity
- Expected time needed for remote troubleshooting
- Power budget for your deployment

### Create Local config.txt (Dropbox Upload)

Create a local configuration file and upload it to Dropbox. This allows you to change TELE1 behaviour remotely for each run.

Create `/tmp/config.txt`:

```bash
cat > /tmp/config.txt <<'EOF'
# TELE1 Configuration
# Upload this file to Dropbox at /config.txt

# Execution mode: auto, ssh, or clear
EXECUTE=auto

# Time (hours) to wait for SSH access if EXECUTE=ssh
# Computer will consume power for this duration
WAIT_TIME_SSH=0
EOF
```

Upload to Dropbox using rclone:

```bash
rclone copy /tmp/config.txt tele1_dropbox:/
```

Verify:

```bash
rclone ls tele1_dropbox:/
```

You should see `config.txt` listed.

### Example Configurations

**Configuration 1: Unattended Field Deployment (Normal)**

```
EXECUTE=auto
WAIT_TIME_SSH=0
```

The node harvests data, uploads, sends email, and powers down immediately.

**Configuration 2: Remote Debugging (SSH Access)**

```
EXECUTE=ssh
WAIT_TIME_SSH=1
```

The node harvests data, uploads, sends email, and remains powered on for 1 hour. You can SSH in via Tailscale for diagnostics.

**Configuration 3: Data Wipe (Clean Start)**

```
EXECUTE=clear
WAIT_TIME_SSH=0
```

After successful upload, all local data and logs are deleted.

---

## Autostart Configuration (Desktop)

For deployments using graphical autostart (not recommended for unattended field use, but useful for lab/testing):

Create the autostart entry:

```bash
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/tele1.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=tele1
Comment=Run tele1 in terminal
Exec=gnome-terminal -- bash -c "/home/tele/tele/tele1.sh; exec bash"
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
```

This runs `tele1.sh` in a visible terminal after login, allowing manual inspection or cancellation if needed.

---

## Verification and Testing

### Pre-Deployment Checklist

Before sending a node to the field, verify all components:

- [ ] **System boot:** Ubuntu 20.04 LTS installed; system time set to UTC
- [ ] **User account:** `tele` user created with sudo privileges and autologin enabled
- [ ] **Shutdown:** Passwordless `sudo poweroff` works without prompts
- [ ] **BIOS:** RTC power-on and Ignition key enabled
- [ ] **Packages:** All required packages installed (`apt install` successful)
- [ ] **Pegasus:** `/opt/PegasusHarvester/pegasus-harvester` exists and is executable
- [ ] **Git:** Repository cloned or scripts manually deployed to `/home/tele/tele`
- [ ] **Script permissions:** All `.sh` files are executable and owned by `tele`
- [ ] **Tailscale:** Node online and reachable via Tailscale SSH
- [ ] **rclone:** Configured with `tele1_dropbox` remote; can list and upload to Dropbox
- [ ] **Credentials:** `credentials.txt` created (mode `0600`) with valid email and Dropbox settings
- [ ] **Config:** `config.txt` uploaded to Dropbox; default `EXECUTE=auto` and `WAIT_TIME_SSH=0`
- [ ] **Logs:** Directory `/home/tele/tele/log/computer/` is writable by `tele` user

### Manual Test Run

Run TELE1 manually to verify end-to-end operation:

```bash
sudo -u tele /home/tele/tele/tele1.sh
```

Monitor the output. Expected stages:

1. **System Preparation:** Checks dependencies and hardware
2. **Configuration Loading:** Fetches config from Dropbox (or uses defaults)
3. **Network Initialisation:** Verifies internet connectivity
4. **Data Collection:** Runs Pegasus Harvester, collects Starlink diagnostics
5. **Data Upload:** Compresses and uploads to Dropbox via rclone
6. **Notification:** Sends status email
7. **Cleanup and Shutdown:** Powers down system (with interactive prompt)

**Expected outcomes:**

- Log file created: `/home/tele/tele/log/tele1_YYYY-MM-DDTHH-MM-SS.log`
- Compressed archive uploaded to Dropbox
- Email notification received with status
- System prompts for shutdown confirmation

### Verify Uploaded Data

After test run, check Dropbox:

```bash
rclone ls tele1_dropbox:/
```

You should see files like `tele1_2026-01-09T12-34-56.tar.gz`.

### Email Notification Testing

Confirm that email settings work:

```bash
source /home/tele/tele/credentials.txt
curl --url "smtps://smtp.gmail.com:465" \
  --ssl-reqd \
  --mail-from "$EMAIL_FROM" \
  --mail-rcpt "$EMAIL_TO" \
  --user "$EMAIL_FROM:$EMAIL_PASSWORD" \
  -T /dev/null -H "Subject: TELE1 Test Email" \
  -d "This is a test message from TELE1."
```

If this succeeds silently, email is configured correctly.

### Shutdown Test

The system should prompt for shutdown at the end. Test passwordless shutdown:

```bash
sudo /sbin/poweroff
```

This should power off immediately without prompting for a password.

---

## Troubleshooting

### tele1.sh Fails to Start

**Check syntax:**

```bash
bash -n /home/tele/tele/tele1.sh
bash -n /home/tele/tele/lib/common.sh
```

**Common issues:**

- Missing library files in `/home/tele/tele/lib/`
- `credentials.txt` not found or not readable by `tele` user
- Incorrect file ownership or permissions

**Solution:**

```bash
ls -la /home/tele/tele/
ls -la /home/tele/tele/lib/
ls -la /home/tele/tele/credentials.txt
```

Verify ownership is `tele:tele` and permissions are correct.

### Pegasus Harvester Not Found

**Error:** `FATAL: Required file missing: /opt/PegasusHarvester/pegasus-harvester`

**Solution:**

```bash
ls -la /opt/PegasusHarvester/
/opt/PegasusHarvester/pegasus-harvester --version
```

If not found, re-deploy the binary and ensure it's executable.

### rclone Upload Fails

**Error in logs:** `FAILED: Harvest archive upload failed`

**Check rclone configuration:**

```bash
rclone listremotes
rclone ls tele1_dropbox:/
```

If Dropbox is unreachable:

1. Verify internet connectivity: `ping -c 1 8.8.8.8`
2. Re-authorise rclone: `rclone config`
3. Check Dropbox token hasn't expired
4. Memory full

### Email Notifications Not Received

**Check credentials:**

```bash
cat /home/tele/tele/credentials.txt
```

Ensure `EMAIL_FROM`, `EMAIL_TO`, and `EMAIL_PASSWORD` are correct.

**Test email manually:**

```bash
source /home/tele/tele/credentials.txt
echo "Test" | curl --url "smtps://smtp.gmail.com:465" \
  --ssl-reqd \
  --mail-from "$EMAIL_FROM" \
  --mail-rcpt "$EMAIL_TO" \
  --user "$EMAIL_FROM:$EMAIL_PASSWORD" \
  -T - -H "Subject: Test"
```

**Common issues:**

- Using Gmail account password instead of app password
- `EMAIL_TO` and `EMAIL_FROM` addresses are swapped
- Gmail account requires 2-step verification enabled

### No Data in Dropbox After Upload

**Check rclone logs:**

```bash
tail /home/tele/tele/log/rclone_errors.log
```

**Verify data was collected:**

```bash
ls -la /home/tele/tele/data/pegasus/
du -sh /home/tele/tele/data/pegasus/
```

If empty, Pegasus harvester may not have collected data. Check:

```bash
ls -la /opt/PegasusHarvester/
lsusb  # Check if Pegasus data logger is connected via USB
```

### Tailscale SSH Not Working

**Verify Tailscale status:**

```bash
sudo tailscale status
```

Should show your node and other devices as "active".

**Check if node is online:**

From your admin machine:

```bash
tailscale status
```

Look for the TELE1 node's Tailscale IP.

**If node is offline:**

- Check internet connectivity: `ping -c 1 8.8.8.8`
- Restart Tailscale: `sudo systemctl restart tailscaled`
- Check auth key validity (may have expired in Tailscale console)

### System Doesn't Power Off

**Check sudoers configuration:**

```bash
sudo visudo
```

Verify the line `tele ALL=(ALL) NOPASSWD: /sbin/poweroff, /usr/sbin/poweroff` is present.

**Test directly:**

```bash
sudo /sbin/poweroff
```

Should power off immediately.

### BIOS Won't Boot Automatically

**Verify BIOS settings (F2 at startup):**

- RTC power-on is **enabled**
- Ignition key is set to **power on** (not disabled)

If system still doesn't boot when AC power is restored:

- Upgrade BIOS to latest version for Shuttle SPCEL03
- Contact Shuttle support with serial number and BIOS version

---

## Next Steps

1. **Field Deployment:** Once all verification tests pass, the node is ready for deployment.

2. **Remote Monitoring:** Use Tailscale SSH to access the node remotely via your admin machine.

3. **Data Retrieval:** Download logs and raw data from Dropbox or via SCP:

   ```bash
   scp -r tele@<tailscale-ip>:/home/tele/tele/log ~/backups/
   ```

4. **Configuration Updates:** Modify `/tmp/config.txt` locally and re-upload to Dropbox to change behaviour on the next run.

5. **Support and Diagnostics:** Keep SSH access available for debugging. Check `/home/tele/tele/log/` for detailed run logs.

---

## Additional Resources

- **Ubuntu Time:** https://help.ubuntu.com/community/UbuntuTime
- **Ubuntu Autologin:** https://help.ubuntu.com/stable/ubuntu-help/user-autologin.html.en
- **Tailscale:** https://tailscale.com/blog/free-plan
- **Tailscale Admin Console:** https://login.tailscale.com
- **rclone Documentation:** https://rclone.org/
- **Shuttle SPCEL03:** https://au.shuttle.com/products/productsDetail?pn=SPCEL02/03&c=edge-pc
- **Starlink Mini:** https://www.jbhifi.com.au/products/starlink-mini

---

**End of Installation Guide**

For questions or updates, contact me. 
