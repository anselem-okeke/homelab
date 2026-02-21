## Kubernetes Audit Security Dashboard (Enterprise)
![img](../img/audi-soc.gif)
This guide shows how to **collect Kubernetes API Server audit logs** with **Grafana Alloy (DaemonSet)** and build an **enterprise-style security dashboard** in Grafana backed by **Loki**.

If anyone clones my repo and follows this document, you should be able to:
1) deploy Alloy for audit logs
2) verify logs in Loki
3) import/build the dashboard
4) understand **why each panel exists**, what it detects, and what actions to take

---

### 1) Why audit logs matter (the enterprise reason)
Kubernetes audit logs are the closest thing to a **control-plane flight recorder**.

They answer questions like:
- **Who did what?** (user/serviceaccount)
- **From where?** (source IP / user agent)
- **To which resource?** (pods/secrets/rbac)
- **Did it succeed?** (2xx vs 4xx/5xx)
- **Was it interactive access?** (pods/exec, port-forward)

In a real enterprise/SOC setup, audit logs support:
- Incident investigations (“how did they get in?”)
- Detection (“RBAC changed”, “secrets modified”, “exec happened”)
- Compliance (“prove access controls are enforced”)

---

### 2) Architecture
**Flow:**
Kube API Server audit file (on control-plane host)  
→ **Grafana Alloy (DaemonSet)** reads files + ships logs  
→ **Loki** stores logs  
→ **Grafana** dashboards/alerts query Loki (LogQL)

**Key design rule:**  
Only promote **low-cardinality labels** (e.g. `job`, `node`).  
Do *not* label things like `requestURI` or `userAgent` (too many unique values).

---

### 3) Prerequisites
- Kubernetes cluster (Talos OK)
- Loki is deployed and reachable from Alloy
- Grafana can reach Loki
- Audit logs exist on control-plane nodes, e.g.:
  - `/var/log/audit/kube/`

Quick verification (on a control-plane node):
```bash
ls -lah /var/log/audit/kube | head
```

### 4) Install Grafana Alloy (Helm) — Audit Collector (Enterprise-style)
### 4.1 Add Helm repo
```shell
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```
### 4.2 Create a namespace
```shell
kubectl create namespace logging --dry-run=client -o yaml | kubectl apply -f -
```
### 4.3 Minimal “enterprise” values for audit collection (DaemonSet on control-plane)

- Save as values-alloy-audit.yaml:
```shell
controller:
  type: daemonset
  nodeSelector:
    node-role.kubernetes.io/control-plane: ""
  tolerations:
    - operator: Exists
  volumes:
    extra:
      - name: auditlog
        hostPath:
          path: /var/log/audit/kube
          type: DirectoryOrCreate

alloy:
  configMap:
    create: true
    content: |
      local.file_match "k8s_audit" {
        path_targets = [{
          __address__ = "localhost",
          __path__    = "/var/log/audit/kube/kube-apiserver*.log",
        }]
      }

      loki.source.file "audit" {
        targets      = local.file_match.k8s_audit.targets
        forward_to   = [loki.process.audit.receiver]
        start_at_end = true
      }

      loki.process "audit" {
        forward_to = [loki.write.local.receiver]

        stage.static_labels {
          values = {
            job    = "k8s-audit",
            stream = "k8s-audit",
            source = "apiserver-audit",
            node   = constants.hostname,
          }
        }

        stage.json {
          expressions = {
            stage     = "stage",
            verb      = "verb",
            user      = "user.username",
            namespace = "objectRef.namespace",
            resource  = "objectRef.resource",
            code      = "responseStatus.code",
            uri       = "requestURI",
          }
        }

        # Keep only final outcome (drops RequestReceived/ResponseStarted duplicates)
        stage.match {
          selector = "{job=\"k8s-audit\"}"
          stages {
            stage.match {
              expression = "stage != \"ResponseComplete\""
              action     = "drop"
            }
          }
        }

        # Drop leader-election / coordination noise
        stage.match {
          selector = "{job=\"k8s-audit\"}"
          stages {
            stage.match {
              expression = "resource == \"leases\" && code =~ \"^2\""
              action     = "drop"
            }
          }
        }

        # Drop successful WATCH (biggest remaining volume)
        stage.match {
          selector = "{job=\"k8s-audit\"}"
          stages {
            stage.match {
              expression = "verb == \"watch\" && code =~ \"^2\""
              action     = "drop"
            }
          }
        }

        # Drop successful reads
        stage.match {
          selector = "{job=\"k8s-audit\"}"
          stages {
            stage.match {
              expression = "(verb == \"get\" || verb == \"list\" || verb == \"watch\") && code =~ \"^2\""
              action     = "drop"
            }
          }
        }

        # LOW-cardinality labels only (prevents stream/cardinality explosion)
        stage.labels {
          values = {
            verb = "verb",
            code = "code",
          }
        }
      }

      loki.write "local" {
        endpoint {
          url = "http://loki.logging.svc.cluster.local:3100/loki/api/v1/push"
          headers = {
            "X-Scope-OrgID" = "1",
          }
        }
      }

  mounts:
    extra:
      - name: auditlog
        mountPath: /var/log/audit/kube
        readOnly: true
```
> Update the Loki URL if your Loki service name/namespace differs.


### 4.4 Install Alloy
```shell
helm upgrade --install alloy-audit grafana/alloy \
  -n logging \
  -f values-alloy-audit.yaml
```
### 4.5 Verify pods
```shell
kubectl -n logging get pods -l app.kubernetes.io/instance=alloy-audit
```
### 4.6 Validate the mount inside Alloy
```shell
pod=$(kubectl -n logging get pod -l app.kubernetes.io/instance=alloy-audit -o jsonpath='{.items[0].metadata.name}')
kubectl -n logging exec -it "$pod" -- sh -lc 'ls -lah /var/log/audit/kube | head'
```
- If this is empty or missing, the dashboard will never work.

### 5) Verify logs in Grafana Explore (must pass before dashboard work)

- In Grafana → Explore → Loki:

```shell
{job="k8s-audit"}
```

- You should see audit entries.

- If you want to confirm you have “security signal”, force some events:

```shell
kubectl -n default create secret generic audit-secret --from-literal=a=b
kubectl -n default delete secret audit-secret

kubectl -n default create role audit-role --verb=get --resource=pods
kubectl -n default delete role audit-role
```

- Then search:

```shell
{job="k8s-audit"} | json | objectRef_resource="secrets"
```
### 6) Dashboard philosophy (what makes it “enterprise”)

- An enterprise security dashboard is not “lots of panels”.
- It is a small number of panels that answer the most valuable questions fast:

- Layer 1 — Health/Volume 
  - “Is something weird happening right now?”

- Layer 2 — Access Failures 
  - “Is someone trying and failing (or misconfigured)?”

- Layer 3 — High-Risk Actions 
  - “Did someone do something high-impact or attacker-like?”

- Layer 4 — Drilldown Evidence 
  - “Show me the raw proof so I can investigate.”

That’s exactly why I pay more attention implementing those dashboards.

### 7) Row 1 — SOC Overview (situational awareness)
- Panel 1: Audit events/sec (cluster)

- What it answers:
  - “How busy is the Kubernetes API right now?” 
  - “Did something spike?”

- Why this panel exists:
- A sudden increase often correlates with:
  - runaway controllers 
  - deployment loops 
  - operator bugs 
  - scanning/probing 
  - cluster instability

- Query:

```shell
sum(
  rate({job="k8s-audit"} | json stage="stage" | stage="ResponseComplete" [5m])
)
```

- Visualization: Time series
- Unit: ops/s
- Legend: cluster

- How to use it (real ops):
  - If it spikes: check Row 1 Panel 2 (which node), Row 2 (denies), and drilldown table.

- Panel 2: Audit events/sec by node

- What it answers:
  - “Is one control-plane node behaving differently?”

- Why it exists:
  - Helps isolate issues:
    - one apiserver instance overloaded 
    - leader election behavior 
    - uneven traffic distribution

- Query:

```shell
sum by (node) (
  rate({job="k8s-audit"} | json stage="stage" | stage="ResponseComplete" [5m])
)
```

- Visualization: Time series
- Unit: ops/s
- Legend: {{node}}

- Panel 3: Non-2xx rate (errors)

- What it answers:
  - “Are requests failing, and how often?”

- Why it exists:
- Non-2xx rising means:
  - more auth failures (401/403)
  - bad requests (400)
  - not found (404)
  - API instability (5xx)

- Query:

```shell
sum(
  rate(
    {job="k8s-audit"}
    | json stage="stage", code="responseStatus.code"
    | stage="ResponseComplete"
    | code!~"^2"
  [5m])
)
```
- Visualization: Time series
- Unit: ops/s
- Legend: non-2xx

### 8) Row 2 — Access Control & Denies (auth posture)
- Panel 4: 401/403 rate (denied/unauthorized)

- What it answers:
  - “Is someone being denied access right now?”

- Why it exists:
  - This is your “RBAC friction detector”. In real orgs:
    - a broken workload starts failing after a RBAC change 
    - a user is probing resources they shouldn’t 
    - compromised token tries privileged actions

- Query:

```shell
sum(
  rate(
    {job="k8s-audit"}
    | json stage="stage", code="responseStatus.code"
    | stage="ResponseComplete"
    | code=~"401|403"
  [5m])
)
```
- Visualization: Time series
- Unit: ops/s
- Legend: 401/403

- Panel 5: Top denied verbs (401/403)

- What it answers:
  - “What action types are getting denied?” (get/list/watch vs create/delete)

- Why it exists:
  - Denied create/delete/patch signals higher risk than denied get.

- Query:

```shell
topk(10,
  sum by (verb) (
    rate(
      {job="k8s-audit"}
      | json stage="stage", code="responseStatus.code", verb="verb"
      | stage="ResponseComplete"
      | code=~"401|403"
    [5m])
  )
)
```
- Visualization: Time series (or bar gauge)
- Unit: ops/s
- Legend: {{verb}}

- Panel 6: Top denied users (401/403)

- What it answers:
  - “Which identity is failing the most?”

- Why it exists:
- Identifies:
  - misconfigured serviceaccounts 
  - suspicious users repeatedly denied

- Query:

```shell
topk(10,
  sum by (user) (
    rate(
      {job="k8s-audit"}
      | json stage="stage", code="responseStatus.code", user="user.username"
      | stage="ResponseComplete"
      | code=~"401|403"
    [5m])
  )
)
```
- Visualization: Time series
- Unit: ops/s
- Legend: {{user}}

### 9) Row 3 — High-Risk Changes (Enterprise Security Signals)

- This row is “enterprise” because it tracks classic high-impact actions.

- Panel 7: Pod exec / port-forward / attach — rate

- What it answers:
  - “Is someone getting interactive access into pods?” 
  - “Is someone bypassing normal ingress paths with port-forward?”

- Why it exists:
- This is one of the strongest post-exploitation signals:
  - attackers love pods/exec 
  - port-forward bypasses network controls 
  - attach can be used for debugging/compromise

- Query (cluster rate):

```shell
sum(
  rate(
    {job="k8s-audit"}
    | json stage="stage", sub="objectRef.subresource", uri="requestURI"
    | stage="ResponseComplete"
    | (sub=~"exec|portforward|attach" or uri=~".*/pods/[^/]+/(exec|portforward|attach).*")
  [5m])
```

- Visualization: Time series
- Unit: ops/s
- Panel name: Pod exec/port-forward/attach rate (cluster)
- Legend: exec/portforward/attach

- If you want by node: sum by (node)(rate(...)) and legend {{node}}.

- Panel 8: RBAC changes/sec (roles & bindings)

- What it answers:
  - “Is anyone changing permissions right now?”

- Why it exists:
- Privilege escalation often starts with:
  - creating/updating ClusterRoleBindings 
  - expanding permissions for a serviceaccount

- Query:

```shell
sum(
  rate(
    {job="k8s-audit"}
    | json stage="stage", verb="verb", res="objectRef.resource"
    | stage="ResponseComplete"
    | res=~"roles|rolebindings|clusterroles|clusterrolebindings"
    | verb=~"create|update|patch|delete|deletecollection"
  [5m])
)
```
- Visualization: Time series
- Unit: ops/s
- Panel name: RBAC changes/sec (roles & bindings)
- Legend: rbac_changes

- Panel 9: Secret writes/sec

- What it answers:
- “Are secrets being modified?”

- Why it exists:
  - Secrets modification can be:
    - credential rotation (legit)
    - credential theft / backdooring (malicious)

- Query:

```shell
sum(
  rate(
    {job="k8s-audit"}
    | json stage="stage", verb="verb", res="objectRef.resource"
    | stage="ResponseComplete"
    | res="secrets"
    | verb=~"create|update|patch|delete|deletecollection"
  [5m])
)
```

- Visualization: Time series
- Unit: ops/s
- Panel name: Secret writes/sec (create/update/patch/delete)
- Legend: secret_writes

### 10) Row 4 — Investigation (Evidence & Drilldown)
- Panel 10: Latest failures (>=300) — drilldown

- What it answers:
  - “Show me the latest suspicious or failing calls with context.”

- Why it exists:
- This is how you investigate quickly:
  - see exact user, verb, resource, uri, user-agent 
  - correlate to denies / errors above

- Query (your proven clean output):

```shell
{job="k8s-audit", node=~"$node"}
| json verb="verb", stage="stage", user="user.username",
       ns="objectRef.namespace", res="objectRef.resource",
       code="responseStatus.code", uri="requestURI", ua="userAgent"
| stage="ResponseComplete"
| code != ""
| code >= 300
| line_format "code={{.code}} verb={{.verb}} user={{.user}} ns={{.ns}} res={{.res}} uri={{.uri}} ua={{.ua}}"
```
- Visualization: Logs
- Panel name: Latest failures (>=300) — drilldown
- Notes:
  - ns can be empty because many resources are cluster-scoped (expected). 
  - No transformations needed. Transformations make this fragile.

### 11) “No data” vs “0” (what enterprise dashboards do)

- Some panels will often show no data because the action didn’t happen.
- That is normal.

- Recommendation:
  - Don’t force or vector(0) everywhere. 
  - If you want “flat zero”, use Grafana panel settings:
  - No value → 0 (or “null as zero” depending on panel type)

- Why? 
  - vector(0) sometimes creates confusing legends and merges series unexpectedly.

## 12) Naming / legends (so the dashboard reads professionally)
If legend shows `{}`:

- That means your query produces a single unlabeled series.
- Set the legend manually to something like:
  - cluster 
  - non-2xx 
  - 401/403 
  - rbac_changes 
  - secret_writes 
  - exec/portforward/attach 

- If query groups by label:

- Use legend format:
  - {{node}} 
  - {{verb}} 
  - {{user}}



### 13) Operational hardening (so Loki doesn’t fill up)

- Audit logs can be extremely noisy.

- Enterprise rule: keep what matters, drop what is pure spam.

- High-value signals to keep 
  - non-2xx responses 
  - create/update/patch/delete 
  - RBAC resources 
  - secrets 
  - exec/portforward/attach

- Common noise to drop (carefully)
  - leases spam (leader election)
  - repetitive watch/list/get for low-risk resources

- Apply drops only after validating dashboards still show important security activity.

### 14) Quick success checklist
- Alloy pod mounts /var/log/audit/kube 
- {job="k8s-audit"} returns logs in Explore 
- Row 1 panels show activity 
- Row 2 panels show denies when you intentionally test RBAC 
- Row 3 panels show signals when you generate RBAC/secret actions 
- Drilldown panel shows failures (>=300)

### 16) Quick step-by-step

- The following references are added for quick setup:
  - [Part of this docs involves loki setup](https://github.com/anselem-okeke/homelab/blob/main/docs/falco-security.md)
  - [Grafana Dashboard.json GitOps provisioning, IaC](https://github.com/anselem-okeke/homelab/blob/main/grafana/panels/talos-cilium-dashboard.provision.json)
  - [Grafana Dsahboard.json GitOps provisioning, IaC](https://github.com/anselem-okeke/homelab/blob/main/grafana/panels/audit-soc-dashboard.provision.json)
  - [Grafana Dashboard.json import only](https://github.com/anselem-okeke/homelab/blob/main/grafana/panels/talos-cilium-dashboard.import-newcopy.json)
  - [Grafana Dashboard.json import only](https://github.com/anselem-okeke/homelab/blob/main/grafana/panels/audit-soc-dashboard.import-newcopy.json)
  - [Step for simulating grafana audit SOC]()

