##  Homelab Security + Observability (Talos/K8s): Prometheus/Grafana + Cilium L7 + Falco + Loki

![img](../img/falco-sec.png)

This doc captures what I built and how to reproduce it:
- **kube-prometheus-stack (KPS)**: Prometheus + Alertmanager + Grafana (+ sidecar provisioning)
- **Cilium L7 / Envoy metrics**: 2xx/3xx/4xx/5xx + p95 panels
- **Grafana dashboard persistence + export**
- **Falco**: runtime threat detection (DaemonSet) + Falcosidekick routing (webhook + Slack + Alertmanager, Loki later)
- **Loki**: log store with PVC (Longhorn)


Falco is a runtime security detector for Kubernetes (and Linux), think of it as “intrusion detection / suspicious
behavior alerts” for what containers and nodes are doing right now, not just how they’re configured.

### What Falco is meant for

- Falco watches:

  - Linux system calls (process executions, file access, network activity) coming from containers and hosts

  - Kubernetes events / audit logs (via plugins), depending on how you deploy it

> Then it matches what it sees against rules (like “a shell spawned inside a container” or “a container wrote to /etc”) and emits alerts.

### Why it’s valuable in a cluster

> It answers: “What bad/unsafe things are happening at runtime?”
> This is different from tools like Trivy/Kyverno which focus on images/policies before runtime.

- Concrete benefits

  - Detect compromise quickly 
    - Shell in a container (`/bin/sh`, `bash`)
    - Privilege escalation attempts 
    - Unexpected outbound connections 
    - Crypto-miner behavior patterns (high-level rules exist)

  - Catch “it shouldn’t do that” behavior 
    - A pod touching host paths 
    - Writing to sensitive dirs (`/etc, /var/run, kubelet paths`)
    - Launching package managers inside containers (apt/yum/apk)

  - Forensics and accountability 
    - “Which pod did it? On which node? Which process? Which user?”

  - Compliance / guardrails 
    - Alerts give evidence that risky actions are actually happening, not just theoretically possible

  - Where Falco fits in an “SRE stack” 
    - Cilium / Hubble = network flows and drops (network truth)
    - Prometheus / Grafana = metrics (performance truth)
    - Loki = logs (app/system narratives)
    - Falco = runtime security truth (process + syscall behavior)

  - Typical output targets:
    - Slack/Teams, Email 
    - Loki (so security events show up in Grafana Explore)
    - SIEM (Splunk/Elastic/OpenSearch), webhook



### When it’s most worth it

- Multi-tenant clusters, internet-exposed workloads, or any cluster where you care about “break-glass events”:

  - exec into pods 
  - unexpected binaries 
  - host access 
  - suspicious network/process patterns

### High-signal “enterprise setup” detections (what to enable first)

- These are the ones that matter and usually pay off immediately:
  - Shell in container (bash, sh, zsh)
  - Exec into container (if using audit/events plugin)
  - Write to sensitive paths: /etc, /usr/bin, /root, /var/run, kubelet dirs 
  - Privileged container / host namespace usage 
  - Mount / access Kubernetes secrets paths unusually 
  - Outbound network tools started (curl/wget/nc/socat) in app pods 
  - Package manager execution inside containers (apk/apt/yum)
  - Create/modify binaries in writable paths (dropper behavior)
  - Unexpected crypto/miner indicators (optional; can be noisy)
  - Container drift: “new process tree that never happens normally” (later)

### Install Falco + Sidekick (one shot)
#### Create files
- Namespace
```shell
kubectl create ns falco
```
- Webhook receiver (in-cluster, zero dependencies)
- Create: `k8s/falco/webhook-echo.yaml`
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webhook-echo
  namespace: falco
spec:
  replicas: 1
  selector:
    matchLabels:
      app: webhook-echo
  template:
    metadata:
      labels:
        app: webhook-echo
    spec:
      containers:
      - name: webhook-echo
        image: mendhak/http-https-echo:35
        ports:
        - containerPort: 8080
        env:
        - name: HTTP_PORT
          value: "8080"
---
apiVersion: v1
kind: Service
metadata:
  name: webhook-echo
  namespace: falco
spec:
  selector:
    app: webhook-echo
  ports:
  - name: http
    port: 80
    targetPort: 8080
```
- apply it
```yaml
kubectl apply -f k8s/falco/webhook-echo.yaml
```
- Falco Helm values (enterprise baseline)

- Create: `k8s/falco/falco-values.yaml`
```yaml
# Falco baseline for Talos + Kubernetes (enterprise-style, low-noise starter)
# - eBPF driver (Talos-friendly)
# - Falcosidekick enabled (routing)
# - Webhook receiver (in-cluster) enabled NOW
# - Loki output stub present (enable later when Loki exists)

tty: true

driver:
  kind: modern_ebpf

# Keep Falco logs structured (nice for later Loki)
jsonOutput: true
jsonIncludeOutputProperty: true

# Minimal resources so it stays stable under load
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: "1"
    memory: 512Mi

# Falcosidekick routing layer
falcosidekick:
  enabled: true

  extraEnvVarsSecret: slack-auth  # see screte file template below for slack

  tolerations:
    - operator: Exists

  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 500m
      memory: 256Mi

  # Sidekick config
  config:
    # Webhook receiver inside the cluster (for immediate proof/testing)
    webhook:
      address: "http://webhook-echo.falco.svc.cluster.local/"
      minimumpriority: "warning"

    slack:
      minimumpriority: "critical"

    alertmanager:
      hostport: "http://kps-kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093"
      endpoint: "/api/v2/alerts"
      minimumpriority: "critical"

    # Prometheus metrics endpoint for sidekick (useful for dashboards)
    # (Sidekick exposes /metrics; kube-prometheus-stack can scrape it if ServiceMonitor is enabled)
    prometheus:
      enabled: true

    loki:
      hostport: "http://loki-gateway.logging.svc.cluster.local"
      minimumpriority: "warning"
      # optional: extra labels to help search in Grafana Explore
      # extralabels: "cluster=homelab,source=falco"

# --- Low-noise starter: narrow exceptions ---
# do NOT silence Falco globally.
# only add a couple of safe exceptions for known tooling patterns.
customRules:
  custom-rules.yaml: |-
    - macro: user_known_tooling_namespaces
      condition: (k8s.ns.name in (falco, monitoring))

    # Example: allow known monitoring agents to read /proc a lot (common noise)
    - rule: Ignore noisy /proc access in monitoring
      desc: Reduce noise from monitoring namespace agents
      condition: >
        (k8s.ns.name=monitoring and proc.name in (node_exporter, prometheus, telegraf))
      output: "Ignoring known monitoring /proc activity (ns=%k8s.ns.name pod=%k8s.pod.name proc=%proc.name)"
      priority: NOTICE
      tags: [k8s, noise_reduction]
      enabled: true

    # Example: if you run "debug pods" in policy-lab, don't blanket-ignore; keep it surgical:
    # Allow *your* known client pod to run curl (adjust pod name if you change it)
    - rule: Allow curl in policy-lab client
      desc: Allow curl inside the specific policy-lab/client pod used for tests
      condition: >
        (k8s.ns.name=policy-lab and k8s.pod.name=client and proc.name=curl)
      output: "Allowed curl in policy-lab client (pod=%k8s.pod.name cmd=%proc.cmdline)"
      priority: NOTICE
      tags: [k8s, noise_reduction]
      enabled: true
```
- slack secret template
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: slack-auth
  namespace: falco
type: Opaque
stringData:
  slack-webhook-url: "SLACK-URL"
```
- Install Falco (Helm)
```shell
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update

helm upgrade --install falco falcosecurity/falco \
  -n falco \
  -f k8s/falco/falco-values.yaml
```
- Verify (must-pass checks)
```shell
kubectl -n falco get pods -o wide
```
- Watch Falco alerts live
```shell
kubectl -n falco logs -l app.kubernetes.io/name=falco -f --tail=50
kubectl -n falco logs -l app.kubernetes.io/name=falcosidekick -f --tail=50
```
- Check Falco DaemonSet
- If DaemonSet exists but still no pods, inspect why
```shell
kubectl -n falco describe ds falco | sed -n '1,200p'
kubectl -n falco get events --sort-by=.lastTimestamp | tail -n 40
```
- usually, taints, forbidden, missing mounts, etc.
> - Target state: 1 Falco pod per node (DaemonSet), plus sidekick + webhook

### Falco DaemonSet Error
- My cluster is enforcing Pod Security “baseline”, and Falco’s DaemonSet requires privileged + hostPath mounts, so it is being blocked:
  - `hostPath volumes …`
  - `privileged=true … violates baseline`

### Fix
- Label the falco namespace as privileged
```shell
kubectl label ns falco \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite
```
- Reconcile Falco (pods will be created)
```shell
helm upgrade --install falco falcosecurity/falco -n falco -f k8s/falco/falco-values.yaml
kubectl -n falco get pods -o wide
```
- Quick proof tests
```shell
kubectl -n policy-lab exec -it client -- sh -lc 'id; uname -a; sleep 1'
kubectl -n falco logs -l app.kubernetes.io/name=falco -c falco --tail=50 | tail -n 50
kubectl -n falco logs deploy/falco-falcosidekick --tail=100
kubectl -n falco logs deploy/webhook-echo --tail=200
Add K8s audit events (detect exec, privileged
```

### install Loki (single-binary, PVC-backed) 
```yaml
chunksCache:
  enabled: false

deploymentMode: SingleBinary

loki:
  auth_enabled: false

  extraEnvFrom:
    - secretRef:
        name: loki-s3-creds

  commonConfig:
    replication_factor: 1

  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb
        object_store: s3
        schema: v13
        index:
          prefix: loki_index_
          period: 24h

  storage:
    type: s3
    bucketNames:
      chunks: loki-chunks
      ruler: loki-ruler
      admin: loki-admin

    s3:
      endpoint: http://loki-minio.logging.svc.cluster.local:9000     #important using in another cluster
      region: eu-central-1   #important using in another cluster
      s3ForcePathStyle: true
      insecure: true

minio:
  enabled: true

  extraEnvFrom:
    - secretRef:
        name: loki-minio-root

  persistence:
    enabled: true
    storageClass: longhorn-retain    #important using in another cluster
    size: 20Gi

  buckets:
    - name: loki-chunks
    - name: loki-ruler
    - name: loki-admin

singleBinary:
  replicas: 1

# Zero out replica counts of other modes (important!)
backend:
  replicas: 0
read:
  replicas: 0
write:
  replicas: 0
ingester:
  replicas: 0
querier:
  replicas: 0
queryFrontend:
  replicas: 0
queryScheduler:
  replicas: 0
distributor:
  replicas: 0
compactor:
  replicas: 0
indexGateway:
  replicas: 0
bloomCompactor:
  replicas: 0
bloomGateway:
  replicas: 0
```
- install
```shell
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install loki grafana/loki \
  -n logging -f /mnt/data/homelab/loki/loki-values.yaml
```