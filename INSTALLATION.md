# TELE installation and field deployment guide

I built TELE to collect seismic data from remote stations where power and
internet access are limited. The idea is straightforward: wake the computer,
copy data from the Pegasus recorder, upload it to Dropbox, send a status email
and switch everything off again.

This guide brings together the hardware, suppliers, photographs and software
setup I use. I've included the practical details so that another station can
be built without having to work out the same things again.

**Updated:** 29 September 2026. The software covered here is `4.0.1`.
Record the exact code revision used for testing as described in the installation section.

> **Testing is still in progress.** Please contact me before using this update
> at an unattended field site. The automated tests pass, but the full setup
> still needs checking with the actual recorder, Dropbox connection and computer.
> In particular, test shutdown and the USB relay: starting the field service
> can switch the computer off, including when something fails.

<img src="img/GRIT%20_Final.png" width="150" alt="GRIT project logo">

## Contents

- [Before running commands](#before-running-commands)
- [About TELE](#about-tele)
- [Hardware and enclosure](#hardware-and-enclosure)
- [Assembly, cabling and power checks](#assembly-cabling-and-power-checks)
- [Station details](#station-details)
- [Configuration file map](#configuration-file-map)
- [Install and prepare Ubuntu](#install-and-prepare-ubuntu)
- [Configure BIOS wake-up and shutdown behaviour](#configure-bios-wake-up-and-shutdown-behaviour)
- [Install Ubuntu dependencies](#install-ubuntu-dependencies)
- [Obtain and verify Nanometrics Harvester](#obtain-and-verify-nanometrics-harvester)
- [Identify the Pegasus recorder safely](#identify-the-pegasus-recorder-safely)
- [Understand and test the native Harvester commands](#understand-and-test-the-native-harvester-commands)
- [Obtain and deploy a pinned TELE release](#obtain-and-deploy-a-pinned-tele-release)
- [Configure Dropbox and rclone](#configure-dropbox-and-rclone)
- [Configure local station identity](#configure-local-station-identity)
- [Configure email and protect credentials](#configure-email-and-protect-credentials)
- [Configure remote station settings](#configure-remote-station-settings)
- [Set up Tailscale and SSH](#set-up-tailscale-and-ssh)
- [Set up the private VNC desktop](#set-up-the-private-vnc-desktop)
- [Set up Starlink diagnostics](#set-up-starlink-diagnostics)
- [Install shutdown protection without activating it](#install-shutdown-protection-without-activating-it)
- [Bench testing and field activation](#bench-testing-and-field-activation)
- [Routine operation and data recovery](#routine-operation-and-data-recovery)
- [Updates, rollback and station replication](#updates-rollback-and-station-replication)
- [Troubleshooting by symptom](#troubleshooting-by-symptom)
- [Maintenance and next steps](#maintenance-and-next-steps)

Set up and test a new station on the bench, with reliable power and physical
access to the computer. If you are changing a station that is already deployed,
read the shutdown and recovery sections first.

## Before running commands

The setup uses several computers and websites. I have labelled the command
blocks so that a command meant for Ubuntu is not accidentally run on the Mac,
or a setup command is mistaken for a harmless inspection command.

| Location | What happens there |
|---|---|
| Ubuntu station | Package installation, recorder access, protected configuration and systemd |
| Mac | Source-code work, browser-assisted authorization, SSH and VNC client |
| SSH session | A terminal connected to Ubuntu; commands run on the station, not on the Mac |
| Google website | Create the station's Gmail app password |
| Dropbox website | Accept invitations, check the account and folder permissions, authorize rclone |
| BIOS | Configure and physically test wake-up and off-state USB power |

### Read a command block before pasting it

- **Prompts:** do not copy terminal prompt text such as `tele@station:~$`.
  Copy only the commands; lines beginning with `#` are explanatory comments.
- **Examples:** replace values such as `station01`, `my_dropbox_path`,
  `REPLACE_WITH_WHOLE_DISK_ID` and `ACTUAL-RUN.log` with the intended values.
  Do not type angle-bracket placeholders as shell redirection.
- **File contents:** blocks marked `ini` are settings to put in the named file
  with an editor, not shell commands. Typing `station=station01` in a terminal
  does not save `/etc/tele/config.txt`.
- **Working directory:** `pwd` shows where you are. `./harvester` means a file
  in that directory; it does not search the computer for the installed Harvester.
- **Variables:** values such as `HARVESTER`, `RECORDER_DEVICE`, `REMOTE_BASE`
  and `TELE_COMMIT` exist only in the shell where you set them. Re-establish
  them if you open another terminal or reconnect.
- **Privileges:** `sudo` is used where the Ubuntu operation needs administrator
  access. It does not make a command find the right file or choose the correct disk.
- **Failures:** stop at an error and check the cause before proceeding. Do not
  use `format`, `erase-volume`, `git reset --hard` or a broad deletion as a shortcut.
- **Secrets:** never paste passwords, OAuth tokens or private configuration into
  GitHub, support messages, screenshots or an assistant conversation.

Commands that list files or inspect status are different from commands that
upload, send email, install packages, restart services or power off. The latter
are marked in their sections; read the warning before running them.

### A quick terminal check

Use this on the terminal you are about to work in. Confirm the hostname and
current directory before editing a station's settings.

```bash
# Run on: the terminal you intend to use, Mac or Ubuntu.
hostname
whoami
pwd
```

Git manages the source repository; rclone manages Dropbox access and transfers.
TELE does not use rsync to authenticate to Dropbox, and neither a Dropbox
invitation URL nor a GitHub URL is an rclone destination path.

## About TELE

TELE runs on an Ubuntu computer connected to a Nanometrics Pegasus recorder
and Starlink. The Pegasus keeps recording while the computer is off; the
computer only needs to be awake when collecting and transmitting data.

The system has been running in Australia, and the Antarctic station has been
transmitting data since February 2026. This software update still needs its own
field checks, so I am keeping those separate from the experience with the
deployed stations.

### How I run the station

My stations wake once a week. Keeping the computer and Starlink on for longer
than necessary wastes battery power, so shutdown is part of the job, not just
something to do after a successful upload.

- **Wake schedule:** the computer wakes once a week through the BIOS arrangement.
  Record the actual supported RTC schedule and time convention for each computer.
- **Starlink switching:** USB 5 V from the computer controls a relay that
  switches Starlink power. Computer shutdown must therefore also switch Starlink off.
- **Data volume:** planning estimate up to approximately 50 MB per day.
  Actual export, diagnostic and retransmission volumes must be measured.
- **Recorder retention:** approximately three years of data before overwrite,
  in this setup. Treat this as an estimate, not a guarantee
  that a particular old interval remains available.
- **Native exports:** waveform miniSEED, SOH, legacy SOH and logs; no routine
  raw PSF image.
- **Harvest budget:** 3,600 seconds of cumulative native export time by default,
  with a bounded termination grace period.
- **Emergency limit:** poweroff is requested at four hours from boot, including
  during a remote-maintenance session.
- **Maintenance modes:** `ssh` and `vnc` wait for a default 600 idle seconds after
  collection/reporting. Detected active connections reset the idle countdown.
  `auto` does not open a maintenance waiting window.
- **Local retention:** keep complete pending uploads and, by default, the last
  verified daily export. Small progress records and recent logs also remain.
- **Remote features:** per-station Dropbox configuration, Tailscale SSH,
  private VNC, Starlink diagnostics and a bounded email attempt per run.

At the planning rate, a week of new data is roughly 350 MB before additional
overhead. A multi-year backfill is a different workload from a routine weekly
run and may need many bounded collection cycles.

### What happens on each run

```text
BIOS wakes computer
  -> USB 5 V energizes the Starlink control relay
  -> independent emergency timer is armed
  -> TELE starts and takes an exclusive lock
  -> station configuration and diagnostics
  -> retry complete pending uploads
  -> identify recorder and inspect volume ranges
  -> export required UTC days using native Harvester
  -> upload and verify Dropbox hashes
  -> acknowledge only verified intervals
  -> upload logs and attempt email
  -> optional SSH/VNC idle window
  -> systemd requests poweroff
  -> USB rail drops and Starlink relay releases
```

Check the last step physically. I need the USB power to disappear and the relay
to release, not just a log message saying that the script has finished.

### Power limits

I use a simple relay controlled by the computer's USB power to switch Starlink.
It works well in this setup, but there is no separate hardware timer to cut
power if the whole computer freezes.

The systemd timer is independent of the collection script and should still
request shutdown if that script hangs. It still depends on Ubuntu working,
so a kernel or firmware freeze remains a risk.

The standard systemd runtime hardware watchdog reboots a machine when it is not
serviced; that is not equivalent to an independent battery-saving power cutoff
([systemd watchdog documentation](https://manpages.debian.org/bookworm/systemd/systemd-system.conf.5.en.html)).
The four-hour limit is therefore a shutdown-request deadline, not a guaranteed
physical power cut.

## Hardware and enclosure

These are the parts and suppliers I used for the test setup. They are not the
only options, and some of the hardware could be made smaller or cheaper.
Check the specifications and availability before ordering, especially if you
are substituting a different power supply, relay or connector.

### Complete test arrangement

The photographs show how I arranged the computer, recorder, power components
and antenna. They should help with the layout, but check the component manuals
for wiring and electrical ratings.

<img src="img/photo_4.JPG" width="720" alt="Complete TELE test arrangement in the outer enclosure, with antenna in the lid and recorder and electronics below">

Test setup. Photo: Tobias Stål.
[Full-size photograph](https://github.com/TobbeTripitaka/telemetry_setup/blob/main/img/photo_4.JPG).

### Shuttle SPCEL03 edge computer

I chose the Shuttle SPCEL03 because it supports RTC power-on and had a reasonable
combination of specifications and price. It is a compact x86-64 computer with
the USB and network connections needed for this setup.

- **Product page:** [Shuttle SPCEL02/03](https://au.shuttle.com/products/productsDetail?pn=SPCEL02/03&c=edge-pc).
- **Deployment checks:** record exact model, serial, BIOS version, installed
  storage/RAM, DC input specification and the actual wake options available.
- **USB behaviour:** select and test a USB port whose 5 V rail powers down when
  the computer shuts down. Standby-charging settings can matter.
- **Software compatibility:** check the Nanometrics Harvester package on the
  Ubuntu release you intend to deploy.

Check the manual for the exact model, including its wake settings and power
connector. I recommend keeping a photograph of the BIOS settings with the
station record.

### Starlink Mini connectivity

I use Starlink Mini for sites without a conventional internet connection.
It only needs to be powered while the computer is uploading data or being
accessed remotely.

- **Product page:** [Starlink Mini at JB Hi-Fi](https://www.jbhifi.com.au/products/starlink-mini).
- **Power saving:** turn off the snow-melting feature in the
  Starlink app where appropriate for the deployment.
- **Wi-Fi:** disabling it may reduce consumption,
  but only do this after confirming a working wired administration/data path.
- **Site checks:** verify antenna visibility, obstruction behaviour, network
  route, service/account status and reconnect time after every power cycle.

An antenna that reconnects quickly on a warm bench may behave differently after
a week unpowered in the field. Measure cold-start readiness before choosing
network timeout and collection settings.

<img src="img/photo_1.JPG" width="720" alt="TELE inner enclosure showing the finned computer, power components and cabling">

Test setup. Photo: Tobias Stål.
[Full-size photograph](https://github.com/TobbeTripitaka/telemetry_setup/blob/main/img/photo_1.JPG).

### Starlink DC power regulator

The Starlink supply needs to suit the station's DC power system. The product
linked below is a Mini booster; check the input and output specifications for
the exact unit you buy.

- **Supplier:** [Starlink Easy 12 Volt Mini Booster](https://campervanbuilders.com.au/products/starlink-easy-12-volt-mini-booster?variant=49807162114354).
- **Alternative product link:** [Mini booster](https://campervanbuilders.com.au/products/starlink-easy-12-volt-mini-booster).
- **Before connection:** check allowable input range, required output voltage,
  connector polarity, startup current, continuous current and environmental limits
  against the exact Starlink and battery arrangement.
- **Documentation:** record the regulator model, supplier datasheet, fuse choice
  and measured startup/steady-state performance in the build record.

Do not use a photographed wiring arrangement as a substitute for the product
datasheet. Have the low-voltage power design checked by someone qualified for
the equipment and deployment environment.

### Pelican case and nested enclosure

I used a Pelican 1200 for the computer, relay, Starlink power unit and wiring.
It is more than large enough, and I would like to make the next enclosure smaller.

- **Product page:** [Pelican 1200 case](https://www.pelican.com/ca/it/product/cases/1200?sku=1200-000-150).
- **Alternate manufacturer page:** [Pelican 1200 Protector Case](https://www.pelican.com/ca/en/product/cases/protector/1200/).
  Try this if the other link does not open.

I mounted the Starlink antenna inside the lid of the outer case and modified
the foam to hold it. The results through the plastic housing have been useful,
although cutting the holder into the lid was a bit messy. There is room to
improve this.

Check reception with your own enclosure, antenna position and site conditions.
The orange inner case and grey outer enclosure in the photographs are separate
parts of the assembly; the product link above is for the Pelican 1200.

<img src="img/photo_2.JPG" width="720" alt="Open orange TELE enclosure inside the larger outer case, showing computer and cable routing">

Test setup. Photo: Tobias Stål.
[Full-size photograph](https://github.com/TobbeTripitaka/telemetry_setup/blob/main/img/photo_2.JPG).

### Solid-state relay and USB control

I chose the relay below because its specifications suited the setup. Cheaper
alternatives may work equally well, but check the control voltage and load
ratings before substituting one.

- **Supplier:** [RS Components solid-state relay, part 9221978](https://au.rs-online.com/web/p/solid-state-relays/9221978?srsltid=AfmBOoqmeamFw7_ystevtvX469QxWLCAx3F5kNwPXLLa6v4AUEZ_Z2qg).
- **Control side:** USB 5 V is the relay-control signal in this arrangement.
  It is not a proposal to supply the Starlink load directly from a USB port.
- **Switched side:** verify DC switching suitability, load current, voltage,
  polarity, leakage, heat dissipation and the equipment's startup requirements.
- **Poweroff test:** verify relay release and Starlink shutdown after a normal
  run, an early script failure and the emergency timer.

There are no software relay commands in this arrangement. The relay follows
the USB power, which is why the computer's off-state USB behaviour matters.

### Connectors, cabling and Pegasus interface

CTALS is an Australian supplier of waterproof connectors and submersible
equipment. The connector and cable layout is another part of the build I
would like to improve.

- **Supplier:** [CTALS waterproof and submersible products](https://www.ctals.com.au/collections/waterproof-submersible-products).
- **Build checks:** record connector series and pinout, use appropriate
  strain relief, protect seals and caps, and label both ends of every cable.
- **Recorder connection:** confirm the intended Pegasus USB/data interface and
  vendor cable requirements before connecting or substituting a cable.
- **Environmental checks:** verify that gland installation, cable bends and
  connector mating preserve the intended enclosure protection.

<img src="img/photo_3.JPG" width="720" alt="Close-up of the Nanometrics Pegasus recorder and its connected data cable">

Photo: Tobias Stål.

### Photograph and drawing record

The photographs and [GRIT logo](https://github.com/TobbeTripitaka/telemetry_setup/blob/main/img/GRIT%20_Final.png)
are in the repository's `img/` directory. Keep that directory with this file
so the images display correctly.

Keep originals when adding annotated wiring diagrams or later build photographs.
Review image metadata before publishing new site photographs, and label which
hardware revision each photograph represents.

## Assembly, cabling and power checks

Prepare and test the hardware on a bench before sealing the enclosure. The
software cannot compensate for unstable DC power, intermittent USB connections,
incorrect pinouts, or a relay that remains on after shutdown.

### Before energizing the assembly

- [ ] Exact computer, recorder, Starlink, regulator and relay models recorded.
- [ ] Input/output voltage, polarity and cable pinouts checked against datasheets.
- [ ] Protection/fusing and cable ratings checked for the actual supply and load.
- [ ] USB used as the specified relay-control signal, not assumed to power the dish.
- [ ] Connectors fully mated; unused connectors capped.
- [ ] Cables labelled and mechanically supported.
- [ ] No exposed conductive parts can short against the enclosure or equipment.
- [ ] Condensation, ventilation/heat transfer and ingress risks reviewed.
- [ ] Recorder power remains independent where continuous recording requires it.
- [ ] A local means of recovering from a failed configuration is available.

### Power and communications tests

Test computer boot first, then USB/recorder visibility, then relay operation and
Starlink connectivity. Repeat tests with the assembled enclosure closed; record
measured startup times and power behaviour rather than relying only on photographs.

- **Cold start:** record the time from BIOS power-on to a usable network.
- **Data connection:** verify the same recorder identity appears after multiple boots.
- **Normal shutdown:** confirm computer power state, USB rail state and relay release.
- **Failure shutdown:** repeat after an intentionally failed collection on the bench.
- **Wake recovery:** confirm the next scheduled BIOS wake still occurs.
- **Unexpected supply loss:** test only under an approved bench procedure and
  inspect filesystem/recorder recovery afterward.

Do not cut power to the recorder as an incidental consequence of a computer-only
test unless that is explicitly part of the recorder's approved operating procedure.
The goal is to save computer/Starlink power without interrupting seismic recording.

## Station details

Keep a short record for each station before starting the installation.
Store passwords and tokens separately from the general hardware and setup notes.

| Item | Record for this station |
|---|---|
| Station name | Unique `station` value in `config.txt`, such as `station01` |
| Location and operator | Site reference and responsible contacts |
| Computer | Model, serial, storage, RAM and supply specification |
| BIOS | Version, RTC setting, timezone convention, AC-restore setting |
| USB relay | Selected USB port and confirmed off-state voltage behaviour |
| Pegasus | Recorder identity, firmware, USB disk serial and whole-disk by-id path |
| Harvester | Package filename, version, source and trusted checksum |
| OS | Ubuntu release, architecture and installation date |
| TELE | Release version and exact Git commit |
| Dependencies | rclone, Tailscale, grpcurl and TigerVNC versions |
| Dropbox | Account owner, remote name, root and station prefix |
| Remote access | Tailnet, device identity, permitted users and recovery method |
| Power policy | Wake interval, harvesting budget, emergency limit |
| Data policy | Collection mode, overlap, local last-batch retention |
| Acceptance | Test results, observed poweroff and next-wake evidence |

The main guide uses `station01`, `tele_dropbox`, `my_dropbox_path` and the
`tele` Linux account as examples. Replace these deliberately and consistently;
do not use one station's Dropbox prefix for multiple independent writers.

## Configuration file map

The files below have different jobs. Do not combine all the settings into one
runtime file or put private credentials into the Dropbox `config.txt`.

| File | Purpose | Example contents |
|---|---|---|
| `/etc/tele/node.conf` | Local hardware and storage connection details | `RCLONE_REMOTE`, `DROPBOX_ROOT`, recorder serial/by-id path, Harvester path |
| `/etc/tele/config.txt` | Local startup settings and the required upload label | `station`, collection mode, maintenance window |
| `<root>/tele/<station>/config.txt` in Dropbox | Remotely adjustable operating settings | Same `station` label, mode and timeout settings |
| `/etc/tele/credentials.txt` | Email credentials only | `EMAIL_FROM`, `EMAIL_TO`, `EMAIL_PASSWORD` |
| `/etc/tele/rclone.conf` | Dropbox remote definition and OAuth tokens, maintained by rclone | Remote named by `RCLONE_REMOTE` |
| `/etc/tele/vnc/tele.passwd` | VNC password file generated by `tigervncpasswd` | Not a plain `KEY=value` file |
| `/var/lib/tele/<station>/config.txt` | Last validated downloaded configuration cache | Managed by TELE, not the main file to edit manually |

The local node, operating-settings, email and rclone files are private root-owned
files with mode 0600. The VNC file has separate ownership for its service user;
follow the VNC section rather than making all configuration files world-readable.

### One station from configuration to upload

For the worked example, use `RCLONE_REMOTE=tele_dropbox` and
`DROPBOX_ROOT=my_dropbox_path` in `node.conf`, and `station=station01` in both
operating-settings files. The rclone configuration must actually contain the
remote named `tele_dropbox`.

```text
/etc/tele/node.conf
    -> Dropbox remote and root, recorder identity, executable paths
/etc/tele/config.txt: station=station01
    -> local state: /var/lib/tele/station01/
    -> local logs:  /var/log/tele/station01/
    -> download:    tele_dropbox:my_dropbox_path/tele/station01/config.txt
                    (the downloaded station must also be station01)
    -> data:        tele_dropbox:my_dropbox_path/tele/station01/pegasus_harvester/
    -> run logs:    tele_dropbox:my_dropbox_path/tele/station01/tele_logfiles/
```

The local label is needed before Dropbox settings can be located. A remote
file with another label is rejected; changing only that remote label does not
rename a deployed station.

This example assumes a destination that the current TELE parser supports.
For a shared/team folder, complete the Dropbox discovery steps and read the
team-folder limitation below before treating the example as your actual path.

## Install and prepare Ubuntu

### Choose and record the operating system

I have used Ubuntu 20.04 LTS on this hardware. For a new installation, the target
is the latest LTS, currently 26.04.1, but check that the Nanometrics package works
on it before committing to a field deployment ([Ubuntu releases](https://releases.ubuntu.com/)).

Use the x86-64/AMD64 image appropriate to the Shuttle hardware. A server or desktop
installation can host the collection service; TELE does not require graphical
autologin to start harvesting.

I would not upgrade the operating system of an inaccessible station just to
install this software. Test on a separate computer or arrange physical access,
and keep a way back to the working setup.

On the Ubuntu station:

```bash
# Run on: Ubuntu station.
cat /etc/os-release
uname -m
hostnamectl
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS
df -h
```

Record the outputs without copying credentials or unrelated private files into
the public repository. Ensure free space for pending data, temporary exports,
the retained batch, logs and OS operations.

### Time and UTC

Set the system timezone to UTC and inspect synchronization. All collection-day
boundaries and example date ranges are UTC, not Hobart local time.

```bash
# Run on: Ubuntu station.
sudo timedatectl set-timezone UTC
timedatectl status
date -u
```

See [Ubuntu time configuration](https://help.ubuntu.com/community/UbuntuTime)
for more detail. Check the BIOS clock separately, as changing Ubuntu's displayed
timezone does not prove the wake alarm uses the time you expect.

### Linux accounts

Use an existing administrative account to provision the station. The collector
is a root-owned system service, while the `tele` account is used for permitted
remote administration and the private VNC desktop.

For a new `tele` account:

```bash
# Run on: Ubuntu station.
id tele
# If it does not exist:
sudo adduser --disabled-password --gecos "TELE Data Collection" tele
```

If `tele` also needs administrator access, add it to the `sudo` group:

```bash
# Run on: Ubuntu station.
# Optional: only if tele is intended to be a system administrator.
sudo usermod -aG sudo tele
```

A disabled account password is not a complete sudo-access plan. Establish and test
an approved administrator authentication/recovery method rather than granting
blanket passwordless sudo to make installation convenient.

### Graphical autologin and desktop choices

Graphical autologin is optional. The system service starts TELE without a desktop
login, so there is no need to enable autologin for data collection.
If you need it for another local task, see
[Ubuntu's autologin instructions](https://help.ubuntu.com/stable/ubuntu-help/user-autologin.html.en).

The VNC setup supplies a separate virtual Xfce desktop. It does
not require a physical GNOME login session and is not the same as mirroring the
computer's local screen; Ubuntu 26.04's default GNOME session is Wayland-only
([Ubuntu desktop change](https://www.theregister.com/software/2026/04/24/ubuntu-resolute-raccoon-drops-xorg-keeps-x11-apps-alive/5225331)).

### Updates and installation timing

Perform normal package maintenance on the bench with sufficient power. Do not run
a full unattended OS upgrade inside the weekly data-collection script.

```bash
# Run on: Ubuntu station.
sudo apt update
sudo apt upgrade
```

Review prompts and reboot requirements before proceeding. Record the tested
package versions so a later dependency update can be evaluated deliberately.

## Configure BIOS wake-up and shutdown behaviour

On the Shuttle, enter the BIOS with F2 during startup, enable RTC alarm wake-up
and check the ignition-key setting if you use a physical switch.
Menu names and supported schedules depend on the firmware; consult the
[Shuttle product/manual reference](https://au.shuttle.com/products/productsDetail?pn=SPCEL02/03&c=edge-pc).

### Firmware items to record

- **RTC alarm:** supported date/day/time choices and the weekly arrangement in use.
- **RTC clock convention:** whether firmware values correspond to UTC or another
  convention, and how the OS treats the hardware clock.
- **AC power restoration:** desired behaviour after supply returns. This is a
  separate setting/behaviour from an RTC alarm.
- **Ignition-key behaviour:** whether a physical switch/input is used and how it
  interacts with shutdown and subsequent wake-up.
- **USB standby power:** which port supplies the relay and whether it remains
  powered in the selected shutdown state.
- **Firmware version:** record before changing settings or applying updates.

RTC wake-up and restarting after power is restored are separate functions.
Test both if the station depends on both.

### Practical wake test

Choose a short bench interval, save the BIOS settings, shut down normally and
observe the next power-on. Repeat after testing relay release, then configure
the actual weekly schedule.

If the firmware does not expose the schedule you expect, stop and document the
limitation. Do not assume the later installer can program an unsupported BIOS
feature. Check that the intended weekly schedule really works on the computer.

Firmware updates, if needed, belong in a controlled maintenance session with the
manufacturer's recovery instructions and stable power. They are not a first
troubleshooting step on an inaccessible battery-powered station.

## Install Ubuntu dependencies

These are Ubuntu commands, not macOS commands. Run them on the bench station
using an administrative account before enabling the field service.

### Core tools

```bash
# Run on: Ubuntu station.
sudo apt install -y \
  bash coreutils findutils util-linux grep sed gawk \
  curl ca-certificates git jq rclone \
  openssh-server openssh-client \
  iproute2 procps usbutils file shellcheck
```

Check availability and record versions:

```bash
# Run on: Ubuntu station.
bash --version
rclone version
curl --version
jq --version
shellcheck --version
command -v timeout flock lsblk findmnt ss ps sha256sum
```

| Tool group | Purpose |
|---|---|
| Bash and core tools | Orchestration, time arithmetic, hashes, atomic moves, bounded commands |
| util-linux / findutils | Locks, disk discovery and controlled file enumeration |
| jq | JSON metadata and diagnostics |
| rclone | Dropbox configuration, copying and content-hash verification |
| curl / CA certificates | Authenticated TLS email and approved setup downloads |
| Git | Source retrieval and exact version control |
| OpenSSH / Tailscale | Remote access and private tunnels |
| iproute2 / procps | Network/process inspection and session detection |
| usbutils | Bench USB discovery through `lsusb` |
| ShellCheck | Local static analysis before release |

Use the Ubuntu package name `usbutils` for `lsusb`. TELE itself does not need
Node.js, npm or Chromium.

Build tools such as `build-essential`, `libssl-dev`, `libffi-dev` and
`python3-dev` are only needed if a package you are installing requires them.
There is no reason to add them all to every field computer by default.

### rclone installation alternatives

The [official rclone installer](https://rclone.org/install.sh) is an alternative
to the Ubuntu package; see the [rclone documentation](https://rclone.org/).
Whichever method you use, record the version and keep the field installation
on a version you have tested.

If you choose the official installer, download and review it before running it
with elevated permissions rather than blindly piping an internet response into
a root shell. Do not install or update rclone during an active collection.

Rclone handles both Dropbox authorization and file transfers. Keep its
configuration separate from the email credentials.

## Obtain and verify Nanometrics Harvester

The Nanometrics `.deb` is not included in this repository. Obtain it from
Nanometrics or your authorized supplier, then record the package version,
download source and trusted checksum.

Do not replace a real supplier checksum with one you computed yourself and then
call the download authenticated. A local hash is useful for recording an already
trusted package; authenticity still depends on its trusted source.

### Inspect and install the approved package

Substitute the actual local filename:

```bash
# Run on: Ubuntu station.
dpkg-deb --info /absolute/path/to/approved-pegasus-harvester.deb
sha256sum /absolute/path/to/approved-pegasus-harvester.deb
sudo apt install /absolute/path/to/approved-pegasus-harvester.deb
```

Use an absolute filename or `./filename.deb` so `apt` recognizes a local package.
Resolve package compatibility on the bench; do not guess missing libraries or
upgrade the remote OS while trying to make an unverified binary run.

### Find the native executable

Use the native executable rather than the GUI launcher. In particular, running
`sudo ./harvester help` from your home directory will not find a binary installed
under `/opt`; `sudo` does not change what `./` refers to.

On my test installation, the native executable is here:

```text
/opt/PegasusHarvester/resources/app/node_modules/@nanometrics/pegasus-harvest-lib/build/Release/harvester
```

Find the installed executable rather than assuming all package versions match:

```bash
# Run on: Ubuntu station.
sudo find /opt -type f -name harvester
```

Then inspect its own interface:

```bash
# Run on: Ubuntu station.
HARVESTER='/opt/PegasusHarvester/resources/app/node_modules/@nanometrics/pegasus-harvest-lib/build/Release/harvester'
"$HARVESTER" version -all
"$HARVESTER" help
```

Expected result: `version -all` prints version information and `help` lists
commands including `harvest` and `volume-info`. If you get “command not found”,
check the full filename and permissions; if you get a library-loading error,
check the vendor package and its Ubuntu compatibility before continuing.

The `/opt/PegasusHarvester/pegasus-harvester` executable is the GUI launcher,
not the native CLI used here. Keep the vendor's `node_modules` directory:
the native executable is installed inside it.

Keep Nanometrics' CLI documentation with the station record and check it against
the installed application's `help` output. Package versions can differ, so
verify the interface rather than assuming every option is unchanged.

## Identify the Pegasus recorder safely

Connect the recorder on the bench, then inspect all disks before selecting an
input. Do not assume `/dev/sdb` will identify Pegasus after every reboot.

```bash
# Run on: Ubuntu station.
lsusb
lsblk -o NAME,SIZE,TYPE,TRAN,SERIAL,FSTYPE,LABEL,MOUNTPOINTS
ls -l /dev/disk/by-id/
findmnt /
```

### Whole disk versus FAT partition

On my test computer, `/dev/sdb` was the whole recorder disk and `/dev/sdb1`
was its FAT32 partition labelled `PEGASUS`. The native Harvester worked with
the whole disk; using the partition produced “Partition#0 is not FAT32”.

This is evidence for the tested recorder layout, not permission to hard-code
`/dev/sdb` on another boot or computer. The station configuration requires
a whole-disk `/dev/disk/by-id/...` symlink and the expected disk serial.

The label `PEGASUS` is a useful clue, not enough on its own. Match the whole-disk
path, type and serial, and keep the Ubuntu system disk out of all recorder commands.

### Verify the chosen stable path

Replace the placeholder with the actual whole-disk identifier, not a `-part1` link:

```bash
# Run on: Ubuntu station.
RECORDER_DEVICE='/dev/disk/by-id/REPLACE_WITH_WHOLE_DISK_ID'
readlink -f "$RECORDER_DEVICE"
lsblk -dn -o NAME,TYPE,TRAN,SERIAL "$RECORDER_DEVICE"
```

The block-device type must be `disk`, its serial must match the intended recorder,
and it must not be an ancestor of the system root filesystem. A shared FAT label
or a familiar-looking UUID alone is not sufficient station identity.

If the USB bridge exposes no usable serial, do not put a made-up value into
`RECORDER_SERIAL`. The script requires one; resolve
and test an identity strategy before approving that hardware combination.

### Mounted FAT partition

The FAT partition may already be mounted, for example at `/mnt/pegasus` or
under `/run/media/<username>/PEGASUS`. Check before adding another mount,
and never put exported data into a directory on the source recorder.

The collector targets the verified whole block device. Follow vendor
guidance for concurrent recorder/USB access, and never run the GUI harvester and
the native collection job against the same recorder simultaneously.

## Understand and test the native Harvester commands

The installed binary's help is the best starting point for checking its commands.
These are the ones useful for setting up and diagnosing TELE.

| Command | Purpose and TELE use |
|---|---|
| `help` | Print supported commands and parameters |
| `version -all` | Record application and dependency versions |
| `list -safe` | Discover PSF devices; useful during bench diagnosis |
| `digitizer-info -i=... -safe` | Inspect recorder metadata |
| `volume-info -i=... -id=... -safe` | Inspect volume existence and time bounds |
| `harvest -i=... -o=... -l=... -u=... -safe` | Export native data, SOH and logs |
| `show-history -i=... -safe` | Inspect recorder harvest history; not Dropbox proof |
| `read-volume` | Advanced volume inspection; not routine station acquisition |
| `save-library` | Compact or raw PSF copy; not used for routine collection |
| `telemetry` | Separate serial telemetry interface; not the USB-disk workflow used here |

The same executable also exposes formatting, erasure, initialization,
library-loading and synthetic-data-generation commands. Do not run `format`,
`erase-volume`, `load-library`, `init-digitizer` or `generate-*` as a response to a
discovery error; they can modify recorder content and are outside this workflow.

### Inspect data categories and ranges

The Harvester identifies its data volumes as follows:

| ID | Category |
|---|---|
| 1 | Sensor time series |
| 2 | Health time series |
| 3 | Clock status |
| 4 | Health digest |
| 5 | Operation log |
| 6 | Harvest log |
| 7 | Forensic log |

For example, after identifying the recorder:

```bash
# Run on: Ubuntu station.
sudo "$HARVESTER" digitizer-info "-i=$RECORDER_DEVICE" -safe
sudo "$HARVESTER" volume-info "-i=$RECORDER_DEVICE" -id=1 -safe
sudo "$HARVESTER" volume-info "-i=$RECORDER_DEVICE" -id=2 -safe
```

Inspect the other IDs during testing as well. The script uses the
union of available positive time bounds instead of assuming waveform bounds
also cover all SOH and logs; some volumes may not expose a time range.

My test recorder did not have clock-status volume 3. The script allows that
specific missing-volume message, but other errors still need investigating,
even if the command eventually prints “Finished”.

### Default output layout and daily files

The native output pattern shown by `help` is:

```text
${Y}/${N}/${S}/${C}.D/${N}.${S}.${L}.${C}.D.${Y}.${J}
```

The symbols refer to year, network, station, channel, location and Julian day.
Other data types may have their own native outputs. Keep those paths unchanged
as well, rather than adding a separate naming scheme.

TELE deliberately does not pass `-p`. It passes `-d=24` to request daily
waveform files, because the installed CLI help lists a one-hour default even
though the native pattern contains a day number.

### Safe bench export

Start with `volume-info`, not an assumed calendar month. Choose a full UTC day
inside the range actually available on the connected recorder; a correctly
formatted date can still describe an interval with no waveform samples.

Choose a full UTC day that actually has data according to `volume-info`.
The dates below are illustrative; change them for the connected recorder and
use a fresh local test directory, never the recorder mount or production Dropbox.

```bash
# Run on: Ubuntu station.
START_UTC='2025-06-01 00:00:00 UTC'
END_UTC='2025-06-02 00:00:00 UTC'
START_SEC=$(date -u -d "$START_UTC" +%s)
END_SEC=$(date -u -d "$END_UTC" +%s)
LOWER_NS=$((START_SEC * 1000000000))
UPPER_NS=$((END_SEC * 1000000000 - 1))
BENCH_OUT="$HOME/pegasus-bench-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BENCH_OUT"
df -h "$BENCH_OUT"
```

When the input identity, dates and free space have been checked:

```bash
# Run on: Ubuntu station, on the bench. This exports data and may update recorder harvest history.
sudo timeout --signal=TERM --kill-after=10 15m "$HARVESTER" harvest \
  "-i=$RECORDER_DEVICE" "-o=$BENCH_OUT" \
  "-l=$LOWER_NS" "-u=$UPPER_NS" \
  -d=24 -safe \
  -harvestData=1 -harvestSoh=1 -harvestLegacySoh=1 -harvestLogs=1
```

`-safe` means the application's safe device-I/O mode, not a guarantee of
read-only recorder access. Observed output includes a harvest-history update;
do not call this command an operation that cannot write anything to the recorder.

Inspect the result:

```bash
# Run on: Ubuntu station.
sudo find "$BENCH_OUT" -type f -printf '%P  %s bytes\n' | head -50
sudo du -sh "$BENCH_OUT"
sudo find "$BENCH_OUT" -type f | wc -l
```

The output may be root-owned because the native command ran through sudo.
Verify waveform samples, channels, timestamps and gaps with an independent
miniSEED reader and a vendor/reference export; a nonzero file count is not
scientific completeness verification.

The 15-minute limit above is a bench safeguard, not a change to TELE's one-hour
automated harvesting budget. If the limit is reached, keep the log and treat
the export as incomplete; do not upload it over a verified daily archive.

### Check the first export before uploading

Look for completion of the individual data, SOH and log operations, not just
the final “Finished” line. These cases mean different things:

| Result | What to check next |
|---|---|
| “Ends before actual data lower time” | Choose an interval inside `volume-info` bounds |
| Only log files appear | Check whether waveform data exists in the requested interval |
| Missing clock-status volume 3 | Confirm this is the known optional-volume case for the recorder, not a different read error |
| Little console output but directory size grows | The export is still making progress; a first-element speed estimate is not useful |
| Timeout, read error or low space | Keep diagnostics, resolve the cause and repeat into a fresh test directory |
| Files and successful operation messages | Still check real miniSEED contents, day boundaries and gaps before approving the workflow |

For a quiet manual export, use a second Ubuntu terminal to check its actual
output directory:

```bash
# Run on: Ubuntu station, in a second terminal. Replace the example with the actual bench directory.
sudo du -sh /absolute/path/to/bench-output
sudo find /absolute/path/to/bench-output -type f | wc -l
```

Do not unplug the recorder or start another harvester to investigate slow
progress. Keep test output separate from the production station folder until
the export and upload checks have both passed.

### Boundary, overlap and repeated-path checks

Export two adjacent full days separately and together, then compare file lists
and sample coverage. Test midnight boundaries, records that straddle midnight,
time correction, the latest partial day and missing-data intervals.

The script rejects a native filename reused by different daily batches rather
than overwriting a potentially fuller earlier file. If SOH/log naming causes
this guard to trigger, stop and resolve the output contract; do not remove the
guard just to make an upload proceed.

Partial-hour bench files must not be copied over canonical full-day files in
production Dropbox. Keep all experiments in a separate local directory and,
if cloud testing is needed, a separate test station prefix.

### PSF images and harvest history

A raw PSF image can preserve the recorder layout, but it creates a large single
file that is awkward to upload over a limited connection. I use the Harvester's
smaller native files for routine collection, so the script does not call
`save-library`.

Recorder harvest history is not the same as upload history. The script needs
to know what has been verified in Dropbox, not just what has been read from
the recorder.

## Obtain and deploy a pinned TELE release

### Clone on the bench machine

Clone the repository onto the bench machine. The commands below create a
directory named `telemetry_setup`.

```bash
# Run on: Ubuntu station.
mkdir -p "$HOME/projects"
cd "$HOME/projects"
git clone https://github.com/TobbeTripitaka/telemetry_setup.git
cd telemetry_setup
git status --short
```

Record and pin the revision you are about to test. For a field installation,
use the exact revision that passed the bench checks, not an automatically
updated branch:

```bash
# Run on: Ubuntu station.
TELE_COMMIT=$(git rev-parse HEAD)
git checkout --detach "$TELE_COMMIT"
git rev-parse HEAD
cat VERSION
```

Record the commit you test, along with the installed package versions.
Documentation may be updated separately, so keep the guide revision with
the station record as well.

Do not automatically `git pull` a moving `main` branch on each weekly wake.
Test a specific version first and deploy it deliberately.

### Run tests before installation

These tests do not connect to a recorder, Dropbox or SMTP and do not power off
the computer. They require the local Ubuntu tools installed earlier.

```bash
# Run on: Ubuntu station.
bash tests/run.sh
shellcheck -S warning -e SC2034 \
  tele.sh lib/common.sh lib/config.sh lib/hardware.sh \
  lib/harvest.sh lib/upload.sh lib/notification.sh lib/remote.sh \
  scripts/*.sh tests/*.sh
```

SC2034 is excluded for intentional shared globals between sourced modules.
The automated tests do not replace the checks with a
real recorder, a live Dropbox connection and the station's power hardware.

### Intended runtime layout

```text
/opt/tele/
  releases/<version-and-commit>/
    tele.sh
    VERSION
    lib/
    scripts/
    systemd/
    config/
    docs/
  current -> releases/<version-and-commit>
/etc/tele/
  node.conf
  config.txt                    # local settings, including station
  credentials.txt
  rclone.conf
  vnc/tele.passwd
  FIELD_ENABLED                 # absent until explicit field activation
/var/lib/tele/<station_name>/
  pending/
  verified/
  owners/
  last-verified/
  config.txt                    # last validated remote settings
  recorder-id
/var/log/tele/<station_name>/
```

Code, runtime state and credentials are separate. Updating or rolling back code
must not delete pending exports or roll back the upload acknowledgments.

### Manual release placement

This is for a new bench installation. Do not overwrite an existing immutable
release directory; if the chosen path already exists, inspect it and select an
appropriate new release path.

```bash
# Run on: Ubuntu station.
RELEASE_DIR="/opt/tele/releases/$(cat VERSION)-${TELE_COMMIT:0:7}"
sudo install -d -m 0755 /opt/tele/releases
sudo mkdir "$RELEASE_DIR"
```

From the checked-out repository, after confirming the directory is new:

```bash
# Run on: Ubuntu station.
set -o pipefail
git archive "$TELE_COMMIT" \
  tele.sh VERSION lib scripts systemd config docs tests \
  README.md INSTALLATION.md img |
  sudo tar -x -C "$RELEASE_DIR"
sudo chown -R root:root "$RELEASE_DIR"
sudo chmod 0755 "$RELEASE_DIR/tele.sh" "$RELEASE_DIR/scripts/vnc-desktop.sh"
```

No credentials or live data should be in the source checkout. The selected
archive paths also leave out the repository's stored runtime logs.

For a new installation only, create the current link:

```bash
# Run on: Ubuntu station.
sudo ln -s "$RELEASE_DIR" /opt/tele/current
readlink -f /opt/tele/current
```

If `/opt/tele/current` already exists, use the later update/rollback procedure
instead of blindly replacing it during a running collection.

### Create configuration directories

Keep private files mode 0600 and root-owned. The top-level directory allows
traversal so the separately protected VNC subdirectory can be accessed by `tele`.

```bash
# Run on: Ubuntu station.
sudo install -d -o root -g root -m 0755 /etc/tele
sudo install -d -o root -g root -m 0700 /var/lib/tele /var/log/tele
```

Do not create `FIELD_ENABLED` yet. Do not start or enable the collector until
the identity, authentication, data and power tests have been completed.

## Configure Dropbox and rclone

Create or select the station's Dropbox account through [Dropbox](https://www.dropbox.com).
I recommend an account owned and managed for the project rather than a personal
account that happens to have access today. A station Gmail address can be used
to keep the accounts together, but the Dropbox and email identities do not
have to be the same.

Rclone uses Dropbox OAuth authorization, not a Dropbox account password in
TELE's email file. Its configuration contains sensitive token material and must
remain private ([rclone Dropbox documentation](https://rclone.org/dropbox/)).

### Choose the upload account

For an invited shared/team destination, first decide which account the field
computer should use. Ask the team administrator to approve a dedicated uploader
account and confirm any team-membership, licensing or application-policy requirements;
do not assume a generic service account or free seat is available.

1. Sign into Dropbox with that intended account in the browser.
2. Accept the invitation and, for a shared folder, use **Join folder** if needed.
3. Open the intended folder and confirm that this account can add files.
4. Authorize rclone using that same account, not a personal account already
   signed into another browser tab.
5. Test the remote and a small upload before changing an existing station.

Dropbox documents how to [join a shared folder](https://help.dropbox.com/share/add-shared-folder).
The account needs **Can edit** access to add files; **Can view** does not permit
uploads ([Dropbox sharing permissions](https://help.dropbox.com/share/set-file-folder-permissions)).

A shared link is not a substitute for folder membership or write permission.
If authorization or access is blocked by the team's policy, ask the administrator;
repeating OAuth setup cannot grant permissions the account does not have.

Do not give the station team-administrator credentials merely to make a folder
visible. Normal uploads should use the approved uploader's own access.

### What the destination setting does not protect

`DROPBOX_ROOT` tells TELE where to work; it is not an account-permission boundary.
A Dropbox app granted Full Dropbox access can have access beyond the one
directory selected in TELE ([Dropbox connected-app permissions](https://help.dropbox.com/integrations/third-party-apps)).

For this reason I prefer a project-owned account with only the required shared
data access and no unrelated personal files. If using a custom Dropbox app,
rclone's team-folder instructions require Full Dropbox rather than the restricted
App Folder access type ([rclone Dropbox setup](https://rclone.org/dropbox/)).

After testing a replacement account, retire the old credentials deliberately.
Revoking an app's access can affect other computers using that account/app, so
check those connections before disconnecting it; if credentials are compromised,
revoke them promptly rather than preserving an unsafe connection for convenience.

### Find the folder before configuring TELE

List the configured remotes on Ubuntu first. This shows remote names, not
passwords; use the name that actually exists rather than assuming the example
`tele_dropbox` is already configured.

```bash
# Run on: Ubuntu station. These commands inspect the service's rclone configuration.
sudo rclone --config /etc/tele/rclone.conf listremotes
rclone version
```

After authorizing the intended account, compare these two listings:

```bash
# Run on: Ubuntu station. Read-only listings; replace tele_dropbox if your remote has another name.
sudo rclone --config /etc/tele/rclone.conf lsd 'tele_dropbox:'
sudo rclone --config /etc/tele/rclone.conf lsd 'tele_dropbox:/'
```

For Dropbox Business, the first addresses the member's personal area, while
the leading slash in the second addresses the root containing team folders
([rclone team-folder paths](https://rclone.org/dropbox/)).
An ordinary joined shared folder may appear in the first listing.

| Destination type | Rclone example | Check before use |
|---|---|---|
| Folder in the account's normal area | `tele_dropbox:FieldData` | Correct account and folder |
| Joined shared folder | `tele_dropbox:ProjectData` | Invitation accepted, folder visible, edit permission |
| Dropbox Business team folder | `tele_dropbox:/Research Team` | Team-root listing, permitted folder, TELE limitation below |

A path with spaces must be quoted in the shell. For example, this is a direct
rclone discovery command, not a TELE configuration example:

```bash
# Run on: Ubuntu station. Read-only rclone team-folder listing; not a supported TELE root configuration yet.
sudo rclone --config /etc/tele/rclone.conf lsd 'tele_dropbox:/Research Team'
```

If a shared folder is not mounted in the account, rclone also provides
`--dropbox-shared-folders`: at the remote root it lists available shared folders,
and using a particular folder path can mount it. The `root_namespace` setting is
another advanced option, requiring the correct namespace ID and access
([rclone shared-folder options](https://rclone.org/dropbox/)).
Do not guess namespace IDs or use administrator impersonation as a routine shortcut.

### Dropbox team-folder limitation in TELE

**This is an outstanding code issue, not fixed by these documentation changes.**
The current `DROPBOX_ROOT` validation strips a leading `/` and rejects spaces,
even when the value is enclosed in quotes.

That means a direct rclone team-folder command can work while the same intended
destination is not handled correctly by TELE. In particular, stripping a team-root
slash can change which Dropbox area is addressed; a successful upload to a
similarly named personal folder would not be the intended result.

Before automated team-folder use, the path handling needs a separate reviewed
code change and tests covering the exact resulting data, log and config paths.
A namespace-rooted remote may provide another route, but it must be configured
and verified explicitly; this guide does not treat it as an already tested workaround.

Until then, use direct read-only rclone discovery and an approved small test
upload to establish access. Do not start a full automated harvest/upload to
test a doubtful destination, and do not remove path validation just to suppress
an error.

### Choose the remote and destination

The guide uses these example values:

```text
RCLONE_REMOTE=tele_dropbox
DROPBOX_ROOT=my_dropbox_path
station=station01
```

The remote/root values go in local `node.conf`; `station` goes in local and
remote `config.txt`. They are shown together here only to illustrate the path.

The resulting Dropbox layout is:

```text
my_dropbox_path/
  tele/
    station01/
      config.txt
      pegasus_harvester/
        <native Harvester paths, unchanged>
      tele_logfiles/
        <run logs and diagnostics>
        harvest/
        receipts/<recorder_serial>/
      <future_extension>/
    station02/
      config.txt
      pegasus_harvester/
      tele_logfiles/
```

An empty `DROPBOX_ROOT` places `tele/` at the remote root. `DROPBOX_ROOT` must
not include the remote name or append another `/tele/<station_name>` itself.
Use distinct station names and prefixes for distinct computers.

### Use an explicit service configuration file

Provision the rclone configuration that the root service will actually use:

```bash
# Run on: Ubuntu station.
sudo rclone --config /etc/tele/rclone.conf config
```

In the wizard:

1. Create a new remote.
2. Name it `tele_dropbox`, or your deliberately chosen `RCLONE_REMOTE`.
3. Choose backend `dropbox` by name; numeric menu positions change.
4. Normally leave client ID/secret blank unless using your own approved Dropbox app.
5. Select browser or headless authorization as appropriate.
6. Complete authorization and confirm the remote.
7. Quit the wizard and protect the file.

The client ID and client secret are application credentials, not fields for
your Google or Dropbox login password. If a working remote already exists,
inspect it rather than blindly replacing it; use a separate test remote when
authorizing a different account.

```bash
# Run on: Ubuntu station.
sudo chown root:root /etc/tele/rclone.conf
sudo chmod 0600 /etc/tele/rclone.conf
sudo stat -c '%a %U %G %n' /etc/tele/rclone.conf
sudo rclone --config /etc/tele/rclone.conf listremotes
```

An interactive user setup normally keeps its rclone file at
`~/.config/rclone/rclone.conf`. TELE instead uses the path in `node.conf`,
so make sure you configure the file that the root-run service will read.

### Browser authorization on the Ubuntu bench machine

If the bench machine has a browser, choose the browser authorization flow.
If rclone cannot launch a browser from sudo, open the local URL it actually prints
in the normal user's browser on that same machine.

The URL will look something like
`http://127.0.0.1:53682/auth?state=xxxxxxxx`. Use the actual URL printed by
the wizard, authorize Dropbox and return to the terminal
([rclone headless/browser setup](https://rclone.org/remote_setup/)).

### Headless authorization using a Mac

Keep the Ubuntu configuration wizard open while doing the browser step on the
Mac. The token is transferred back to that wizard; simply signing into Dropbox
on the Mac does not configure the edge computer.

1. **Ubuntu terminal:** run the configuration wizard with the service's explicit
   configuration file.
2. **Ubuntu wizard:** select or create the intended Dropbox remote. Answer
   **No** when asked to use a browser automatically on this headless computer.
3. **Ubuntu wizard:** leave it waiting at the token prompt and copy the exact
   `rclone authorize ...` command it prints.
4. **Mac terminal:** run that command using a browser-equipped rclone installation.
5. **Mac browser:** check the account identity and authorize the project uploader.
6. **Mac terminal:** copy the returned token JSON only, not surrounding
   instructions, shell prompts or log messages.
7. **Ubuntu wizard:** paste that JSON at the waiting token prompt, confirm the
   remote and quit the wizard.
8. **Ubuntu terminal:** check file permissions and list the remote's intended
   folder before doing any upload.

This is rclone's documented headless flow; matching rclone versions on the two
computers are recommended ([rclone remote setup](https://rclone.org/remote_setup/)).
With Homebrew already available on the Mac, install rclone if needed:

```bash
# Run on: Mac, not Ubuntu. Only install if rclone is not already available.
brew install rclone
rclone version
```

Homebrew is one of the installation methods listed by rclone
([rclone installation](https://rclone.org/install/)).
Do not update a deployed station's software mid-run merely to match the Mac;
choose compatible versions during planned setup.

For a standard remote the authorization command usually resembles this,
but the exact command printed by the Ubuntu wizard takes precedence:

```bash
# Run on: Mac. Use the exact authorize command printed by the Ubuntu wizard.
rclone authorize dropbox
```

If the browser opens your personal Dropbox account, stop and switch to the
intended project account before granting access. Use a separate browser profile
or sign-in session if that makes the choice clearer.

Treat the returned JSON as a password. Paste it directly into the Ubuntu wizard,
not into GitHub, email, a support message or an assistant conversation.

An alternative is to create the remote in a dedicated configuration file on the
Mac and securely transfer that file to `/etc/tele/rclone.conf`, then set its
owner and permissions. Do not copy a general-purpose configuration containing
unrelated cloud credentials onto the field station
([rclone configuration transfer](https://rclone.org/remote_setup/)).

### Check the result and reconnect only when needed

After the wizard completes, the intended remote name should appear in the
service configuration:

```bash
# Run on: Ubuntu station. This lists names without printing token contents.
sudo rclone --config /etc/tele/rclone.conf listremotes
```

If the remote name is missing, check which configuration file and Linux user
were used. A successful Mac authorization is not proof that the Ubuntu token
was pasted and saved successfully.

If a previously working authorization has actually been revoked, the documented
reconnect command starts OAuth again ([rclone reconnect](https://rclone.org/commands/rclone_config_reconnect/)):

```bash
# Run on: Ubuntu station, only when intentionally reauthorizing this remote.
sudo rclone --config /etc/tele/rclone.conf config reconnect tele_dropbox:
```

This changes the stored authorization. Do not use it as the first response to
a mistyped path, missing editor permission or the TELE team-path limitation.

### Create a separate upload-test folder

Use a separate Dropbox test prefix while setting up the station. Unlike the
read-only listings above, this block creates a folder if needed; it does not
start TELE or upload recorder data.

```bash
# Run on: Ubuntu station.
REMOTE_BASE='tele_dropbox:my_dropbox_path/tele/station01-test'
sudo rclone --config /etc/tele/rclone.conf mkdir "$REMOTE_BASE"
sudo rclone --config /etc/tele/rclone.conf lsf "$REMOTE_BASE"
```

An empty listing can be valid for an empty folder. Authentication or permission
errors are not equivalent to “there are no files”.

### Small upload and hash verification test

This command block intentionally writes a small test file to the chosen test
prefix. Confirm the value of `REMOTE_BASE` first; do not point it at another
station or an unrelated Dropbox folder.

```bash
# Run on: Ubuntu station.
TEST_DIR=$(mktemp -d)
mkdir "$TEST_DIR/data"
printf 'TELE bench upload test\n' >"$TEST_DIR/data/rclone-test.txt"
sudo rclone --config /etc/tele/rclone.conf copy \
  "$TEST_DIR/data" "$REMOTE_BASE/setup-test" --checksum --dropbox-batch-mode sync
sudo rclone --config /etc/tele/rclone.conf hashsum Dropbox \
  "$TEST_DIR/data" --output-file "$TEST_DIR/dropbox.sum"
sudo rclone --config /etc/tele/rclone.conf check \
  "$TEST_DIR/dropbox.sum" "$REMOTE_BASE/setup-test" \
  --checkfile Dropbox --one-way
```

The Dropbox backend supports its content hash and synchronous upload completion;
the collector relies on these rather than a filename or size alone
([rclone Dropbox integrity behaviour](https://rclone.org/dropbox/)).
One-way checking leaves unrelated destination files alone
([rclone check](https://rclone.org/commands/rclone_check/)).

After verifying the exact test destination, you may remove only the test file:

```bash
# Run on: Ubuntu station.
sudo rclone --config /etc/tele/rclone.conf deletefile \
  "$REMOTE_BASE/setup-test/rclone-test.txt"
rm -f "$TEST_DIR/data/rclone-test.txt" "$TEST_DIR/dropbox.sum"
rmdir "$TEST_DIR/data" "$TEST_DIR"
```

Do not replace that targeted deletion with a recursive purge of the station
prefix. The production collector itself does not delete Dropbox data.

## Configure local station identity

For a new installation, copy the example and edit it locally:

```bash
# Run on: Ubuntu station.
sudo install -o root -g root -m 0600 \
  /opt/tele/current/config/node.conf.example /etc/tele/node.conf
sudoedit /etc/tele/node.conf
```

Do not repeat the copy step over an already configured file. The finished file
contains literal settings like these, with real non-secret identity values:

```ini
RCLONE_REMOTE=tele_dropbox
DROPBOX_ROOT=my_dropbox_path
RECORDER_SERIAL=REPLACE_WITH_LSBLK_SERIAL
RECORDER_DEVICE=/dev/disk/by-id/REPLACE_WITH_WHOLE_DISK_ID
RCLONE_CONFIG=/etc/tele/rclone.conf
PEGASUS_BIN=/opt/PegasusHarvester/resources/app/node_modules/@nanometrics/pegasus-harvest-lib/build/Release/harvester
VNC_SERVICE=tele-vnc@tele.service
VNC_PORT=5901
```

| Setting | Meaning and constraints |
|---|---|
| `RCLONE_REMOTE` | Configured remote name without its trailing colon |
| `DROPBOX_ROOT` | Optional root prefix; no spaces, and a leading slash is currently stripped. Read the team-folder limitation before using a team-root path. |
| `RECORDER_SERIAL` | Exact trimmed serial exposed by `lsblk`; uses the same identifier character restriction |
| `RECORDER_DEVICE` | Absolute whole-disk `/dev/disk/by-id/...` link, not a partition link |
| `RCLONE_CONFIG` | Absolute protected rclone configuration path |
| `PEGASUS_BIN` | Absolute native executable path |
| `VNC_SERVICE` | Matching `tele-vnc@<user>.service` instance |
| `VNC_PORT` | Session-detection port; keep 5901 with the supplied `:1` VNC service |

Changing `VNC_PORT` alone does not reconfigure TigerVNC's listening port. Change
the service and detection configuration together, then retest.

The collector records the recorder serial in local state and refuses an
unexpected replacement. Do not delete that identity check to make a different
recorder look like the old one; plan an explicit migration or use a new station
identity/prefix when appropriate.

Recorder identity and executable/device paths are not accepted from Dropbox
`config.txt`. This keeps remotely downloaded settings from selecting an arbitrary
program or disk.

### Set the station label in config.txt

Create the private local configuration before running TELE:

```bash
# Run on: Ubuntu station.
sudo install -o root -g root -m 0600 \
  /opt/tele/current/config/config.defaults /etc/tele/config.txt
sudoedit /etc/tele/config.txt
```

Choose a unique station name and set its normal operating mode:

```ini
station=station01
EXECUTE=auto
HARVEST_MODE=incremental
HARVEST_BUDGET_SECONDS=3600
MAINTENANCE_IDLE_SECONDS=600
RETAIN_LAST_BATCH=yes
```

`station` is a lowercase key. Its value is one directory name, with 1–64 letters,
numbers, dots, underscores or hyphens and a letter/number at the start.
Spaces, slashes, empty labels and path traversal are rejected.

With the example root, this produces:

```text
my_dropbox_path/tele/station01/config.txt
my_dropbox_path/tele/station01/pegasus_harvester/
my_dropbox_path/tele/station01/tele_logfiles/
/var/lib/tele/station01/
/var/log/tele/station01/
```

The local file tells TELE which station folder to look in for remote settings.
The remote file must contain the same `station` value. A missing or different
remote label is rejected, leaving a valid matching cache or the local settings
in use; it never silently redirects uploads or reuses another station's state.

For a test station prefix, use `station=station01-test` in both copies.
The label is not the miniSEED station code and does not change Harvester filenames.
If you intentionally rename a station, follow [the state and path precautions](docs/RENAME.md)
before moving any files or acknowledgments.

## Configure email and protect credentials

### Gmail app-password setup

For `EMAIL_PASSWORD`, TELE needs a **Gmail app password**, not the Google account's
normal password. It is also not a six-digit sign-in code, a recovery code or a
Dropbox token.

Google requires 2-Step Verification for app passwords and describes them as
16-character app/device credentials ([Google app-password instructions](https://support.google.com/accounts/answer/185833?hl=en)).
Do the following in a browser on the Mac or another trusted administration computer:

1. Open [Google Account](https://myaccount.google.com) and sign into the account
   that will appear in `EMAIL_FROM`. Check the account shown in the profile menu
   if several Google accounts are signed in.
2. Open the account's security/sign-in settings and enable **2-Step Verification**
   if it is not already enabled. Complete the setup, rather than stopping after
   adding only a recovery email or phone number.
3. Open [Google App passwords](https://myaccount.google.com/apppasswords).
   Google may ask you to sign in again.
4. Create a new app password for this station. If asked for an app name, use a
   recognizable label such as `TELE station01 email`.
5. Copy the generated app password into the station's protected email file in
   the next section. If it is displayed in groups separated by spaces, enter
   the 16 characters without the display spaces.
6. Set `EMAIL_FROM` to the same account for which you generated that password.
   Set `EMAIL_TO` to the operator who should receive reports.
7. Run the separate bench email test and confirm that the message arrives
   before enabling unattended operation.

Do not paste the generated password into the terminal command line or commit
it in an example file. If you lose it or are unsure which station used it,
create a replacement, update that station's private file and retest.

### If Google does not show App passwords

Check the actual signed-in account before changing security settings. A Google
profile open in another tab may be a different account from the intended sender.

| Check | What to do |
|---|---|
| 2-Step Verification is not fully enabled | Complete it, then reopen the app-password page |
| Account is managed by work or school | Ask the account administrator whether app passwords are permitted |
| 2-Step Verification uses only security keys | Check Google's account-specific availability guidance |
| Account uses Advanced Protection | Ask for an approved supported mail arrangement rather than weakening that protection |
| The direct page opens a sign-in screen | Sign in with the intended sender account, then return to the app-password page |

Google lists managed accounts, security-key-only setups and Advanced Protection
among the reasons the option may be unavailable
([Google app-password help](https://support.google.com/accounts/answer/185833?hl=en)).
Do not disable account protection or substitute the normal Google password to
get past the problem; the current mail helper expects a supported Gmail app-password setup.


### Create the private email file

For a new installation:

```bash
# Run on: Ubuntu station.
sudo install -o root -g root -m 0600 \
  /opt/tele/current/config/credentials.txt.example /etc/tele/credentials.txt
sudoedit /etc/tele/credentials.txt
```

The file accepts these three keys:

```ini
EMAIL_FROM=station-account@gmail.com
EMAIL_TO=operator@example.com
EMAIL_PASSWORD=REPLACE_WITH_STATION_APP_PASSWORD
```

Replace the password placeholder inside `/etc/tele/credentials.txt`, using
`sudoedit`, with the generated app password. Do not edit the public
`config/credentials.txt.example` to hold your real credential.

The script supports one recipient address and Gmail SMTP. Multiple recipients
and other mail providers would need changes to the notification code; extra
configuration keys are rejected.

Use full-line comments if necessary, not an inline comment after a password.
The parser is literal data parsing: it does not expand variables, execute shell
commands or interpret a sourced credentials script.

### Inspect permissions without exposing secrets

```bash
# Run on: Ubuntu station.
sudo stat -c '%a %U %G %n' \
  /etc/tele/node.conf \
  /etc/tele/config.txt \
  /etc/tele/credentials.txt \
  /etc/tele/rclone.conf
```

Expect root ownership and mode 600 for these files. Do not print their contents
into a shared terminal recording, log, support message or Git commit.

The SMTP password is passed through a temporary private curl configuration,
not placed in the command arguments. Keep shell tracing off when working with
credentials, and do not use `source` to load a credentials file.

### Send a bench email without starting field collection

The following runs only the notification helper from the installed, trusted
code. It sends a real message to `EMAIL_TO`, creates local diagnostic/state
directories, and does not invoke the recorder or install a shutdown trap.

```bash
# Run on: Ubuntu station.
sudo bash <<'BASH'
set -Eeuo pipefail
source /opt/tele/current/tele.sh
load_node_config /etc/tele/node.conf
load_local_config /etc/tele/config.txt
init_workspace
load_credentials /etc/tele/credentials.txt
log "Explicit bench email test"
send_notification BENCH_TEST
BASH
```

Confirm the message arrived and inspect the station's local log if it did not.
Email is best effort: unavailable internet, invalid credentials or emergency
shutdown can prevent delivery even though power protection works correctly.

Expected result: the configured recipient receives an email with `BENCH_TEST`
in its subject. A missing email does not justify running the complete field
service to try again; inspect the helper's log, sender account, credential and
network while the computer is still in the controlled bench state.

### Which password or token goes where

I keep these identities separate so that a change to one account does not become
a confusing station-wide troubleshooting exercise.

| Credential | Where it is used | What to remember |
|---|---|---|
| Ubuntu login/sudo credential | Local administration or the selected SSH authentication method | Not a Dropbox or Gmail credential; test the intended administrator access |
| Google account password | Google website sign-in | Do not put it in `EMAIL_PASSWORD` |
| Gmail app password | `EMAIL_PASSWORD` in `/etc/tele/credentials.txt` | Google revokes app passwords when the Google account password changes; generate a replacement and update the station ([Google](https://support.google.com/accounts/answer/185833?hl=en)) |
| Dropbox account password | Browser sign-in during account authorization | A normal password change alone does not invalidate existing access/refresh tokens ([Dropbox API explanation](https://community.dropbox.com/en/discussion/622289/does-changing-password-to-dropbox-will-affect-the-api-key-or-token/p1)) |
| Dropbox OAuth credentials | `/etc/tele/rclone.conf`, maintained by rclone | Treat token material as a secret; app authorization is separate from the account password ([Dropbox OAuth guide](https://developers.dropbox.com/oauth-guide)) |
| Tailscale enrollment and device identity | Tailscale setup and its own protected state | Record enrollment and device-expiry policy separately; do not put either in Dropbox config |
| VNC password | The file created by `tigervncpasswd` | Separate from the Ubuntu, Google and Dropbox credentials |

In particular, **Google and Dropbox do not behave the same way when an account
password changes**. Plan a Gmail app-password replacement during maintenance
when changing the Google password; do not assume Dropbox must be reauthorized
just because its password changed.

I recommend giving each station its own named Gmail app password. If several
stations share one Google account, plan replacements for all of them when
changing that account's main password, because Google revokes the account's
app passwords ([Google password-change guidance](https://support.google.com/accounts/answer/185833?hl=en)).

Dropbox access can still be lost through app disconnection, account changes or
team-administrator action; long-term authorization is not a promise that access
can never be revoked ([Dropbox API revocation explanation](https://community.dropbox.com/en/discussion/784068/invalid-access-token-across-multiple-dropbox-team-spaces)).
After a planned account/security change, verify a harmless folder listing and
the bench email test while recovery access is still available.

Do not postpone necessary security action to preserve station access. If an
account or token is compromised, revoke it and arrange a controlled credential
replacement.

### Credential lifecycle

- **Separate credentials:** use station-specific access where practical and
  document who can revoke or replace it.
- **Dropbox:** keep refresh-token configuration private and writable only by the
  service identity so rclone can maintain authorized access.
- **Tailscale:** distinguish an enrollment auth key from the enrolled device's
  identity and access policy.
- **VNC:** use a separate VNC credential; never email it automatically.
- **Git:** commit examples, not actual private files or logs containing tokens.
- **Incident response:** revoke exposed material at the provider, replace it on
  the station through a trusted channel, and verify recovery before deployment.

I would like the installer to take one private setup file and create the
individual runtime files from it. That still needs the Dropbox authorization
material as well as the email details; email/password pairs alone are not enough.

## Configure remote station settings

Each computer reads its own Dropbox configuration:

```text
<dropbox_root>/tele/<station_name>/config.txt
```

The private `/etc/tele/config.txt` supplies the required `station` label before
the script constructs any upload or state paths. The downloaded file must
declare that same station and is validated before replacing its cache.

If download or validation fails, the script uses a matching validated cache or
the local settings. Missing/invalid local station configuration stops startup
rather than choosing a guessed upload folder. No configuration is executed as shell.

### Format rules

- **Syntax:** one literal `KEY=value` per line.
- **Comments:** blank lines and full lines beginning with `#` are allowed.
- **Quotes:** simple outer single/double quotes are accepted literally; shell
  substitutions and escapes are not evaluated.
- **Keys:** duplicate and unknown keys are rejected, not silently accepted.
- **Station key:** use lowercase `station`; the other documented keys are uppercase.
- **Size:** the file is limited to 32 KiB.
- **Dates:** whole UTC dates in `YYYY-MM-DD` format for range mode.
- **Units:** the timeout settings below are integer seconds, not hours.

### Supported settings

| Key | Default | Accepted values / effect |
|---|---|---|
| `station` | Required; no built-in label | 1–64 letters/numbers/dots/underscores/hyphens, starting with a letter/number; must match the local file |
| `EXECUTE` | `auto` | `auto`, `ssh`, `vnc` |
| `HARVEST_MODE` | `incremental` | `incremental`, `reconcile`, `reupload`, `range` |
| `REQUEST_ID` | Empty | Required for non-incremental modes; 1–80 letters, numbers, dots, underscores or hyphens |
| `FROM_DATE` | Empty | Valid `20xx-MM-DD`, required for `range` |
| `TO_DATE` | Empty | Valid later UTC date, exclusive upper day boundary for `range` |
| `MAINTENANCE_IDLE_SECONDS` | `600` | Integer 0–3600; used only in SSH/VNC modes |
| `HARVEST_BUDGET_SECONDS` | `3600` | Integer 1–3600; cumulative native export budget |
| `NETWORK_TIMEOUT_SECONDS` | `300` | Integer 10–600; bound for each rclone operation |
| `RETAIN_LAST_BATCH` | `yes` | `yes` or `no`; pending completed uploads remain in either case |
| `MIN_FREE_MIB` | `2048` | Integer 256–1048576; free-space reserve threshold |
| `OVERLAP_DAYS` | `2` | Integer 1–30; revisit recent days as well as unverified/open days |

The four-hour emergency ceiling is deliberately a local administrator-controlled
systemd setting, not a way for downloaded config to disable battery protection.
The initial config download uses the bounded timeout in the local settings.

### Normal weekly collection

```ini
station=station01
EXECUTE=auto
HARVEST_MODE=incremental
HARVEST_BUDGET_SECONDS=3600
RETAIN_LAST_BATCH=yes
```

This is the power-saving unattended mode. It does not wait for SSH/VNC after
the work and reporting stages, so request a maintenance mode before the next
wake when remote access is needed.

### SSH maintenance window

```ini
station=station01
EXECUTE=ssh
HARVEST_MODE=incremental
MAINTENANCE_IDLE_SECONDS=600
RETAIN_LAST_BATCH=yes
```

The normal idle countdown begins after the other stages finish. Detected sessions
keep resetting it; after the last detected connection ends, a fresh idle interval
must elapse before normal shutdown.

The emergency timer still applies. A disconnected-but-stale transport may be
counted conservatively as active, which is why session detection is not a
replacement for the boot-time deadline.

### VNC maintenance window

```ini
station=station01
EXECUTE=vnc
HARVEST_MODE=incremental
MAINTENANCE_IDLE_SECONDS=600
```

This requests the separately provisioned private VNC service after collection
and reporting, then uses the same idle-window logic. If VNC fails to start,
the script logs the failure and leaves the SSH waiting window open.

### Reconcile all retained data

```ini
station=station01
EXECUTE=auto
HARVEST_MODE=reconcile
REQUEST_ID=full-check-2026-09
RETAIN_LAST_BATCH=yes
```

`reconcile` re-exports the recorder's retained history and uploads missing or
changed contents, not files that already match. Keep the same request ID to
resume a long scan over multiple wakes; use a new ID to request another full scan.

### Force reupload

```ini
station=station01
EXECUTE=auto
HARVEST_MODE=reupload
REQUEST_ID=force-send-2026-09
```

`reupload` deliberately retransmits each newly processed day for that request.
Days already acknowledged for the same request are not repeatedly forced from
the start every week; recent overlap processing also avoids indefinitely forcing
the same acknowledged contents.

### Repair a date range

```ini
station=station01
EXECUTE=auto
HARVEST_MODE=range
REQUEST_ID=repair-june-october-2025
FROM_DATE=2025-06-01
TO_DATE=2025-11-01
```

This requests June through October as full UTC days, ending before 1 November.
Full-day exports protect the canonical native daily files from accidental
replacement with a shorter hour-only export.

### Upload the configuration

Prepare a file locally, check the station destination, then upload that exact
file. This example uses a test station prefix, so both the local file and the
file being uploaded must say `station=station01-test`. Switch to the real
station label and prefix together only after checking the setup.

```bash
# Run on: Ubuntu station.
REMOTE_BASE='tele_dropbox:my_dropbox_path/tele/station01-test'
sudo rclone --config /etc/tele/rclone.conf copyto \
  /absolute/path/to/config.txt "$REMOTE_BASE/config.txt" --checksum
sudo rclone --config /etc/tele/rclone.conf cat "$REMOTE_BASE/config.txt"
```

It is safe to inspect this non-secret runtime configuration, but do not put email
passwords, Dropbox tokens, Tailscale auth keys, executable paths or device paths
in it. Editing it affects a subsequent validated load, not necessarily a
collection that has already read its configuration.

## Set up Tailscale and SSH

I use Tailscale to reach the station through Starlink without opening public
inbound ports. See the [Tailscale overview](https://tailscale.com/blog/free-plan)
and [admin console](https://login.tailscale.com), and check which service plan
suits the number of stations and people who need access.

### Ubuntu installation and enrollment

Use Tailscale's current Ubuntu instructions or its stable package repository.
The documented convenience installer remains available, but a reproducible field
build should record the installed version ([Tailscale Linux installation](https://tailscale.com/docs/install/linux)).

Tailscale provides this installation command:

```bash
# Run on: Ubuntu station.
curl -fsSL https://tailscale.com/install.sh | sh
```

For a controlled build, download/review the script or follow the provider's
package-repository method before granting installation privileges. After
installation, enroll interactively on the bench:

```bash
# Run on: Ubuntu station.
sudo tailscale up
tailscale status
tailscale ip
```

Follow the actual authorization URL locally and confirm the correct tailnet and
device identity. Do not paste reusable enrollment keys into public setup logs.

### Choose the SSH path deliberately

There are two related but different ways to use SSH:

- **OpenSSH over Tailscale:** the operating system's `sshd` handles authentication,
  while the tailnet provides network connectivity.
- **Built-in Tailscale SSH:** Tailscale intercepts port 22 on the device's
  Tailscale address and authorizes access through tailnet SSH policy, rather than
  the normal OpenSSH server ([Tailscale SSH](https://tailscale.com/docs/features/tailscale-ssh)).

To enable the built-in option from a local bench session:

```bash
# Run on: Ubuntu station.
sudo tailscale set --ssh
```

Enabling it can interrupt an existing SSH connection to the Tailscale address;
maintain local recovery access while making the change
([Tailscale SSH setup](https://tailscale.com/docs/features/tailscale-ssh)).
Allow both the required network access and the intended SSH users in tailnet policy.

For ordinary OpenSSH, verify its service on the bench:

```bash
# Run on: Ubuntu station.
sudo systemctl enable --now ssh
sudo systemctl status ssh
```

Keep SSH and VNC access on the intended private network. There is no need to
open a public port or add router forwarding for this setup.

### Enrollment key expiry versus device access

An auth key used to enroll a device and the enrolled device's later key-expiry
policy are different operational concerns. Decide how the station will maintain
authorized access through long unattended intervals before deployment.

Tailscale documents disabling device key expiry for trusted continuously
connected devices, while warning that this reduces security and requires prompt
revocation if the device is lost or compromised
([Tailscale Linux key-expiry guidance](https://tailscale.com/docs/install/linux)).
Apply an explicit policy to each station rather than assuming a one-time login
will remain usable indefinitely.

### macOS administration computer

The simplest client choice is the standalone macOS app recommended by
Tailscale; sign into the same intended tailnet
([Tailscale macOS installation](https://tailscale.com/docs/install/mac)).
Do not run multiple conflicting Tailscale app/daemon variants on the Mac
([macOS variant guidance](https://tailscale.com/docs/concepts/macos-variants)).

If you prefer the command-line-only version, the Homebrew setup is:

```bash
# Run on: Mac.
brew install --formula tailscale
sudo brew services start tailscale
sudo tailscale up
tailscale status
```

Those commands correspond to the open-source daemon variant, not an instruction
to add a second daemon alongside the standalone app
([Tailscale's macOS CLI instructions](https://github.com/tailscale/tailscale/wiki/Tailscaled-on-macOS)).
The Mac only needs client connectivity to administer the Ubuntu station.

### Connect and disconnect

Use the station's actual Tailscale address or approved MagicDNS hostname:

```bash
# Run on: Mac.
ssh tele@station01
```

Replace `station01` with the name or Tailscale address shown for your computer.
Check the device identity before connecting, especially when managing several stations.

End the session normally:

```bash
# Run on: Ubuntu station, inside the SSH session; this returns you to the Mac terminal.
exit
```

In `ssh`/`vnc` mode, normal shutdown is deferred while the script detects an
active session, but the emergency deadline still wins. Test interactive shells,
file transfers, tunnels and abrupt disconnects with the installed versions.

### Retrieve protected logs

The state and log files are normally root-owned and private. Export the files
you need rather than making the entire directory readable or writable by everyone.

An authorized administrator can export a selected non-secret diagnostic file
to a temporary operator-readable location, then copy it from the Mac. For example,
replace the actual run filename before using this Ubuntu command:

```bash
# Run on: Ubuntu station.
sudo install -o tele -g tele -m 0600 \
  /var/log/tele/station01/ACTUAL-RUN.log /home/tele/tele-export.log
```

On the Mac:

```bash
# Run on: Mac.
mkdir -p "$HOME/backups"
scp tele@station01:/home/tele/tele-export.log "$HOME/backups/"
```

Review diagnostic files before sharing them publicly. Remove passwords, tokens
and any station or account information that should remain private.

## Set up the private VNC desktop

VNC gives me a graphical desktop when SSH is not enough. This setup uses a
separate virtual Xfce desktop, not a mirror of the computer's physical screen.

TigerVNC supports the standalone desktop, foreground operation, local-only
listening, password file and startup script used here
([TigerVNC Ubuntu manual](https://manpages.ubuntu.com/manpages/noble/en/man1/tigervncserver.1.html)).

### Install and prepare the desktop

On the Ubuntu bench station:

```bash
# Run on: Ubuntu station.
sudo apt install -y xfce4 tigervnc-standalone-server tigervnc-tools dbus-x11
command -v tigervncserver tigervncpasswd dbus-run-session startxfce4
```

Confirm package names/options on the selected Ubuntu release. The cited manual
documents the command interface, but the exact target combination still needs
to pass the bench tests.

Create the protected VNC password location and enter a dedicated password through
the local prompt:

```bash
# Run on: Ubuntu station.
sudo install -d -o tele -g tele -m 0700 /etc/tele/vnc
sudo -H -u tele tigervncpasswd /etc/tele/vnc/tele.passwd
sudo chown tele:tele /etc/tele/vnc/tele.passwd
sudo chmod 0600 /etc/tele/vnc/tele.passwd
```

The `/etc/tele` parent must allow directory traversal by `tele`; the credentials
files themselves remain root-owned mode 600. The VNC subdirectory/password are
private to the VNC user.

### Install the VNC unit without enabling field collection

```bash
# Run on: Ubuntu station.
sudo install -o root -g root -m 0644 \
  /opt/tele/current/systemd/tele-vnc@.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start tele-vnc@tele.service
sudo systemctl status tele-vnc@tele.service
sudo ss -ltnp | grep ':5901'
```

The template binds to localhost and uses display `:1`, normally port 5901.
Verify it is not listening on a public/wildcard interface; investigate an
unexpected binding rather than opening a firewall port.

### Connect through an SSH tunnel from the Mac

Keep this terminal open:

```bash
# Run on: Mac.
ssh -N -L 5901:127.0.0.1:5901 tele@station01
```

Then use a VNC viewer on the Mac to connect to `127.0.0.1:5901`.
For macOS Screen Sharing, this can be opened with:

```bash
# Run on: Mac.
open 'vnc://127.0.0.1:5901'
```

Enter the separate VNC password locally when prompted. If that local port is
already in use, choose another local forwarding port and point the viewer at it;
do not change the station's service port merely to resolve a Mac-side conflict.

### Complete the VNC bench test

Confirm the virtual desktop starts, input works, closing the viewer removes the
connection, and TELE's maintenance timer detects the session. Test the actual
SSH path used for the tunnel, including built-in Tailscale SSH if enabled.

Stop only the standalone VNC test service when finished:

```bash
# Run on: Ubuntu station.
sudo systemctl stop tele-vnc@tele.service
```

This command is different from stopping `tele.service`, whose exit behaviour
includes poweroff. Do not confuse the two units.

## Set up Starlink diagnostics

The script collects Starlink status with a short `grpcurl` request to the dish's
local service. This avoids running a browser just to read diagnostic information
([query example](https://rcastellotti.dev/posts/development-of-a-framework-for-retrieval-of-parameters-of-the-starlink-dish)).

### Install grpcurl deliberately

Use a trusted, versioned binary release from the
[grpcurl project](https://github.com/fullstorydev/grpcurl).
Choose the Linux architecture matching `uname -m`, obtain any published checksum
material, verify the download and record the installed version.

Do not copy a macOS/Apple Silicon binary to the x86-64 Shuttle. If building from
source instead, use the project's documented Go installation method with a
specific approved release tag rather than `@latest`; perform the build on the
bench, not during collection.

After installing the executable in the approved PATH:

```bash
# Run on: Ubuntu station.
grpcurl -version
command -v grpcurl
```

Record the release and checksum you install, and check that it works with the
station before deployment. Keep that record with the other package versions.

### Query the dish on the bench

```bash
# Run on: Ubuntu station.
timeout --signal=TERM --kill-after=5 25 \
  grpcurl -plaintext -max-time 20 -d '{"get_status":{}}' \
  192.168.100.1:9200 SpaceX.API.Device.Device/Handle
```

Confirm the station can route to that local address through its actual Starlink
network arrangement and that the output contains `dishGetStatus`. The script
treats unavailable diagnostics as nonfatal to seismic acquisition.

This is a status query, not a command to reboot, stow, reset or reconfigure the
dish. Firmware changes can alter the local interface; keep the diagnostic call
bounded and retest after a relevant firmware/network change.

## Install shutdown protection without activating it

This section installs unit files but deliberately does not arm field operation.
Read it completely before entering commands on any computer that must remain on.

### Service responsibilities

| Unit | Responsibility |
|---|---|
| `tele.service` | Runs the root collector; requests poweroff on normal/error exit through `ExecStopPost` |
| `tele-power-guard.timer` | Independent timer requesting shutdown four hours after boot |
| `tele-poweroff.service` | Issues the emergency poweroff request |
| `tele-vnc@tele.service` | Private virtual desktop, started only when requested or explicitly bench-tested |

Both the collector and emergency timer check for `/etc/tele/FIELD_ENABLED`
before starting. Leave this file absent while setting up the computer; removing
it later does not stop a service or timer that is already running.

### Copy and inspect units

```bash
# Run on: Ubuntu station.
sudo install -o root -g root -m 0644 \
  /opt/tele/current/systemd/tele.service \
  /opt/tele/current/systemd/tele-power-guard.timer \
  /opt/tele/current/systemd/tele-poweroff.service \
  /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemd-analyze verify \
  /etc/systemd/system/tele.service \
  /etc/systemd/system/tele-power-guard.timer \
  /etc/systemd/system/tele-poweroff.service
```

Verify the installed executable paths now exist and the native binary is present.
Syntax validation alone does not prove service timing or physical poweroff.

Inspect without starting the units:

```bash
# Run on: Ubuntu station.
sudo systemctl cat tele.service
sudo systemctl cat tele-power-guard.timer
sudo systemctl cat tele-poweroff.service
sudo systemctl is-enabled tele.service tele-power-guard.timer
sudo test ! -e /etc/tele/FIELD_ENABLED
```

An “inactive” or “disabled” state is expected at this point. Do not add `--now`
to an enable command while still working through setup.

### Adjust the emergency limit

The default four-hour limit is intentionally local and cannot be disabled by
downloaded station config. If an authorized administrator changes it, update
the timer and the collector limit together and repeat the power tests.

Use `sudo systemctl edit tele-power-guard.timer` and enter, for example:

```ini
[Timer]
OnBootSec=
OnBootSec=4h
```

Then use `sudo systemctl edit tele.service`:

```ini
[Service]
RuntimeMaxSec=4h
```

`OnBootSec` is measured from boot; `RuntimeMaxSec` is measured from service start.
The boot timer is the overall ceiling, not an additional four hours after an
SSH session starts.

If the computer has already been up longer than the timer's boot deadline,
starting that timer can cause an immediate shutdown request. Enable for a
deliberate fresh boot rather than arming it late during a long bench session.

### Check for duplicate startup jobs

Make sure only one job can start the collector. Check cron, systemd and desktop
autostart entries, and disable any duplicate TELE launchers without changing
unrelated jobs.

```bash
# Run on: Ubuntu station.
sudo -u tele crontab -l
sudo crontab -l
systemctl list-unit-files | grep -i tele
sudo ls -la /home/tele/.config/autostart/
```

If `/home/tele/.config/autostart/tele.desktop` exists, check what it starts.
It should not launch a second collector alongside the system service.

The root-run service does not need a passwordless poweroff rule for the `tele`
user. If you review existing sudoers rules, use `visudo` and check whether
another tool depends on a rule before removing it.

## Bench testing and field activation

Work with physical access, stable power and a separate Dropbox station prefix.
The checklist below covers the tests needed before deployment.
`docs/VALIDATION.md` has further detail about the automated and hardware tests.

### Keep the test stages separate

Do not start with the complete field service just to find out whether a password
or upload path is correct. Check each part while the computer is still under
your control.

| Stage | What runs | What it can change |
|---|---|---|
| Inspect | `pwd`, `lsblk`, `rclone lsd`, `systemctl status` | Read-only inspection; no intended data upload or shutdown |
| Local software tests | `bash tests/run.sh` and ShellCheck | Temporary local test files; no real recorder, Dropbox, email or poweroff |
| Native export test | Harvester into a fresh bench directory | Local data and possibly recorder harvest history; no cloud upload |
| Cloud/email tests | Small rclone test file and the bench email helper | The selected Dropbox test destination and a real email to `EMAIL_TO` |
| Remote-access test | Tailscale/SSH and the standalone VNC service | Access/session state, without starting the collector |
| Field run | `tele.service` with the marker and emergency timer | Recorder export, live uploads, notifications and eventual poweroff |

Before the early stages, inspect the machine's state rather than assuming that
an SSH connection means it is safe from shutdown:

```bash
# Run on: Ubuntu station. Inspection only; inactive units may return a nonzero status.
uptime
sudo systemctl status tele.service tele-power-guard.timer
sudo test ! -e /etc/tele/FIELD_ENABLED
```

If the last check fails, the activation marker exists. If a collector or timer
is already active, plan a controlled maintenance session rather than casually
stopping services or editing a running installation.

### Understand the three time limits

- **Harvest budget:** one hour of cumulative native export time by default,
  not a new hour for each daily chunk.
- **Maintenance idle window:** 10 minutes by default, only when `EXECUTE=ssh`
  or `EXECUTE=vnc`; detected sessions reset this idle countdown.
- **Emergency deadline:** four hours from boot by default, regardless of an
  active SSH/VNC session. Starting the service late does not give a fresh
  four-hour boot-timer allowance.

`EXECUTE=auto` does not wait just because an administrator has opened SSH.
Select a maintenance mode before the run if access is needed, and remember that
the emergency timer still takes priority.

`systemctl stop tele.service` can trigger its poweroff action. It is not a pause
button, and removing `FIELD_ENABLED` does not cancel an already running service
or timer. Test these behaviours with physical access before relying on them remotely.

### Before the first poweroff-capable run

- [ ] Hardware models, wiring, fusing and environmental assumptions recorded.
- [ ] Ubuntu version, architecture and Harvester compatibility checked.
- [ ] UTC and BIOS/RTC conventions documented.
- [ ] Whole recorder disk and serial confirmed after more than one reboot.
- [ ] Native command help/version saved privately.
- [ ] A real full-day export contains the expected waveform, SOH and logs.
- [ ] Adjacent-day and combined exports agree on sample coverage and native paths.
- [ ] Midnight/time-correction behaviour understood.
- [ ] No destructive recorder command is in the procedure.
- [ ] All local tests and static checks pass on the selected software version.
- [ ] Local and Dropbox `config.txt` both contain the intended matching `station`.
- [ ] Rclone uses `/etc/tele/rclone.conf`, not an accidental user configuration.
- [ ] Test Dropbox upload and explicit hash verification succeed.
- [ ] Private credentials and station identity have correct ownership/modes.
- [ ] Test email reaches the intended recipient.
- [ ] Tailscale/SSH and VNC work through the intended private access path.
- [ ] Starlink status query succeeds, or its known limitation is documented.
- [ ] Both shutdown units are installed and reviewed, but not yet enabled.
- [ ] Old GUI/autostart/cron launch paths cannot start a competing collector.
- [ ] All unrelated work has been saved and all connected users warned.

### Fault-injection tests

On the bench, demonstrate that each failure is bounded and does not falsely
acknowledge data. Restore the deliberate fault after each test.

- **No recorder:** pending completed data can still be retried; the error is reported.
- **Wrong identity:** a different disk/serial is rejected rather than harvested.
- **Interrupted export:** no incomplete scratch payload is uploaded.
- **Interrupted upload:** completed pending data survives and retries.
- **Hash mismatch:** no success checkpoint is written.
- **Disk reserve:** native acquisition stops before consuming all usable space.
- **Configuration failure:** malformed/new config does not partly replace valid settings.
- **Email failure:** does not prevent eventual shutdown.
- **Hung process:** an independent shortened bench timer requests poweroff.
- **Active sessions:** SSH/VNC defer normal idle shutdown, but not the emergency limit.
- **Disconnect:** the full idle interval restarts after the last detected connection.
- **Recorder retention advance:** any risk of overwritten unverified history is visible.

Use shortened, explicitly documented bench limits where appropriate rather than
waiting four hours for every test. Revert temporary overrides to the approved
field values and verify them before deployment.

### Explicit field-mode activation

The following steps intentionally arrange for the computer to run TELE and
power off after a subsequent boot. They are not part of merely checking out
the repository, installing dependencies or viewing the code.

Only on the intended station, after completing the checks:

```bash
# Run on: Ubuntu station.
sudo touch /etc/tele/FIELD_ENABLED
sudo chown root:root /etc/tele/FIELD_ENABLED
sudo chmod 0600 /etc/tele/FIELD_ENABLED
sudo systemctl enable tele-power-guard.timer tele.service
```

Save all work and choose a deliberate reboot time. The next command disconnects
current sessions; the machine is expected to collect and later shut down:

```bash
# Run on: Ubuntu station.
sudo systemctl reboot
```

Do not start `tele.sh` manually in place of the field service. It deliberately
requires the service context and an active emergency timer.

### Observe the run

During a requested maintenance window:

```bash
# Run on: Ubuntu station.
sudo journalctl -u tele.service -b
sudo systemctl status tele.service
sudo systemctl list-timers --all | grep tele
sudo ls -la /var/lib/tele/station01/
sudo ls -la /var/log/tele/station01/
```

Verify the station's Dropbox contents, run status and email separately.
Then physically observe poweroff and Starlink relay release, and verify the
next BIOS wake cycle.

`systemctl stop tele.service` is not a harmless “pause”: its exit path requests
poweroff. Similarly, disabling a unit without stopping it does not cancel an
already running instance; plan maintenance/disarming from a controlled state.

### Returning to a non-field bench state

When the collector is not running and physical access is available, an
administrator can remove the activation marker and disable automatic starts.
Do not interpret removing the marker alone as cancelling an already armed timer.

```bash
# Run on: Ubuntu station.
# Only in a controlled maintenance state, with no active collection:
sudo rm -f /etc/tele/FIELD_ENABLED
sudo systemctl disable tele.service tele-power-guard.timer
sudo systemctl stop tele-power-guard.timer
```

Without the guard, the computer and Starlink may remain powered. Do not leave
this bench configuration on a battery-powered remote site.

## Routine operation and data recovery

### What is kept locally

- **`pending/`:** complete frozen exports not yet fully acknowledged after upload
  and verification.
- **`verified/`:** small daily metadata receipts, not copies of the waveform archive.
- **`owners/`:** records used to detect ambiguous reuse of native paths.
- **`last-verified/`:** the last successfully verified daily batch when retention
  is enabled.
- **Cached config/identity:** last validated settings and the bound recorder serial.
- **Logs:** recent run/diagnostic files and pending log snapshots.

Incomplete `.partial-*` export scratch is never treated as upload-ready.
On recovery, the script keeps its diagnostic log, removes the incomplete
payload and leaves the day unverified so it can be harvested again.

“Keep the last batch” means one daily export, not the entire weekly run.
Keeping a week or a larger rolling cache would need an extension to the
retention code.

### What counts as uploaded

The script records Dropbox-compatible content hashes, copies data, checks the
remote against that manifest and only then writes the local acknowledgment.
A remote filename, a local file count or successful native extraction alone is
not enough.

Dropbox hash verification proves that transferred bytes match the frozen export,
not that the recorder's original measurements or the native export are scientifically
valid. Check the real miniSEED output as part of the bench testing.

### Offline runs and backlogs

If network operations fail, complete pending data remains for a later attempt.
Battery deadlines take priority over finishing the backlog or sending a message.

A very large backfill can span several weekly wakes. Keep the same request ID
to resume it; do not create a new full-reupload request each week unless you
intend to resend previously completed work.

### Lost local state or payload

If unverified payload is lost while the recorder still retains the interval,
it can be exported again. Use a fresh `reconcile` request when complete historical
repair is needed, and reserve `reupload` for intentional retransmission.

The script does not automatically reconstruct all local state from the remote
receipts. If recovery is needed, stop and check the recorder identity, destination
and available data before changing state; do not edit it during a collection.

### Changing the upload destination

An acknowledgment that data reached one Dropbox location is not proof that it
exists in another. Treat a change of account, remote root, namespace or station
label as a data-migration task, not just a cosmetic configuration edit.

1. Confirm the new account's write permission and exact destination with direct
   rclone listings and a small verified test upload.
2. Check that TELE supports that path; the team-root/space limitation described
   above must be resolved or an explicitly validated setup used first.
3. Stop changes to configuration/state while a collection is active. Arrange
   the new local settings and matching remote `config.txt` during maintenance.
4. Preserve existing pending files and the old verified archive until the new
   destination has been checked.
5. Use a fresh reconciliation request for the data still retained by Pegasus,
   rather than relying on incremental acknowledgments from the old destination.
6. Keep that request active until the intended retained history has been
   verified at the new destination, then return to normal incremental operation.

For a supported, verified new destination, the operating settings could be:

```ini
station=station01
EXECUTE=auto
HARVEST_MODE=reconcile
REQUEST_ID=destination-change-2026-09-29
```

If the label changes, a different local state directory is selected. Do not
copy old verified acknowledgments into an empty new destination and assume
they describe uploads there.

Data already overwritten on the recorder cannot be recovered by reconciliation.
If it exists only in the previous cloud archive or a retained local copy, plan
and verify that transfer separately before retiring the old storage or credentials.

### Recorder overwrite and historical corrections

The recorder's approximate three-year retention is not an unlimited backup.
If data is overwritten before any verified remote copy exists, re-harvesting
cannot recover it.

The default overlap revisits recent data, but arbitrary older timing/metadata
corrections can require a full reconciliation. Monitor actual backlog and
retention bounds rather than treating a recent success email as proof that
every historical interval remains recoverable.

### Daily/weekly operator checks

- **Wake evidence:** expected run log or notification received.
- **Upload status:** new or repaired data reached the correct station prefix.
- **Pending trend:** queue is not growing indefinitely.
- **Retention margin:** oldest unverified data remains on the recorder.
- **Disk space:** reserve is sufficient for the observed workload.
- **Power:** computer/Starlink are not unintentionally online all week.
- **Remote access:** authorization remains valid for the next maintenance window.
- **Configuration:** no stale force-reupload request or unintended maintenance mode.

If the station remains online unexpectedly, investigate before repeatedly
extending SSH/VNC access. A maintenance convenience must not silently become a
week-long battery load.

## Updates, rollback and station replication

If moving an existing installation to the TELE paths and unit names, read
[the rename checklist](docs/RENAME.md) first. Do not remove pending data or leave
two different collection services and power timers enabled.

### Pulling updates to your source checkout

Pull source updates in your working Git checkout, not in the installed
`/opt/tele/current` release. This can be a checkout on the Mac or on the Ubuntu
bench computer.

First move into the actual repository directory and inspect it. If you chose
a different clone location, substitute that path; on a Mac you can type `cd `
and drag the folder from Finder into Terminal.

```bash
# Run on: Mac or Ubuntu, in your source checkout; adjust the example directory.
cd "$HOME/projects/telemetry_setup"
pwd
git remote -v
git status --short
```

If `git status --short` lists files, stop and decide which changes to keep.
Review and deliberately commit or back up your work; do not run `git reset --hard`,
delete the checkout or stage secrets just to clear an error.

For a clean checkout:

```bash
# Run on: Mac or Ubuntu source checkout, only after checking for local changes.
git fetch origin &&
git switch main &&
git pull --ff-only origin main &&
git log -1 --oneline
```

`--ff-only` stops if local and remote history have diverged instead of silently
creating a merge ([Git pull documentation](https://git-scm.com/docs/git-pull)).
If it stops, inspect the branch/history before choosing a recovery action.

This updates the checkout only. It does not replace the installed release,
copy new systemd units, update protected credentials or activate field operation.

### Version policy

Use a reviewed Git tag or exact commit that passed the relevant tests.
Do not automatically install the newest branch contents, dependency release,
vendor package or OS during weekly acquisition.

Keep release directories immutable. Record the active release link, installed
vendor/dependency versions and the test results for each station.

### Updating code

Prepare the new release in a new root-owned directory while the collector is
not running. Test it before changing `/opt/tele/current`; do not mix some old
modules with a new `tele.sh`.

For an approved release directory already populated and checked, switch the link
atomically on Ubuntu:

```bash
# Run on: Ubuntu station.
# Replace this with the actual tested release directory.
NEW_RELEASE='/opt/tele/releases/APPROVED_VERSION_AND_COMMIT'
sudo test -x "$NEW_RELEASE/tele.sh"
sudo ln -sfn "$NEW_RELEASE" /opt/tele/current.next
sudo mv -Tf /opt/tele/current.next /opt/tele/current
readlink -f /opt/tele/current
```

Stop on any failed check rather than continuing the block blindly.
If service templates changed, review/copy them deliberately and reload systemd;
do not assume switching a source symlink updates already installed unit files.

### Rollback

Roll back only to a known compatible code release. Preserve `/etc/tele`,
pending data, verified receipts and recorder identity instead of replacing the
whole application/state tree with an old backup.

Check state-format compatibility before rolling back code. A rollback is only
useful if the selected release can read the station's existing state safely.

### Replicating a station

- **Unique identity:** choose a new station name, computer hostname and Dropbox prefix.
- **Recorder binding:** discover the actual by-id path and serial on that node.
- **Credentials:** enroll and authorize deliberately; do not clone unrelated secrets.
- **Tailscale:** enroll the device as its own identity, not a duplicate live daemon state.
- **State:** start with an empty station-specific state tree unless performing an
  explicit replacement/migration.
- **Power:** repeat BIOS, USB relay and shutdown tests on every computer.

Hardware that looks identical can have different firmware settings or USB power
behaviour. A passed test on station01 is not sufficient evidence for station02.

## Troubleshooting by symptom

### TELE does not start

Inspect the service journal, activation marker and installed files:

```bash
# Run on: Ubuntu station.
sudo journalctl -u tele.service -b
sudo systemctl cat tele.service
sudo ls -l /etc/tele/FIELD_ENABLED /opt/tele/current/tele.sh
sudo bash -n /opt/tele/current/tele.sh
```

Expected causes include a deliberately absent activation marker, missing code,
wrong private-file ownership, unsupported configuration keys or unavailable
dependencies. The field service may request shutdown after startup failure,
so diagnose on a controlled bench rather than repeatedly guessing remotely.

### Native Harvester is missing or will not load

```bash
# Run on: Ubuntu station.
sudo find /opt -type f -name harvester
file /opt/PegasusHarvester/resources/app/node_modules/@nanometrics/pegasus-harvest-lib/build/Release/harvester
```

Verify the vendor package, CPU architecture, executable permissions and required
libraries. Do not confuse the Electron GUI launcher with the native executable;
record the actual package error rather than silently changing paths.

### “Partition#0 is not FAT32” or “not a PSF library”

Recheck whether the input is the whole recorder disk or only its FAT partition.
Also verify that the by-id link still identifies the intended recorder.

Do not format the disk just because the error message suggests it.
Check the input device first; using the FAT partition instead of the whole
recorder disk can produce this error.

### Recorder identity mismatch

Inspect `lsblk`, the by-id symlink, the expected serial in `node.conf` and the
recorded identity in the station state. A changed USB bridge or recorder may be
a real replacement requiring an explicit migration.

Do not delete the check or point at whichever `/dev/sdX` happens to exist.
If the setup exposes no stable serial, resolve that hardware/identity limitation
before unattended operation.

### Harvest appears slow or frozen

In my manual test, the logs finished quickly and SOH took longer, but the output
folder kept growing. The first progress line is not a useful speed estimate
when only one element has been processed.

For a manual bench export, monitor the local test folder from another terminal:

```bash
# Run on: Ubuntu station.
sudo du -sh /absolute/path/to/bench-output
sudo find /absolute/path/to/bench-output -type f | wc -l
```

Do not unplug the recorder or launch a second harvester to test whether the
first is busy. The automated script has a timeout and free-space check;
inspect the harvest log if it stops.

### Harvest generated files but data seems absent

Logs and SOH can exist even when the requested waveform interval has no samples.
Compare the requested nanosecond range with `volume-info`, inspect native
operation status messages and validate the actual waveform files.

An out-of-range export can still produce a log file without any waveform data.
Check the data itself rather than relying on the number of files created.

### Native path collision

The script stops when two different daily exports use the same
native relative path with ambiguous contents. This may expose a SOH/log naming
or boundary behaviour that requires a different validated export strategy.

Preserve the two export listings/logs for investigation. Do not disable the
guard or upload the shorter file over a previously complete one.

### Dropbox authentication, permissions or quota failure

```bash
# Run on: Ubuntu station.
sudo rclone --config /etc/tele/rclone.conf listremotes
sudo rclone --config /etc/tele/rclone.conf lsf \
  'tele_dropbox:my_dropbox_path/tele/station01'
```

Check the exact account, app scope, remote name, destination, provider quota
and authorization state. Reauthorize with the intended private config file;
do not create a second working desktop-user config and assume the service uses it.

Basic `ping -c 1 8.8.8.8` and `ping -c 1 1.1.1.1` checks
can help diagnose general connectivity, but successful ICMP does not prove
Dropbox DNS, TLS, authentication or permissions.

### Upload hash verification fails

Retain pending data and inspect the manifest, local disk health and remote result.
Do not mark the interval uploaded, delete the queue or fall back to a size-only
comparison just to obtain a success state.

Use a separate controlled test to distinguish local mutation, an interrupted
transfer and a backend/configuration problem. A new reconciliation may repair
missing or changed content once the underlying fault is understood.

### Disk space runs low

```bash
# Run on: Ubuntu station.
df -h /var/lib/tele /var/log/tele
sudo du -sh /var/lib/tele/station01/pending
sudo du -sh /var/lib/tele/station01/last-verified
sudo du -sh /var/log/tele/station01
```

Find out whether space is held by pending exports, incomplete scratch, logs,
retained data or unrelated OS files. Do not indiscriminately clear pending or
verified-state directories; those are part of recovery correctness.

Reduce avoidable data churn through `incremental`/`reconcile` instead of
repeated `reupload` requests. Reassess the reserve and storage capacity using
measured export sizes.

### Email is not received

Inspect protected-file permissions and the run log without printing passwords.
Check sender/recipient addresses, the Gmail app password, account restrictions,
network readiness and the recipient's spam/quarantine rules.

Use the bench email test in the email section. Keep credentials out of command
arguments, shared logs and public support messages.

| Symptom | First check |
|---|---|
| Google does not offer App passwords | Correct account, completed 2-Step Verification and account-policy restrictions |
| Mail authentication rejected | `EMAIL_FROM` matches the account that generated the app password |
| Mail stopped after a Google password change | Generate a replacement app password and update the station's private file |
| Test seems to succeed but no message is visible | Correct `EMAIL_TO`, spam/quarantine, and the run log |
| Credentials file rejected | Only the supported keys, no inline password comments, root ownership and mode 0600 |

Do not solve a mail-only problem by replacing the Dropbox token. The providers
and credential files are separate.

### Starlink diagnostics fail but data uploads work

Inspect routing to `192.168.100.1:9200`, grpcurl installation and the response
format. Firmware/local API behaviour can change independently of general
internet access.

The collector records this as a diagnostic problem and continues with data
collection. Keep troubleshooting to status queries; do not reset or reconfigure
the dish just to investigate a failed reading.

### Tailscale or SSH is unavailable

On the Ubuntu bench station:

```bash
# Run on: Ubuntu station.
tailscale status
tailscale ip
sudo systemctl status tailscaled
sudo systemctl status ssh
```

On the Mac, confirm the intended tailnet/device is visible and use the correct
hostname/IP and Linux username. For built-in Tailscale SSH, inspect both network
and SSH access policy; for OpenSSH, inspect its own authentication configuration.

An expired enrollment key is not necessarily the cause of an already enrolled
device going offline. Check device key expiry, policy, internet readiness and
whether the station is simply powered off as designed.

### VNC is unavailable

```bash
# Run on: Ubuntu station.
sudo systemctl status tele-vnc@tele.service
sudo journalctl -u tele-vnc@tele.service -b
sudo ss -ltnp | grep ':5901'
sudo stat -c '%a %U %G %n' /etc/tele/vnc /etc/tele/vnc/tele.passwd
```

Check the dedicated password file, parent-directory traversal, virtual-desktop
dependencies and startup script. Verify the Mac SSH tunnel before changing
server settings; never fix a tunnel problem by exposing VNC publicly.

### Computer does not power off

Inspect the collector's exit behaviour and the independent timer:

```bash
# Run on: Ubuntu station.
sudo systemctl status tele-power-guard.timer
sudo systemctl list-timers --all | grep tele
sudo journalctl -u tele.service -u tele-poweroff.service -b
```

During an explicit bench test with all work saved, direct poweroff can be tested:

```bash
# Run on: Ubuntu station.
# This immediately requests shutdown of the computer where it is run.
sudo /sbin/poweroff
```

The collector runs as root, so its shutdown does not depend on the `tele`
user's sudo permissions. If shutdown is requested but the computer or USB rail
remains powered, check the firmware and hardware behaviour as well.

### Computer shuts down immediately when a timer is started

Check the uptime and boot-relative emergency deadline. Starting a timer after
its `OnBootSec` deadline has already elapsed is different from giving the
computer a fresh four-hour session.

Use a planned new boot after enabling the approved field units. Do not repeatedly
extend or restart timers remotely without understanding the battery consequences.

### BIOS does not wake the station

Review the recorded alarm settings, firmware clock, ignition-key behaviour and
AC-restoration policy separately. Verify the last shutdown state and whether
the station actually had the required supply available at the alarm time.

If necessary, contact Shuttle support with the model, serial number and BIOS
version. Apply firmware updates on the bench with reliable power and a recovery
plan, not as an unplanned change to an inaccessible station.

## Maintenance and next steps

### What to keep for every deployment

Keep the wiring record, component manuals, supplier references, original and
annotated photographs, BIOS screenshots, code/package versions, non-secret
configuration, test results and a recovery contact.

Keep private credential material separately. Diagnostic bundles should identify
the station and software version without exposing tokens, passwords or
unnecessary account information.

### Installation script

Once the software has been properly tested, I want to make an installation
script that downloads it from GitHub and handles the Ubuntu setup. Ideally,
the only input will be a private text file containing the station settings
and credentials.

The installer will need to cover the following:

- **Source:** obtain a pinned approved GitHub release with integrity checking.
- **OS setup:** install approved dependencies and configure the required users,
  directories and services without an unplanned full OS upgrade.
- **Private input:** read one protected provisioning file if desired, then split
  secrets and non-secret station identity into protected runtime files.
- **Nanometrics:** install an authorized vendor package with a known version and
  trusted checksum, using a download/distribution method permitted by the vendor.
- **Cloud authorization:** import valid Dropbox OAuth configuration and enroll
  Tailscale deliberately; email passwords alone are insufficient.
- **Validation:** check device identity, paths, hashes, service syntax and access.
- **Versions:** support immutable releases and rollback without deleting state.
- **Activation:** require a distinct, explicit lab-to-field activation step.
- **BIOS:** present the physical wake/USB-power checklist unless an actual
  supported firmware-management interface is established.

I want setup to be easier without making it easier to switch off the wrong
computer or lose data. Field activation should remain a separate step, with
credentials kept private and the recorder left intact.

### Additional documentation within this repository

`docs/DESIGN.md` explains how the collection and recovery work,
`docs/VALIDATION.md` covers the tests, and `docs/REVIEW_SUMMARY.md` records
the software review.

I would like this guide to remain useful as a complete set of build and setup
notes, including the hardware links and photographs. If you build a station
or find something that can be improved, please get in touch.
