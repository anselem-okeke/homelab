## Grafana Dashboard via ConfigMap Provisioning (kps-grafana sidecar)

Goal: ensure your Grafana dashboard can’t be lost (even if Grafana pod/PVC gets recreated),
by provisioning it from Kubernetes using the Grafana sidecar.

```shell
kubectl -n monitoring get deploy kps-grafana -o yaml | egrep -n "dashboards|label|LABEL|folder|searchNamespace|RESOURCE" -A3 -B2
```
- The command above will show the actual env vars passed to `kiwigrid/k8s-sidecar`, including the label key it watches (e.g. `LABEL=grafana_dashboard`).

My cluster already has the sidecar configured with:
- LABEL = `grafana_dashboard`
- LABEL_VALUE = `"1"`
- RESOURCE = `both` (ConfigMaps and Secrets)

So any ConfigMap/Secret with label `grafana_dashboard: "1"` will be auto-loaded as a Grafana dashboard.

---

### 0) Files to use (important)

Export **two** JSON files:

- Export for provisioning
```shell
GRAFANA_URL="http://localhost:8000"
DASH_UID="adg9q66"

curl -sS -u "admin:admin" \
  "$GRAFANA_URL/api/dashboards/uid/$DASH_UID" \
| tee /tmp/grafana_dash_raw.json \
| jq -r '.dashboard' > /mnt/data/homelab/grafana/panels/talos-cilium-dashboard.json
```
- Export with metadata
```shell
GRAFANA_URL="http://localhost:8000"
DASH_UID="adg9q66"

curl -sS -u "admin:admin" \
  "$GRAFANA_URL/api/dashboards/uid/$DASH_UID" \
| jq '.' > /mnt/data/homelab/grafana/panels/talos-cilium-dashboard-full.json
```

- verify
```shell
jq -r '.dashboard.title' /mnt/data/homelab/grafana/panels/talos-cilium-dashboard-full.json
jq -r '.meta.slug, .meta.folderTitle, .meta.url' /mnt/data/homelab/grafana/panels/talos-cilium-dashboard-full.json
```

- Use for provisioning (dashboard-only):
  - `/mnt/data/homelab/grafana/panels/talos-cilium-dashboard.json`

- Do NOT use for provisioning, use for dashboard import (envelope + meta):
  - `/mnt/data/homelab/grafana/panels/talos-cilium-dashboard-full.json`

---

## 1) Create the provisioning YAML

Create a folder for K8s manifests:
```bash
mkdir -p /mnt/data/homelab/k8s/monitoring
```
- Generate a ConfigMap YAML from your dashboard JSON and add the label the sidecar watches:
```shell
kubectl -n monitoring create configmap grafana-dashboard-talos-cilium \
  --from-file=talos-cilium-dashboard.json=/mnt/data/homelab/grafana/panels/talos-cilium-dashboard.json \
  --dry-run=client -o yaml \
| sed '/^metadata:/a\  labels:\n    grafana_dashboard: "1"' \
> /mnt/data/homelab/k8s/monitoring/grafana-dashboard-talos-cilium.yaml
```

### 2) Apply it to the cluster
```shell
kubectl apply -f /mnt/data/homelab/k8s/monitoring/grafana-dashboard-talos-cilium.yaml
```

### 3) Verify the ConfigMap label (must be "1")
```shell
kubectl -n monitoring get cm grafana-dashboard-talos-cilium \
  -o jsonpath='{.metadata.labels.grafana_dashboard}{"\n"}'
```


- Expected output:
  - `1`

### 4) Confirm Grafana loaded it

- The sidecar will reload dashboards automatically via Grafana’s API.
- No Grafana restart needed.

- Wait ~30–60 seconds, then in Grafana:

  - Go to Dashboards 
  - Search for: For the name of your dashbaord, mine is Talos-Cilium-Dashboard

### 5) Commit to git (SRE-safe)
```shell
cd /mnt/data/homelab
git add k8s/monitoring/grafana-dashboard-talos-cilium.yaml
git commit -m "Provision Grafana dashboard via ConfigMap: Talos-Cilium"
```


- Now your dashboard is protected:
  - If Grafana restarts → dashboard stays 
  - If Grafana PVC is lost → dashboard is recreated from K8s manifest 
  - If you rebuild the cluster → dashboard is restored by applying this YAML