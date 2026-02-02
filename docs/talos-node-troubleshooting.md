## Troubleshooting Notes (Truth tests + what each error really meant)

### 1) “Does the node *really* own the static IP?” → ARP is the truth test
If the node owns `192.168.0.245`, it must respond to ARP on the LAN.

Run from a host on the same L2 network (jumpbox):
```bash
sudo ip neigh flush all
sudo arping -I ens18 -c 3 192.168.0.245
```

- Interpretation:
  - ARP replies → The IP is actually bound to a NIC at Layer 2. 
  - Timeouts → Nothing owns that IP (Talos didn’t apply it / wrong NIC / wrong bridge/VLAN / IP conflict in rare cases).

> This single test saved hours: if ARP fails, ping, nc, routes, and redirects don’t matter yet.

### 2) Ping works but nc -vz <ip> 50000 fails

- Talos API listens on TCP/50000, but it can be in different states:
  - `Connection refused`:
    - The host is reachable (ARP works), but nothing is listening on 50000 yet. 
    - Common during early boot or when Talos API is not started.

  - `No route to host`:
    - Usually means ARP failed / no L2 neighbor. 
    - Or you are on a different VLAN / wrong bridge.

  - `Succeeded`:
    - Port is reachable, so Talos API transport works (mTLS still may block commands).

- Command:

```shell
nc -vz 192.168.0.245 50000
```

### 3) ICMP “Redirect Host” messages were a symptom, not the root cause

- I saw messages like:
  - `Redirect Host (New nexthop: 192.168.0.245)`
  - `Destination Host Unreachable`

- I flushed route caches and disabled accept_redirects, but the real underlying issue remained:

  - The node was not answering ARP for 192.168.0.245, so L2 was broken.

- Conclusion:
  - Fixing redirects helped reduce noise, 
  - but ARP truth-test proved the real root cause was IP ownership.

### 4) Talos TLS / auth errors explained (common failure modes)
### a) `tls: certificate required`

> This happens when you connect to a running node that requires client certificates (mTLS/RBAC),
> but you used a command path that didn’t present your client cert (e.g., insecure/maintenance style).

- Fix:
  - Use your cluster talosconfig:

talosctl --talosconfig ~/talos-prod/talosconfig \
```shell
  -e 192.168.0.210 -n <node> version
```

### b) `x509: certificate signed by unknown authority`

- This means the client doesn’t trust the node’s CA, often due to:
  - using the wrong talosconfig 
  - reinstall/wipe loops changing identity 
  - talking to a node in maintenance vs running mode

- Fix:
  - Ensure you can talk to a control-plane with your talosconfig:

```shell
talosctl --talosconfig ~/talos-prod/talosconfig \
  -e 192.168.0.210 -n 192.168.0.210 version
```

### 5) “InvalidArgument: cluster instructions are required”

- I hit this when trying to apply a snippet (network-only YAML) with apply-config.

- Talos apply-config expects a full machine config containing:
  - `cluster`: section 
  - `.machine.ca` or `machine.acceptedCAs`

- Fix:
  - merge the snippet into a full config first, or rewrite the full config.

### 6) “Mutually exclusive: interface and deviceSelector”

- I hit:

```shell
[networking.os.device.interface], [networking.os.device.deviceSelector]: config sections are mutually exclusive
```
- Meaning:
  - You cannot put both interface: eth0 and deviceSelector: in the same interface entry.

- Fix:
  - Use deviceSelector only (recommended in VMs):

```yaml
interfaces:
  - deviceSelector:
      hardwareAddr: "bc:24:11:8c:5b:e3"
    dhcp: false
    addresses:
      - 192.168.0.245/24
```

### 7) Why talosctl machineconfig patch kept “not fixing” it

talosctl machineconfig patch merges YAML (especially arrays).
It did not remove old entries in machine.network.interfaces, so interface: eth0 remained.

Proof:

```shell
grep -n "interface:" w2-mac-fixed-final.yaml
```


- Final fix was to force overwrite the interfaces: array via a rewrite step.

### 8) Proxmox checks that mattered

- On Proxmox host:

```shell
qm config 114 | egrep '^(bios|boot|scsi0|ide2|net0)'
```


- I verified:
  - net0 MAC was stable (used in deviceSelector)
  - bridge vmbr0 was correct 
  - disk present on scsi0

- If ARP fails repeatedly, capture on Proxmox bridge:

```shell
tcpdump -ni vmbr0 arp and host 192.168.0.245
```

- Postmortem Timeline (Knowledge Transfer)
- Context 
  - Worker VM on Proxmox needed static IP 192.168.0.245. 
  - Node frequently came up with DHCP IP (192.168.0.185) and static IP failed after reboot.

- Observations 
  - arping to 192.168.0.245 consistently timed out during failure → node was not owning the IP. 
  - ping sometimes worked briefly then failed. 
  - Talos API (50000) behavior varied (refused, no route, tls errors), correlating with whether the IP existed at L2.

- Attempts (and why they didn’t solve it)
  - Reapplying static config pinned to interface: eth0 
    - Failed because Talos interface name was not stable across VM boots/contexts.

  - Repeated machineconfig patch overlays 
    - Failed because patching merged array entries and did not remove existing interfaces/addresses.

  - Route/redirect flushing on jumpbox 
    - Reduced noise but didn’t fix the underlying issue (no ARP replies on .245).

- Breakthrough 
  - Identified the likely root cause: Talos interface naming mismatch in the VM. 
  - Confirmed Proxmox NIC MAC for VM114 from qm config 114:
    - `BC:24:11:8C:5B:E3`

- Final Fix 
  - Switched to deviceSelector.hardwareAddr to bind guarantees to the correct NIC. 
  - Stopped relying on patch merge to “remove” old interface entries. 
  - Rewrote machine.network.interfaces to contain exactly one entry (MAC-pinned) and removed all interface: keys.

- Verification
  - arping started replying for 192.168.0.245 → definitive proof the node owns the IP.

  - ping succeeded. 
  - Talos API on port 50000 became reachable once the node completed boot.

- Preventative Actions 
  - In Talos-on-Proxmox: prefer MAC-based deviceSelector for static IP. 
  - Use ARP (arping) as the first diagnostic to confirm IP ownership. 
  - Avoid repeated reinstall/wipe loops unless intentionally rebuilding. 
  - When changing network interfaces lists, prefer a controlled overwrite (rewrite) rather than relying on merge semantics.