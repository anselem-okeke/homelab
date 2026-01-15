### Talos: Migrate from Flannel → Cilium (VXLAN) + Hubble (UI/Relay)

This runbook documents how I migrated a Talos Kubernetes cluster from Flannel to Cilium, and enabled **Hubble** (Relay + UI).
(Observability stack + dashboards are documented [here]())

---

### 0) Environment details (what we had)

### Cluster networking (before)
- **CNI:** Flannel (DaemonSet `kube-flannel` in `kube-system`)
- **kube-proxy:** enabled
- **Control-plane VIP (API):** `192.168.0.210:6443`
- **Pod CIDRs (per node):** `10.244.x.0/24` (kube-controller-manager assigned)
- **Service CIDR:** Kubernetes default `10.96.0.0/12` (example: `kubernetes` svc = `10.96.0.1`)

### Validate baseline
```bash
kubectl get pods -n kube-system | grep -E "cilium|calico|flannel"
kubectl get ds -n kube-system
kubectl get nodes -o wide

# Pod CIDR per node
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.podCIDR}{"\n"}{end}'

# Service CIDR check (kubernetes service)
kubectl get svc kubernetes -o wide
```

---

### 1) What “Pod CIDR” and “Service CIDR”

- Pod CIDR: IP range used for Pod IPs. Usually allocated per node (e.g., 10.244.1.0/24).

- Service CIDR: Virtual IP range for Services (ClusterIP), e.g., 10.96.0.0/12.

- During migration, I do not change these ranges. Cilium will route within them.

---

### 2) Install Cilium (keep it safe first)

- I installed Cilium using:
  - IPAM: `kubernetes` (uses existing PodCIDRs assigned by K8s)
  - Routing: `tunnel` with `vxlan` (simple & reliable for homelabs)
  - kube-proxy replacement: start conservative (`false`), then enable later.

- Add Helm repo (if needed)
```shell
helm repo add cilium https://helm.cilium.io/
helm repo update
```

- Create `cilium-values.yaml`
```shell
# cilium-values.yaml
# Talos + Flannel -> Cilium migration (safe path)
# - keep kube-proxy for now
# - tunnel (vxlan) for simplicity
# - Talos-required: disable cgroup automount + drop SYS_MODULE capability

kubeProxyReplacement: "false" # <----this is false to prevent kube-proxy replacement, change to "true" during replacement

k8sServiceHost: "192.168.0.210"
k8sServicePort: 6443

ipam:
  mode: "kubernetes"

routingMode: "tunnel"
tunnelProtocol: "vxlan"

# Pod + Service CIDRs for cluster (informational and clarity)
# Pod CIDR:     10.244.0.0/16
# Service CIDR: 10.96.0.0/12

# Enterprise-grade visibility
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true

# --- Talos-specific requirements ---
cgroup:
  autoMount:
    enabled: false
  hostRoot: /sys/fs/cgroup

# Talos blocks loading kernel modules from pods, to ensure SYS_MODULE is not requested.
securityContext:
  capabilities:
    ciliumAgent:
      - CHOWN
      - KILL
      - NET_ADMIN
      - NET_RAW
      - IPC_LOCK
      - SYS_ADMIN
      - SYS_RESOURCE
      - DAC_OVERRIDE
      - FOWNER
      - SETGID
      - SETUID
    cleanCiliumState:
      - NET_ADMIN
      - SYS_ADMIN
      - SYS_RESOURCE
```

- Install
```shell
helm repo add cilium https://helm.cilium.io/
helm repo update

helm upgrade --install cilium cilium/cilium \
  -n kube-system \
  -f cilium-values.yaml
```
- if anything breaks, you can rollout immediately
```shell
helm upgrade cilium cilium/cilium -n kube-system -f cilium-values.yaml
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system get pods -l k8s-app=cilium -w
```

- Watch Cilium pods
```shell
kubectl -n kube-system get pods -l k8s-app=cilium -w

# Validate basic networking before cutting over
kubectl -n kube-system exec ds/cilium -- cilium status
kubectl get pods -A -o wide | head -50
```
- (Optional) open Hubble UI:
```shell
kubectl -n kube-system port-forward svc/hubble-ui 12000:80
curl -I http://127.0.0.1:12000
```
- get `HTTP/1.1 200 OK`
- Then browse `http://localhost:12000`
- port forward to host machine if you are not running from server
  - `ssh -L 12000:127.0.0.1:12000 user@<IP>`
---

### 3) Verify Cilium is healthy
- Check Cilium status
```shell
kubectl -n kube-system exec ds/cilium -- cilium status | sed -n '1,120p'
```
- OR
```shell
kubectl -n kube-system get svc hubble-ui -o wide
kubectl -n kube-system get endpoints hubble-ui -o wide
kubectl -n kube-system get pods -l k8s-app=hubble-ui -o wide
```
- `Note` avoid TLS/SSL mismatch when using TALOS, either directly use the talosconfig or export to the shell
```shell
talosctl get manifests \
  -n 192.168.0.241 \
  --endpoints 192.168.0.241 \
  --talosconfig ~/talos-prod/talosconfig

# OR
export TALOSCONFIG=~/talos-prod/talosconfig
talosctl --endpoints 192.168.0.241 -n 192.168.0.241 get manifests
```
# This is the cleanest enterprise setup (ServiceMonitors, dashboards, alert rules).

- Expected signals:
  - Cilium: Ok 
  - CNI Config file: successfully wrote ... 05-cilium.conflist 
  - Hubble: Ok (later)

- Confirm Cilium services exist
```shell
kubectl -n kube-system get svc | grep -E "hubble|cilium|operator"
```
---

- # REmove - install prometheus stack 
```shell
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace monitoring

helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  -n monitoring
```

### 4) Remove Flannel (after Cilium is stable)

> - Only do this once Cilium is Running on every node and cilium status looks healthy.

- Remove Flannel DaemonSet
```shell
kubectl -n kube-system delete ds kube-flannel
```


- (Optionally remove Flannel configmap if present)

```shell
kubectl -n kube-system delete cm kube-flannel-cfg --ignore-not-found
```

- Confirm Flannel is gone
```shell
kubectl get pods -n kube-system | grep -i flannel || echo "OK: no flannel pods"
kubectl get ds -n kube-system | grep -i flannel || echo "OK: no flannel daemonset"
```


>  - Note: Existing Pods may still be using old networking until they restart. New Pods should use Cilium.

---


### 5) Enterprise step: move to kube-proxy replacement (optional but recommended)

- I enabled `kube-proxy replacement` after `Cilium` and `pod networking` were stable.

### A) Disable kube-proxy on Talos

- I patched Talos MachineConfigs to stop managing kube-proxy (and any remaining flannel manifests if they existed).

- Example:
```shell
# talos-disable-kube-proxy.yaml
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true

# my cluster comprises of 1VIP, 3control planes, 2worker node - 1deactivated
# the IPs 241,242,243,244 are node IP
talosctl patch mc \
  --nodes 192.168.0.241,192.168.0.242,192.168.0.243,192.168.0.244 \
  --endpoints 192.168.0.241 \
  --talosconfig ~/talos-prod/talosconfig \
  --patch @talos-disable-kube-proxy.yaml
```

- If you see a Talos TLS error like `certificate signed by unknown authority`, 
- it usually means your `--endpoints` / `--nodes` / `talosconfig` are mismatched (wrong cluster context). Fix context first, then retry.

### B) Enable kubeProxyReplacement in Cilium

- Update `cilium-values.yaml`:

```shell
kubeProxyReplacement: "true"
```


- Apply:

```shell
helm upgrade --install cilium cilium/cilium \
  -n kube-system \
  -f cilium-values.yaml
```


- Verify:

```shell
kubectl -n kube-system exec ds/cilium -- cilium status | grep -E "KubeProxyReplacement|Masquerading|Routing"
```


- You should see:
  - KubeProxyReplacement: True
  
### 6) Troubleshooting notes (what we hit)
### A) Init container capability error (OCI runtime / caps)

- Symptom (example):
  - can't apply capabilities: operation not permitted

- Fix pattern:
  - This is usually an environment/runtime privilege constraint. 
  - Confirm Talos version + container runtime is supported. 
  - Re-check Cilium install mode and ensure you’re not forcing unsupported privileged operations. 
  - Reinstall/upgrade Cilium after correcting values.

### B) Talos x509 handshake errors

- Symptom:
  - tls: failed to verify certificate ...

- Fix pattern:
  - Use the correct talosconfig 
  - Ensure --endpoints points at a valid control-plane endpoint for that cluster 
  - Ensure node IPs match the cert SANs in your Talos config

### 8) Validation checklist (done means migration complete)

- kubectl get ds -n kube-system shows no flannel 
- kubectl -n kube-system get pods -l k8s-app=cilium shows Running on all nodes 
- cilium status reports Cilium Ok 
- Hubble UI reachable via SSH tunnel
- (Optional) KubeProxyReplacement: True and kube-proxy disabled on Talos

## [Reference -  Cilium official Documentation](https://docs.cilium.io/en/stable/index.html)