# Technician guide

One page. Everything here is typed on the station computer, in a terminal.
The folder you were given contains passwords (`setup.conf`). Do not email or share it.

## 1. Install

1. Copy the whole folder to the Desktop of the computer (unzip it first if needed).
2. Plug in the Pegasus recorder (USB) and a network cable with internet.
3. Open a terminal in the folder (right-click, Open in Terminal) and run:

```bash
# Run on: the station computer, in the unzipped folder.
sudo bash INSTALL.sh
```

It takes 10 to 30 minutes and prints what it does. It does not switch on field
operation and does not power the computer off. If it stops with an ERROR, fix what
it says and run the same command again; repeating is safe. Send the ERROR line to
the project lead if you cannot fix it.

When it says `Installed TELE revision`, the computer restarts by itself after one
minute (cancel with `sudo systemctl stop tele-install-reboot.timer`). A short
report, `INSTALL-REPORT.txt`, is left in the folder: send it to the project lead.

## 2. Test one run

After the restart, with the recorder and the internet connected:

```bash
# Run on: the station computer. Takes a few minutes; does not power off.
sudo /opt/tele/current/tele.sh --once
```

It collects what the recorder holds, uploads and verifies it in Dropbox, and sends
the status email. Check that the email arrived and that Dropbox has a `Nanometrics`
folder for this computer. `sudo /opt/tele/current/tele.sh --status` shows the
folders and the days done.

## 3. Switch on field operation

Only when the project lead says so. The computer then powers off after every run:

```bash
# Run on: the station computer, in the folder.
sudo bash INSTALL.sh --enable-field
```

Set the BIOS wake-up and test the USB relay as described in
[INSTALLATION.md](INSTALLATION.md#bios-wake-up-and-the-usb-relay).

## 4. Stop the timers (computer keeps running)

Use this whenever you need the computer to stay on for upgrades or checks. It works
at any time, also while a run is in progress:

```bash
# Run on: the station computer.
sudo tele-maintenance on
```

Log in over SSH (`ssh <account>@<tailscale address>`, or `mosh` on a weak link).
When you are done, arm field mode again and switch off:

```bash
# Run on: the station computer.
sudo tele-maintenance off
sudo poweroff
```

`sudo tele-maintenance status` says whether field mode is armed. Without
`tele-maintenance on`, a computer that was switched on powers off by itself after at
most 4 hours.

## 5. Afterwards

When the installation has been accepted, delete the folder (it holds passwords):

```bash
# Run on: the station computer.
sudo rm -rf ~/Desktop/FOLDER_NAME
```
