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



## SSH

This setup uses Tailscale’s free plan to reach Starlink‑connected machines reliably without port‑forwarding. Tailscale handles NAT traversal and gives each device a stable private IP.
[https://tailscale.com/blog/free-plan](https://tailscale.com/blog/free-plan)

1. Install and bring up Tailscale on the remote (Starlink) machine

Install Tailscale using the official install script:

```
curl -fsSL https://tailscale.com/install.sh | sh
```

Then bring the node online in your tailnet, enable Tailscale SSH, and authenticate with an auth key generated in the Tailscale admin UI (this is not your password, but a special key string):

```
sudo tailscale up --ssh --authkey "tskey-xxxxxxxxxxxxxxxx"
```

This command:

- Starts the Tailscale client.

- Joins the machine to your tailnet using the auth key.

- Enables SSH over Tailscale so other devices in the tailnet can SSH in.


2. Install and bring up Tailscale on admin machine (e.g. On macOS with Homebrew:)


```
 brew install --formula tailscale
```

Start the background service and bring it up:

```
sudo brew services start tailscale
sudo tailscale up  
```

The first `tailscale up` will print a login URL; open it in a browser and approve the device so it joins the same tailnet.

3. Check connected devices and SSH in

List all devices in your tailnet from macOS:

```
tailscale status
```

You will see entries like:
```
100.116.108.33  tele1  linux   active
```

To open an SSH session to that remote machine:


```
 ssh tele@100.116.108.33   
```

(or use the hostname instead of the IP if you prefer).

4. Ending the SSH session

When finished, simply exit the remote shell:

```
exit
```

This closes the SSH session and returns you to your local macOS shell.
