# Enterprise rollout approach for Cilium policies

![img](../../img/cilium-policy.svg)

---

### The principles

1) Progressive enforcement (never flip the whole cluster at once)
2) Golden baselines (DNS + platform dependencies are standardized)
3) Per-app allowlists (teams declare dependencies explicitly)
4) Observability gates (drops + reasons decide go/no-go)
5) Break-glass (fast rollback path exists, documented)

---

### Phase 0 — Set up a “policy program” (lightweight but real)

### 0.1 Create namespaces
- policy-lab 
- policy-stage 
- prolicy-prod

```yaml
kubectl create ns policy-stage
kubectl label ns policy-lab policy-tier=lab --overwrite
kubectl label ns policy-stage policy-tier=stage --overwrite
```

### 0.2 Define standard labels all workloads must have

- Enterprise requirement: everything must be selectable by policy. 
  - `app`
  - `team` (optional)
  - `tier` (optional)

- Example expectation:

```yaml
labels:
  app: server
  team: platform
  tier: backend
```

### Phase 1 — Golden baseline policies (platform-owned)

>  - These are reused everywhere so app teams don’t reinvent the wheel.

### 1.1 DNS allow policy (template)

- Create a reusable YAML template in your repo, for example:
  - `policies/baseline/allow-dns-egress.yaml`
  - (Use the same policy; keep one “approved” version.)

### 1.2 (Optional) Platform dependencies

- Enterprises often also allow:
  - egress to metrics/logging endpoints (Prometheus, Loki, OTEL collectors)
  - egress to time sync (NTP)
  - egress to internal proxies (egress gateway)

### Phase 2 — Start with “observe only” gates (no surprises)

>  - Before enforcing on a namespace, you confirm what it currently talks to.

### 2.1 Pre-flight: identify dependencies

- In your lab, you’ll do this manually first:
  - What services does the app call? 
  - Does it need DB, Redis, external APIs? 
  - Does it need DNS? (almost always yes)

- Enterprise version uses:
  - Hubble UI (flows)
  - metrics (top namespaces)
  - sometimes service maps (tracing)

### 2.2 Observability go/no-go gate (the rule)

- For a namespace to proceed to enforcement:
  - You must be able to run the app normally 
  - Drops should be explainable (not random)
  - You must have a rollback plan

- Practical “gate” checks (Grafana/PromQL):

```yaml
sum(rate(cilium_drop_count_total[5m]))
topk(10, sum by (reason) (rate(cilium_drop_count_total[5m])))
topk(10, sum by (node, reason) (rate(cilium_drop_count_total[5m])))
```

### Phase 3 — Progressive enforcement per namespace (the enterprise method)
### 3.1 Enforce only in one namespace at a time

- Order:
  - `policy-lab` 
  - `policy-stage`
  - one “low-risk” prod namespace 
  - expand

### 3.2 The exact rollout sequence in each namespace

>  - For each namespace:

### Step A — Apply default-deny
```shell
kubectl -n <ns> apply -f policies/baseline/default-deny.yaml
```

### Step B — Apply golden DNS allow
```shell
kubectl -n <ns> apply -f policies/baseline/allow-dns-egress.yaml
```

### Step C — Apply app-specific allow rules

- Example:
  - allow frontend → backend 
  - allow backend → db 
  - allow backend → external API (if required)

### Step D — Validate + watch drops for 15 minutes

- app health checks pass 
- no unexplained drops spike

### Phase 4 — Change management (what makes it “enterprise”)
### 4.1 Policies must be version-controlled

- Repo structure example:

```yaml
policies/
  README.md

  apps/
    policy-lab/
      namespace.yaml
      demo-app.yaml
      kustomization.yaml

    policy-stage/
      namespace.yaml
      demo-app.yaml
      kustomization.yaml

  baselines/
    default-deny.yaml
    allow-dns-egress.yaml

  overlays/
    policy-lab/
      kustomization.yaml
      allow-client-to-server.yaml

    policy-stage/
      kustomization.yaml
      allow-client-to-server.yaml

```

### 4.2 Pull request review

- Even in homelab, emulate:
  - platform approves baseline changes 
  - app owners approve app allowlists

### 4.3 Promotion model

- Same policy flows:
  - `lab` → `stage` → `prod`

- Meaning: don’t write policies directly in prod first.

### Phase 5 — Break-glass (rollback) plan

> - Enterprises always have a “stop the bleeding” button.

### 5.1 Namespace rollback

- If an app breaks:
```shell
kubectl -n <ns> delete netpol --all
```


- That immediately restores default allow behavior for that namespace.

### 5.2 Partial rollback (remove only the deny)
```shell
kubectl -n <ns> delete netpol default-deny
```

### 5.3 Post-incident rule

- After rollback:
  - check drop reasons 
  - add missing allow rules 
  - re-enable deny

- This is how enterprises avoid “we disabled security forever”.

### Phase 6 — “Definition of Done” for a namespace

- A namespace is considered “enterprise policy-ready” when:
  - Default-deny is in place 
  - DNS allow policy applied 
  - App allowlists exist and are minimal 
  - Tests prove expected behavior 
  - Dashboards show stable drops (near-zero, explainable)
  - Rollback steps documented

[Reference - Cilium Network Policy](https://docs.cilium.io/en/stable/security/policy/index.html)