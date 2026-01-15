### Observability Setup (Talos + Cilium + Hubble + Prometheus + Grafana)
![img](../img/cilium-dashboard.gif)

**Goal:** End-to-end observability for Cilium/Hubble:
- Enable **Hubble metrics** + Cilium/Operator metrics
- Install **kube-prometheus-stack** (Prometheus Operator + Grafana)
- Ensure **ServiceMonitors** are actually scraped
- Build a clean **Grafana dashboard** (Hubble + Cilium “enterprise” panels)
- Include **all queries used** (PromQL)

> This document assumes Cilium is already installed and running on all nodes.

---

### 0) Baseline checks (before touching observability)
### Confirm Cilium + Hubble are running
```bash
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system get pods | grep -E "hubble|cilium|operator"
kubectl -n kube-system exec ds/cilium -- cilium status | sed -n '1,120p'
```
---

### 1) Enable Hubble + Cilium Prometheus metrics (Helm values)
### 1.1 Update your cilium-values.yaml

- Add (or confirm) these sections.

If you already had hubble enabled, the important part is: hubble.metrics.enabled list (otherwise metrics stay disabled).

# --- Metrics (Prometheus) ---

# Cilium agent metrics
prometheus:
  enabled: true
  serviceMonitor:
    enabled: true   # requires Prometheus Operator (kube-prometheus-stack)

# Cilium operator metrics
operator:
  prometheus:
    enabled: true
    serviceMonitor:
      enabled: true # requires Prometheus Operator

# Hubble metrics
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true

  metrics:
    enabled:
      - dns:query;ignoreAAAA
      - drop
      - tcp
      - flow
    serviceMonitor:
      enabled: true # requires Prometheus Operator

  # Hubble Relay metrics (optional, but nice)
  relay:
    prometheus:
      enabled: true
      serviceMonitor:
        enabled: true # requires Prometheus Operator

1.2 Apply upgrade
helm upgrade --install cilium cilium/cilium -n kube-system -f cilium-values.yaml
kubectl -n kube-system rollout status ds/cilium
kubectl -n kube-system rollout status deploy/cilium-operator
kubectl -n kube-system rollout status deploy/hubble-relay

1.3 Verify Hubble metrics service exists
kubectl -n kube-system get svc | grep -E "hubble|cilium|operator"


Expected (example):

hubble-metrics (headless) port 9965

cilium-agent metrics (typically 9962) via Service/Endpoints

2) Prove metrics are emitted (without Prometheus)

This validates /metrics is live.

2.1 Port-forward Hubble metrics locally (from jumpbox)
kubectl -n kube-system port-forward svc/hubble-metrics 9965:9965

2.2 Read metrics (new terminal)
curl -s http://127.0.0.1:9965/metrics | head -n 40
curl -s http://127.0.0.1:9965/metrics | grep -E '^hubble_' | head -n 40


Stop port-forward with Ctrl+C when done. Prometheus does not need port-forward.