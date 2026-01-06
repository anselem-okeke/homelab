## Homelab Checklist 
<p align="center">
  <img src="img/ryzen-1.jpg" width="400" height="300" />
  <img src="img/ryzen-2.jpg" width="400" height="300" />
</p>


### Target hardware: 
- Ryzen 7 3700X (8c/16t)
- 32GB RAM
- 1TB NVMe + 2TB SSD  
### Goal: 
- enterprise-style platform experience (kubeadm, HA control plane, CI runners, observability, Windows VM)

---

### Roadmap Checklist

| Phase | Goal | Checklist |
|------:|------|----------|
| **0** | **Foundation (BIOS + Proxmox)** | - [ ] Enable **SVM/AMD-V** + **UEFI** in BIOS  <br> - [ ] Install **Proxmox VE** on **1TB NVMe**  <br> - [ ] Set **static IP** or DHCP reservation for Proxmox host  <br> - [ ] Confirm UI access: `https://<proxmox-ip>:8006` |
| **1** | **Storage + Template + Backups** | - [ ] Add **2TB SSD** as Proxmox storage (`bulk-ssd`) (Directory or ZFS)  <br> - [ ] Keep NVMe storage for “hot” VM disks (`local-lvm` or ZFS)  <br> - [ ] Upload **Ubuntu Server ISO**  <br> - [ ] Create Ubuntu VM, install, enable SSH  <br> - [ ] Install `qemu-guest-agent` inside Ubuntu  <br> - [ ] Convert Ubuntu VM → **Template**  <br> - [ ] Configure at least **one Proxmox backup job** to `bulk-ssd` |
| **2** | **Core VMs (Jumpbox + Windows)** | - [ ] Clone template → `jumpbox` (2 vCPU / 2GB / 40GB NVMe)  <br> - [ ] Install tools on `jumpbox` (git, tmux, kubectl, helm, ansible)  <br> - [ ] (Optional) Clone template → `infra-svcs` (2 vCPU / 3–4GB / 40GB)  <br> - [ ] Upload **Windows ISO** + **VirtIO ISO**  <br> - [ ] Create `win-tools` VM (UEFI/OVMF + VirtIO SCSI + VirtIO NIC)  <br> - [ ] Install **VirtIO guest tools** in Windows  <br> - [ ] Enable **RDP** + confirm you can connect from laptop |
| **3** | **kubeadm Cluster (Enterprise-style)** | - [ ] Clone template → `k8s-cp1/cp2/cp3` (2 vCPU / 3–4GB / 60GB NVMe each)  <br> - [ ] Clone template → `k8s-w1/w2` (3 vCPU / 5GB / 80GB NVMe each)  <br> - [ ] Set hostnames + static IPs / DHCP reservations  <br> - [ ] Install container runtime (e.g., **containerd**) on all nodes  <br> - [ ] Install `kubelet`, `kubeadm`, `kubectl` on all nodes  <br> - [ ] `kubeadm init` on `k8s-cp1` using HA control-plane endpoint  <br> - [ ] Join `k8s-cp2/cp3` as control planes  <br> - [ ] Join `k8s-w1/w2` as workers  <br> - [ ] Copy kubeconfig to `jumpbox` (`~/.kube/config`)  <br> - [ ] Verify: `kubectl get nodes` shows all nodes **Ready** |
| **4** | **Networking + Ingress + Test App** | - [ ] Install CNI (recommended: **Cilium**)  <br> - [ ] Install Ingress controller (**ingress-nginx** or Traefik)  <br> - [ ] Deploy demo app + Service + Ingress  <br> - [ ] Verify app reachable from browser (via node IP/DNS)  <br> - [ ] (Optional) Add a simple NetworkPolicy and test traffic |
| **5** | **Observability + Smart-Monitor** | - [ ] Create `obs-stack` VM (2 vCPU / 4–6GB / 150GB on **2TB SSD**)  <br> - [ ] Install Prometheus + Grafana (optional: Loki/Promtail)  <br> - [ ] Scrape Proxmox host + VMs + Kubernetes metrics  <br> - [ ] Deploy Smart-Monitor backend + DB (if separate)  <br> - [ ] Build dashboards: node CPU/RAM/disk, K8s nodes/pods, CI runners |
| **6** | **CI/CD Runners (GitLab.com + Homelab)** | - [ ] Create `ci-runner-01` VM (4 vCPU / 4GB / 100GB NVMe)  <br> - [ ] Install Docker + GitLab Runner  <br> - [ ] Register runner to GitLab.com (tags: `linux`, `docker`, `homelab`)  <br> - [ ] Limit concurrency (`concurrent = 2`)  <br> - [ ] (Optional) Install GitLab Runner on `win-tools` (tags: `windows`)  <br> - [ ] Create a test `.gitlab-ci.yml` (lint/test/build) |
| **7** | **GitOps + Deployments** | - [ ] Add CI stage: build image + push registry  <br> - [ ] Add CI stage: deploy to K8s (kubectl/Helm)  <br> - [ ] Install Argo CD or Flux  <br> - [ ] Sync manifests/Helm from Git repo  <br> - [ ] Verify Git changes automatically reconcile to cluster |
| **8** | **DR / Upgrades / Hardening (Platform-level)** | - [ ] Schedule nightly VM backups to `bulk-ssd`  <br> - [ ] Practice etcd snapshot + restore (kubeadm control plane)  <br> - [ ] Perform a full kubeadm upgrade (CP nodes → workers)  <br> - [ ] Harden Proxmox access (users/roles, SSH hygiene)  <br> - [ ] Harden Kubernetes (RBAC roles, least privilege, separate admin context)  <br> - [ ] Write “incident runbooks” (node down, restore VM, restore etcd) |

---

### VM Specs

| VM | vCPU | RAM | Disk | Storage |
|----|-----:|----:|-----:|---------|
| `jumpbox` | 2 | 2GB | 40GB | NVMe |
| `win-tools` | 4 | 5GB | 120GB | NVMe |
| `k8s-cp1..3` | 2 | 3–4GB | 60GB | NVMe |
| `k8s-w1..2` | 3 | 5GB | 80GB | NVMe |
| `obs-stack` | 2 | 4–6GB | 150GB | 2TB SSD |
| `ci-runner-01` | 4 | 4GB | 100GB | NVMe |

### Kubernetes Specs

| VM        | Role          | vCPU |  RAM |            Disk |
| --------- | ------------- | ---: | ---: | --------------: |
| `talos-cp1` | control-plane |    2 | 3 GB |           60 GB |
| `talos-cp2` | control-plane |    2 | 3 GB |           60 GB |
| `talos-cp3` | control-plane |    2 | 3 GB |           60 GB |
| `talos-w1`  | worker        |    3 | 5 GB |           80 GB |
| `talos-w2`  | worker        |    3 | 5 GB |           80 GB |


> Tip: If RAM gets tight, shut down `win-tools` when not needed, or reduce `obs-stack`/`ci-runner-01` by 1GB each.

