### Talos Worker with Static IP and MAC address

#### Goal
Worker W2 must use a stable static IP `192.168.0.245/24` in Talos on Proxmox, without “reverting” to DHCP IP (e.g. `192.168.0.185`).

---

#### Root cause
1) **Talos NIC name mismatch** (VM interface names may not match your expected `eth0/ens18`).  
2) **Patch merge behavior** (`talosctl machineconfig patch` merges lists; it doesn’t delete old `interfaces` entries).  
✅ Final solution: bind the NIC by **MAC** using `deviceSelector.hardwareAddr`, and generate a final file where **no `interface:`** keys remain.

---

#### Part 1 — Generate a patchable full worker config (base file)

#### 1) Confirm Talos access via control-plane works
```bash
talosctl --talosconfig ~/talos-prod/talosconfig \
  -n 192.168.0.210 -e 192.168.0.210 version
```

#### 2) Export a live worker config from a known-good worker (W1)

- I used a running worker (example: `192.168.0.244`) as the template base.

```shell
cd ~/talos-prod

talosctl --talosconfig ~/talos-prod/talosconfig \
  --endpoints 192.168.0.210 \
  --nodes 192.168.0.244 \
  get machineconfig -o yaml > w1-live.yaml
```

- Why this step is required

- get `machineconfig -o yaml` returns an object like:

  - metadata...

  - spec: |
  (and then the actual machine config YAML is inside that string)

- talosctl machineconfig patch needs the real config YAML, not the wrapper object.

#### 3) Extract the YAML under `spec: |` into a real machineconfig file
```shell
awk '
$1=="spec:" && $2=="|" {grab=1; next}
grab { sub(/^    /,""); print }
' w1-live.yaml > w1-live-spec.yaml
```


- Quick sanity:

```shell
head -n 20 w1-live-spec.yaml
```


- Expected start:

```yaml
version: v1alpha1
debug: false
persist: true
machine:
  ...
```
#### 4) If the file contains multiple YAML documents, take only the MachineConfig doc

- Some Talos outputs can be multi-doc (e.g. additional `HostnameConfig` doc).

- I extracted only the first document (before `---`):

```yaml
awk 'BEGIN{first=1} /^---[[:space:]]*$/{exit} {print}' w1-live-spec.yaml > w1-live-machine.yaml
```

- Now `w1-live-machine.yaml` is a clean single-doc base.

#### Part 2 — Create W2’s full config (base) using patches
#### 5) Create a W2 static network patch (initial version)
```yaml
cat > w2-static.yaml <<'YAML'
machine:
  network:
    nameservers:
      - 192.168.0.1
    interfaces:
      - interface: eth0
        dhcp: false
        addresses:
          - 192.168.0.245/24
        routes:
          - network: 0.0.0.0/0
            gateway: 192.168.0.1
YAML
```

#### 6) (Optional) Create a wipe patch ONLY for fresh reinstall

- Use `wipe: true` only when you are intentionally reinstalling.

```shell
cat > w2-wipe.yaml <<'YAML'
machine:
  install:
    wipe: true
YAML
```

#### 7) Patch the base worker config into a W2 full config
```shell
talosctl machineconfig patch w1-live-machine.yaml \
  --patch @w2-static.yaml \
  --output w2-fixed.yaml

talosctl machineconfig patch w2-fixed.yaml \
  --patch @w2-wipe.yaml \
  --output w2-fixed-final.yaml
```


- At this point, `w2-fixed-final.yaml` is a full Talos machine config for W2 (cluster section, machine CA, etc. included),
- but the network is still pinned to `interface: eth0`.

#### Part 3 — The actual final fix (MAC-based `deviceSelector` + rewrite)
#### 8) Get the Proxmox NIC MAC address

- From Proxmox host:

```shell
qm config 114 | egrep '^(net0|scsi0|boot|bios|ide2)'
```


- Example:

```shell
net0: virtio=BC:24:11:8C:5B:E3,bridge=vmbr0
```

#### 9) Create MAC-based network config (deviceSelector only)

> Important: interface: and deviceSelector: are mutually exclusive in the same entry.
> I used MAC selection only.

```shell
cat > w2-mac-net.yaml <<'YAML'
machine:
  network:
    nameservers:
      - 192.168.0.1
    interfaces:
      - deviceSelector:
          hardwareAddr: "bc:24:11:8c:5b:e3"
        dhcp: false
        addresses:
          - 192.168.0.245/24
        routes:
          - network: 0.0.0.0/0
            gateway: 192.168.0.1
YAML
```

#### 10) Why patching was not enough

- Even after patching, interface: eth0 remained because patching merges lists:

```shell
talosctl machineconfig patch w2-fixed-final.yaml \
  --patch @w2-mac-net.yaml \
  --output w2-mac-fixed-final.yaml

grep -n "interface:" w2-mac-fixed-final.yaml
```


- I still saw:

```shell
- interface: eth0
```


So I must overwrite the whole `interfaces:` array cleanly.

#### 11) Generate the final working file by rewriting `machine.network.interfaces`

- This is the final step that actually made the static IP stick permanently.

```shell
python3 - <<'PY'
import yaml

src = "w2-fixed-final.yaml"
dst = "w2-mac-fixed-final.yaml"

mac = "bc:24:11:8c:5b:e3"
ip  = "192.168.0.245/24"
gw  = "192.168.0.1"
dns = ["192.168.0.1"]

with open(src) as f:
    cfg = yaml.safe_load(f)

cfg.setdefault("machine", {})
cfg["machine"].setdefault("network", {})

cfg["machine"]["network"]["nameservers"] = dns
cfg["machine"]["network"]["interfaces"] = [{
    "deviceSelector": {"hardwareAddr": mac},
    "dhcp": False,
    "addresses": [ip],
    "routes": [{"network": "0.0.0.0/0", "gateway": gw}],
}]

with open(dst, "w") as f:
    yaml.safe_dump(cfg, f, sort_keys=False)

print(f"Wrote {dst}")
PY
```
#### 12) Sanity checks (must pass)
```shell
grep -n "interface:" w2-mac-fixed-final.yaml || true
grep -nE "deviceSelector|hardwareAddr|192\.168\.0\.245" w2-mac-fixed-final.yaml
```

- Expected:
  - No output for `interface:`
  - Output includes the MAC selector and `192.168.0.245`

#### Part 4 — Apply and verify
#### 13) Apply config (secure mode via talosconfig)
```shell
talosctl --talosconfig ~/talos-prod/talosconfig \
  --endpoints 192.168.0.210 \
  --nodes 192.168.0.185 \
  apply-config --mode=reboot \
  --file ~/talos-prod/w2-mac-fixed-final.yaml
```

#### 14) Verify at Layer 2 first (ARP test)
```shell
sudo ip neigh flush all
sudo arping -I ens18 -c 3 192.168.0.245
ping -c 2 192.168.0.245
nc -vz 192.168.0.245 50000
```


- ARP reply = static IP is truly bound to the NIC.

- Key takeaways 
  - In Talos-on-VMs, MAC pinning is the most reliable for static IPs. 
  - `talosctl machineconfig patch` merges arrays; it won’t remove old interface entries. 
  - When you need a clean network config, rewrite `machine.network.interfaces` explicitly.