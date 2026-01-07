# Linux Setup

Our system runs on Ubuntu 20.04.

## Time configuration

- Use **UTC** for the system clock for consistency with seismometer timestamps.  
- See Ubuntu time configuration notes:  
  [https://help.ubuntu.com/community/UbuntuTime](https://help.ubuntu.com/community/UbuntuTime)

## User and login

- Create a single main user (e.g. `tele`) with `sudo` privileges.  
- Enable automatic login for this user (no password at graphical login):  
  [https://help.ubuntu.com/stable/ubuntu-help/user-autologin.html.en](https://help.ubuntu.com/stable/ubuntu-help/user-autologin.html.en)

## Autostart of `tele1.sh`

Create an autostart entry so the script runs in a visible terminal after login:

```
mkdir -p ~/.config/autostart
```

Create ~/.config/autostart/tele1.desktop:

```
[Desktop Entry]
Type=Application
Name=tele1
Comment=Run tele1 in terminal
Exec=gnome-terminal -- bash -c "/home/tele/tele/tele1.sh; exec bash"
Terminal=false
X-GNOME-Autostart-enabled=true
```

## Passwordless shutdown

Allow the tele user to power off without entering a sudo password:

```
sudo visudo
```

Add at end of file:

```
tele ALL=(ALL) NOPASSWD: /sbin/poweroff, /usr/sbin/poweroff
```


## BIOS Settings (F2 on Shuttle SPCEL03)

Enable RTC (real-time clock) power-on.

Set Ignition key (or equivalent option) to power on the system.



