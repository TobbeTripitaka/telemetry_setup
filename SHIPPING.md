# Shipping TELE computers with Ubuntu only

This is the handover procedure for computers shipped before the TELE software
has been installed. Ubuntu is already installed; a technician will complete
software installation, configuration and testing before field deployment.

Long time might pass between preparation and deployment. A computer that passes the shipping checks below
is ready for the technician, not yet ready for an unattended station.

Updated: 14 October 2026.

## What “uninstalled” means

The intended shipping state is:

- **Operating system:** Ubuntu installed and able to boot, with a known local
  administrator account.
- **Networking:** ordinary Ethernet internet access checked where possible.
  A site-specific network configuration is not required for shipping.
- **TELE:** installation and field activation left to the technician.
- **Nanometrics:** the approved Harvester package may still need to be obtained
  and installed; recorder access has not necessarily been tested.
- **Accounts:** Dropbox, Gmail, Tailscale and VNC authorization/configuration
  need not be present on the shipping computer.
- **Power control:** no working TELE automatic-shutdown protection should be
  assumed on an Ubuntu-only computer.

Record the actual state of each machine rather than assuming they are identical.
If software or services have already been installed on a particular unit, note
that exception in its private handover record.

**An Ubuntu-only computer must not be left on the field battery expecting TELE
to switch it off.** Leave recurring unattended wake-up inactive while connected
to a battery until the collector and shutdown protection have been installed
and tested.

### Check the administrator login

Log in using the account the technician will use. Confirm its username and
password, and test administrator access from a terminal:

```bash
# Run on: the Ubuntu computer being shipped.
whoami
sudo true
```

The second command should complete successfully, asking for the current user's
password if authentication is needed. Ubuntu authorizes sudo access through
the sudo group, and an authorized user normally authenticates with their own
password, not a separate root password
([Ubuntu user-management documentation](https://documentation.ubuntu.com/server/how-to/security/user-management/)).

- **Existing account:** use the working administrator account; there is no need
  to rename it to `tele` just for shipping.
- **Password delivery:** send the login password through a separate secure
  channel, not on an external label, in this repository or in a public issue.
- **Firmware access:** if a BIOS/UEFI password is set, arrange secure access for
  the technician as well.
- **Temporary access:** agree which temporary credentials should be changed or
  removed before final deployment.


### Test shutdown and cold boot

Save any work, shut down normally, and power the computer on again. Confirm that
Ubuntu reaches its normal login screen rather than a recovery menu or installation
prompt.

- **Normal login screen:** acceptable; TELE does not require graphical autologin.
  Do not enable desktop autologin just for the technician.
- **Disk-unlock prompt:** record it and provide the unlock/recovery details
  securely so the technician can boot the machine.
- **Unattended operation:** an interactive pre-boot unlock requirement must be
  resolved as part of the field deployment design.
- **Encryption changes:** do not remove encryption or reinstall Ubuntu in a rush
  merely to simplify shipping.

Do not start a major OS upgrade or firmware update immediately before packing.
If updates are already underway, let them finish and check a reboot before
declaring the machine ready to ship.

### Check Ethernet and internet

Connect an Ethernet cable to an ordinary working network and open the
[TELE repository](https://github.com/TobbeTripitaka/telemetry_setup). Record any
adapter, cable or network issue that the technician will need to resolve.

Keep networking simple, normally using the network's automatic address
configuration unless an agreed site plan requires otherwise. Do not disable
the firewall or expose SSH/VNC publicly as a shipping shortcut.

Remote-access software is optional at this stage. If it is already configured,
record what was actually tested; otherwise the technician can set it up during
installation.

### Label the machine and record its identity

Use a clear physical asset label such as `TELE-PC-01`, `TELE-PC-02` or
`TELE-PC-03`. Label the matching power supply and any machine-specific adapters
so they remain together.

The asset label is not necessarily the final TELE `station` value. The station
label controls the later upload/state namespace and can be assigned during
software configuration.

Useful details can be collected without installing TELE:

```bash
# Run on: the Ubuntu computer being shipped. These commands inspect the system.
hostname
whoami
cat /etc/os-release
uname -m
```

Record the computer's model and serial from its label as well. Save the output
or a photograph in the private handover record, not alongside real passwords
in a public repository.

### Check the physical power arrangement if available

The intended field arrangement uses computer USB 5 V to operate the relay
supplying Starlink. Computer shutdown must therefore release the relay and
remove Starlink power.

- **Relay test:** if the relay and antenna are available, observe a normal
  shutdown and confirm that Starlink power is actually removed.
- **USB port:** identify the port intended to control the relay; do not assume
  all ports behave the same after shutdown.
- **Firmware record:** photograph the BIOS/UEFI wake, USB standby-power,
  power-restoration and relevant ignition settings.
- **Unknown settings:** record them for review instead of changing unfamiliar
  firmware options immediately before dispatch.
- **Missing hardware:** if the relay, antenna or recorder is not available,
  explicitly mark that test as not performed.

The technician must still test the final weekly wake schedule and complete
power cycle with the assembled station. A photograph of settings is not proof
that the wake/shutdown arrangement works.

## Pack and hand over

Shut the computer down and disconnect its external power before packing.
Do not leave it connected to the station battery or another power supply during
transport.

- **Computer:** label visible, ports protected, suitable protective packaging.
- **Power supply:** correct supply and power lead, labelled to match the machine.
- **Adapters and cables:** include required Ethernet, display, USB and recorder
  adapters, or state clearly which the technician must supply.
- **Hardware status:** distinguish items shipped with the computer from items
  supplied separately at the installation location.
- **Contact:** provide someone who can answer questions about station labels,
  authorized accounts, hardware identity and deployment timing.

Do not put passwords, OAuth tokens or enrollment keys on the shipping label
or in the box's public paperwork. Deliver secrets separately using the agreed
secure channel.

## Private handover record for each computer

Copy this table into the private equipment record and fill it in for each unit.
Do not fill the committed example with secrets; record how credentials will be
delivered, not the credentials themselves.

| Item | Record |
|---|---|
| Physical asset label | |
| Computer model and serial | |
| Ubuntu version | |
| CPU architecture (`uname -m`) | |
| Current hostname | |
| Administrator username | |
| Login/password delivery method | |
| `sudo true` succeeded | Yes / No / Not tested |
| Cold boot reaches Ubuntu | Yes / No / Not tested |
| Disk-unlock prompt | Yes / No / Not checked |
| Unlock/recovery details delivered securely | Yes / No / Not applicable |
| BIOS/UEFI access or password delivery arranged | |
| Ethernet internet tested | Yes / No / Not tested |
| BIOS settings photographs provided | Yes / No |
| USB relay/Starlink shutdown tested | Passed / Failed / Not available |
| Intended station label, if assigned | |
| Recorder identity, if already verified | |
| Power supply and adapters included | |
| Software already present beyond Ubuntu | |
| Known problems or unfinished checks | |
| Technical contact | |
| Technician and intended installation date | |

An unchecked item is unfinished work, not an assumed pass. Keep this record with
the machine's eventual deployment and acceptance record.

## Information that can be prepared after shipping

The computer does not need to hold all service credentials before it leaves.
Prepare and deliver the following before the technician starts installation:

- **Station assignment:** the unique `station` label and intended Dropbox
  destination for each computer.
- **Private installer input:** a filled private copy of the setup example linked
  from [INSTALLATION.md](INSTALLATION.md#prepare-the-private-setup-file).
- **Dropbox authorization:** approved project-account access to the intended
  shared/team folder, with the required rclone authorization material.
- **Email:** sender, recipient and a station Google app password, following the
  [email setup instructions](INSTALLATION.md#gmail-app-password-setup).
- **Tailscale:** enrollment/access arrangements and the intended remote operator.
- **VNC:** the separate credential if a virtual desktop is required.
- **Nanometrics:** the authorized Harvester package or permitted download
  location, the trusted checksum and the required platform/version.
- **Software revision:** an agreed Git commit or release for the technician to
  install and record.

Send the approved package and setup material through suitable private channels.
Do not replace Dropbox OAuth or a Google app password with ordinary personal
account passwords.

## Technician installation and acceptance

Use [INSTALLATION.md](INSTALLATION.md) as the complete procedure and
[INSTALL.sh](INSTALL.sh) as the staged installer. Work with physical access and
reliable bench power; this is not an unattended field run.

1. Review the handover record and resolve login, disk-unlock, networking and
   hardware-access problems.
2. Obtain the agreed TELE revision and authorized Nanometrics package.
3. Prepare the private setup file and confirm the station label and Dropbox
   destination before any production upload.
4. Confirm the recorder's whole-disk by-id path and serial. Never substitute
   the computer's OS disk or guess a recorder path from an old `/dev/sdX` name.
5. Use installer preview and per-stage confirmation for the first machine.
   Do not request field activation during initial setup.
6. Run the preflight and real bench collection tests below, then inspect the
   exported files and verified Dropbox contents.
7. Verify email, Tailscale/SSH and any VNC access. Resolve the actual access
   policy and credential issues before relying on remote maintenance.
8. Complete the recorder, interruption-recovery and physical power/wake checks
   in [docs/VALIDATION.md](docs/VALIDATION.md).
9. Only after acceptance, enable the approved field service and emergency timer
   for a controlled next boot. Record the installed revision and test results.

After installation, the bench commands are:

```bash
# Run on: the Ubuntu bench computer, after TELE has been installed.
# Configuration/device inspection; no collection, email or requested shutdown.
sudo /opt/tele/current/tele.sh --check

# Real collection, Dropbox upload and email; no maintenance wait or requested shutdown.
sudo /opt/tele/current/tele.sh --once
```

Bench commands refuse to run while the field collector or emergency timer is
active. If an unexpectedly configured machine already has those services
running, arrange controlled maintenance rather than casually stopping the
collector: stopping the field service can request poweroff.

Do not treat successful software installation or local automated tests as
acceptance of the assembled station. Before deployment, verify the real recorder,
cloud archive, weekly wake and USB-relay shutdown together.

## Final deployment boundary

The intended field behaviour is weekly BIOS wake, collection and reporting,
then poweroff, with an independent software timer as the emergency deadline.
No such shutdown protection should be assumed while the computer is still in
the Ubuntu-only or bench-testing state.

There is no separate hardware cutoff in this station design. The technician must
record the remaining risk of a whole-system freeze and must not describe the
software timer as a guarantee against every possible power or firmware failure.
