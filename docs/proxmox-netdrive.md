Part A — Create the LXC container (UI wizard)
1) General tab

Fill corresponding:

- CT ID: 100 usually random

- Hostname: fileserver01

- Unprivileged container: ON (keep it ON)

- Nesting: OFF (not needed for Samba also could be ON)

- Password: set it (fine)
- tick “Start after created” at the end.


2) Template tab

- Storage: ssd-backup
- First upload container Template to ssd storage
- Template: debian-12-standard...



3) Disks tab



Storage: local-lvm

- Disk size: 8 GiB


- Recommended: for Samba + logs and extra tools (tailscale, monitoring, etc.)

- Storage = local-lvm  (OS on NVMe fast; data will live on SSD via mountpoint later).

4) CPU tab

- 2 cores is fine and still lightweight.)

5) Memory tab

   - Memory: 1024 MiB 

   - Swap: 1024 MiB

6) Network tab (IMPORTANT)
   - Bridge: vmbr0  good 
   - Firewall: checked (shows firewall=1)
   - IPv4: DHCP(recommended)
   - IPv4: DHCP 
   - Gateway: leave blank (DHCP provides it)
   - IPv6: leave off unless you need it
- About the Firewall checkbox:

- If NO plan to manage Proxmox firewall rules now, you can uncheck it to avoid accidental blocking.

- If checked, adding allow rules later.

7) DNS tab

- Leave as

- “use host settings” 

8) Confirm tab

- see something like:

- rootfs local-lvm:8 (or 16)

- net0 ... bridge=vmbr0

- ostemplate ssd-backup:vztmpl/debian...

- unprivileged 1

- Tick Start after created
Click Finish.

Part B — Prepare the SSD folders (Proxmox host)

- In pve01 → Shell run:

```shell
mkdir -p /mnt/pve/ssd-backup/netshare/data
mkdir -p /mnt/pve/ssd-backup/netshare/iso-drop
```


- These are the only folders we will expose as a “network drive”.
- Proxmox backups stay safe in /mnt/pve/ssd-backup/dump and will NOT be shared.


Part C — Add the SSD folder into the container (Mount Point)

Select your container CT 100 (fileserver01)

Stop container
```shell
pct shutdown 100 || true
pct stop 100
```

Set: done through the CLI not GUI

```shell
# GUI style
Source: /mnt/pve/ssd-backup/netshare
Target: /srv/netshare
```

```shell
# CLI style 
vim /etc/pve/lxc/100.conf

# add line at the bottom
mp0: /mnt/pve/ssd-backup/netshare,mp=/srv/netshare

# start
pct start 100

# enter
pct enter 100
```
- confirm:
```shell
ls -ld /srv/netshare
mount | grep netshare || df -h | grep netshare
```
- should see /srv/netshare mounted.
- permission denied
```shell
chmod 777 /mnt/pve/ssd-backup/netshare
```

Part D — Fix permissions (required for unprivileged LXC)

- open the container console (CT → Console) and run:
```shell
id
```
- create a Samba user:

```yaml
apt update
apt install -y samba
useradd -m -u 1000 smbuser
passwd smbuser
smbpasswd -a smbuser
```


- On the Proxmox host shell, run this (this mapping is the key):

- Unprivileged containers map UID like:
- host_uid = 100000 + container_uid
- smbuser is UID 1000 → host UID 101000

So on Proxmox host:
```yaml
chown -R 101000:101000 /mnt/pve/ssd-backup/netshare
chmod -R 2770 /mnt/pve/ssd-backup/netshare
```
- Now the container user smbuser can write into the SSD share.


Part E — Configure Samba shares (inside container)

Inside the container:

- nano /etc/samba/smb.conf


- Add at the bottom:

```yaml
[data]
   path = /srv/netshare/data
   browseable = yes
   read only = no
   guest ok = no
   valid users = smbuser
   create mask = 0660
   directory mask = 2770
   inherit permissions = yes

[iso-drop]
   path = /srv/netshare/iso-drop
   browseable = yes
   read only = no
   guest ok = no
   valid users = smbuser
   create mask = 0660
   directory mask = 2770
```

- Restart Samba:
```shell
systemctl restart smbd
```

#### make drive modifiable from anywhere
- Install ACL tools (host)
```shell
apt update
apt install -y acl
```
- Apply ACLs to the shared folder (host)
```shell
setfacl -R -m u:101000:rwx,g:101000:rwx,m:rwx /mnt/pve/ssd-backup/netshare/data
setfacl -R -d -m u:101000:rwx,g:101000:rwx,m:rwx /mnt/pve/ssd-backup/netshare/data
```
- `m sets` current permissions (fixes existing stuff)

- `d -m` sets default permissions (for future files)

- `m:rwx` ensures the ACL mask doesn’t silently remove write access

```shell
systemctl restart smbd
systemctl enable smbd
```

Part F — Access from Windows + Linux (any other computer)
- Windows

- Open File Explorer and type:

\\fileserver01\data (if name resolves)
or

\\<container-ip>\data

To map it: Right-click → Map network drive

- Linux
- Install CIFS support + create mount point
```shell
sudo apt update
sudo apt install -y cifs-utils
sudo mkdir -p /mnt/data
```

- Mount with explicit SMB version + rw

- This will prompt you for the password:
```shell
sudo mount -t cifs //192.168.0.51/data /mnt/data \
  -o username=smbuser,vers=3.0,rw,uid=$(id -u),gid=$(id -g),file_mode=0660,dir_mode=0770
```
- if fails, try:
```shell
sudo mount -t cifs //192.168.0.51/data /mnt/data \
  -o username=smbuser,vers=2.1,rw,uid=$(id -u),gid=$(id -g),file_mode=0660,dir_mode=0770
```

- If don’t want a password prompt (credentials file)
````shell
sudo bash -c 'cat > /root/.smbcred <<EOF
username=smbuser
password=YOUR_PASSWORD
EOF'
sudo chmod 600 /root/.smbcred

sudo mount -t cifs //192.168.0.51/data /mnt/data \
  -o credentials=/root/.smbcred,vers=3.0,rw,uid=$(id -u),gid=$(id -g),file_mode=0660,dir_mode=0770
````
- Get the real reason from dmesg (most important)

- Run immediately after a failed mount:
```shell
dmesg | tail -n 50
```
- Typical meanings:

  - `STATUS_LOGON_FAILURE` → wrong password / wrong user 
  - `STATUS_ACCESS_DENIED` → share permissions / Samba config 
  - `protocol negotiation failed` → wrong vers=... 
  - `No route to host` / `Connection timed out` → firewall/port 445 blocked


#### Tailscale (step-by-step)

“relocation-proof” solution: always reachable `fileserver01` home or even network changes.

A) Install Tailscale in the container (fileserver01)

- Open CT console and run:

```shell
apt update
apt install -y curl
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up
```
- tailscale up will print a login URL. Open it in your browser, authenticate, approve the device with github.

- Then confirm:

```shell
tailscale status
tailscale ip -4
```


- You’ll get a Tailscale IP like 100.x.y.z.

B) Install Tailscale on your Windows PC

- Install Tailscale (Windows app)

- Sign in with the same account

- Confirm both devices appear in tailscale status

C) Map the share over Tailscale (Windows)

In File Explorer:

- `\\<tailscale-ip>\data`

Example:

- `\\100.101.102.103\data`

Map it to a drive letter (Z:) like you already did.

- Now you can access the share:

  - at home 
  - after relocation 
  - from anywhere (as long as both devices are on Tailscale)
  - You do not open router ports. SMB stays private, only reachable via VPN.