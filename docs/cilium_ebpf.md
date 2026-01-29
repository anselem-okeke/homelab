### Cilium eBPF Map Pressure in Grafana (Panels + Alerts) — Setup Notes

![img](../img/cilium_dashboard2.gif)

This doc captures what I configured and why, for monitoring **Cilium eBPF map pressure** (`cilium_bpf_map_pressure`) in Grafana, plus how to build a reliable **“>80% for 5m”** alert.

---

#### Prerequisites (must be true before panels/alerts work)

- Cilium installed with **Prometheus metrics enabled** (cilium-agent exposes `/metrics`)
- Prometheus is running and **scraping Cilium** (Target shows **UP**) via **ServiceMonitor/PodMonitor** (Prometheus Operator) or **static scrape config**
- Grafana has the **correct Prometheus datasource**
- Metric exists in Explore

---
#### What `cilium_bpf_map_pressure` means

- Metric: `cilium_bpf_map_pressure`
- Meaning: **how full a Cilium eBPF map is**
  - roughly: `entries_in_use / max_entries`
- Value range:
  - `0.0` = empty
  - `1.0` = full
- I used Grafana unit:
  - **Percent (0.0–1.0)** so **0.07** renders as **7%**

#### Why does this matter
- If critical maps (CT / LB / NAT / IPCache) approach full capacity, networking can degrade:
  - connection failures / timeouts
  - increased drops (seen in Hubble)
  - unstable service routing (LB/NAT issues)

---

#### Why “cluster” vs “by node” when you have one cluster

“Cluster” here means **aggregated across all nodes** in your one cluster.

- **Cluster panel:** worst pressure per map type across the whole cluster.
- **By node panel:** worst pressure per map type *per node* (to catch a hot node).

---

#### BPF Map Pressure Panels

#### Panel A — Top pressured maps (cluster)

**Title:** `BPF map pressure — Top 10 (cluster)`  
**Visualization:** Time series  
**Query:**
```shell
topk(10, max by (map_name) (cilium_bpf_map_pressure))
```
Legend: `{{map_name}}`

Standard options

- Unit: `Percent (0.0-1.0)`

- Min: 0

- Max: 1

- Decimals: 2 
  - Answers: Which map types are closest to full overall?

#### Panel B — Top pressured maps (by node)
#### Title: `BPF map pressure — Top 10 (by node)`
**Visualization:** Time series
#### Query:

```shell
topk(10, max by (node, map_name) (cilium_bpf_map_pressure))
```

Legend: `{{node}} / {{map_name}}`

Standard options

- Unit: `Percent (0.0-1.0)`

- Min: 0

- Max: 1

- Decimals: 2 
  - Answers: Is one node becoming a bottleneck?

#### Thresholds (Visualization coloring)
- Thresholds mode: Absolute
- Use these values (ratio scale 0–1):

  - 0.70 = warning

  - 0.80 = high

  - 0.90 = critical

  - 1.00 = full

> Note: thresholds are numeric only. 
> Colors are set by clicking the colored dots next to `Base` and each threshold row.



- Why “Policy-only Panel C” returned no data
- I tried:


```shell
cilium_bpf_map_pressure{map_name=~".*policy.*"}
```
- But discovery showed exported `map_name` values do not include `policy/lpm`.

- Discovery query (Explore)

````shell
topk(200, max by (map_name) (cilium_bpf_map_pressure))
````
I observed map names:

- `ct4_global`

- `ct_any4_global`

- `lb4_services_v2`

- `lb4_backends_v3`

- `lb4_reverse_nat`

- `lxc`

- `ipcache_v2`

So Panel C must match what exists in your cluster.

#### Recommended Panel C (Outage prevention filter)
- Focus on maps that usually cause real incidents when full: CT + LB/NAT + IPCache.


```shell
topk(10, max by (node, map_name) (
  cilium_bpf_map_pressure{map_name=~"ct.*|lb4_.*|ipcache_.*|lxc"}
))
```
- Legend: `{{node}} / {{map_name}}`
- Thresholds: same as A/B 
  - Answers: Are we approaching a real networking incident on any node?

- Check Cilium version

```shell
kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```
- Example output:
  - quay.io/cilium/cilium:v1.18.6@sha256:...
  - → Version is v1.18.6

- Optional confirm from inside pod:


```shell
POD=$(kubectl -n kube-system get pod -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec -it "$POD" -- cilium version
```
#### Alert: “BPF map pressure high (>80% for 5m)”
- Recommended rule style (keeps node + map labels)
- Query (Instant)

```shell
max by (node, map_name) (cilium_bpf_map_pressure)
```
Alert condition
- IS ABOVE `0.8`

- Evaluation 
  - Evaluate every: `1m` 
  - Pending period (For): `5m`

- This gives per-series alert instances, so you can see exactly:

  - which `node`

  - which `map_name`

- Notification templating: what `{{ $labels.node }} / {{ $labels.map_name }}` means
- These are placeholders Grafana replaces with the actual series labels that triggered the alert.

- Example output:
  - `talos-cfi-xtb / ct4_global`

- Recommended message fields
- Summary


```shell
BPF map pressure high
```
- Description
```shell
{{ $labels.node }} / {{ $labels.map_name }} is above 80% for 5 minutes.
```



- (Optional) include current value if your Grafana supports it:


```shell
Current value: {{ $values.A }}
```
- Testing the alert (safe + fast)
  - Step 1 — Lower threshold temporarily
    - Change alert condition:
      - `0.8` → `0.01` (or `0.05`)

  - Step 2 — Reduce pending period 
    - Pending period: `5m` → `None` or `1m`

  - Step 3 — Save 
    - Alert should go Pending → Firing quickly.

  - Step 4 — Revert to production settings 
    - Threshold back to `0.8` 
    - Pending period back to `5m` 
    - Save again

> Important: panel thresholds vs alert thresholds 
> - Panel thresholds (Field → Thresholds) only affect chart colors.
> - Alert thresholds are set in the alert rule’s Alert condition.
> - Changing panel thresholds does not test the alert.

