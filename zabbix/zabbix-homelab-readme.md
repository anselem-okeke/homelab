# Zabbix Homelab Infrastructure Monitoring

## Overview

This project implements an enterprise-style infrastructure monitoring setup using **Zabbix**.

The goal is to monitor Linux servers, Windows servers, network reachability, service ports, Docker containers, SNMP targets, dashboards, alerts, and controlled self-healing actions.

This setup is designed as a practical homelab project that demonstrates real infrastructure monitoring patterns used in DevOps, SRE, Platform Engineering, and IT Operations environments.

---

## Architecture Summary

The Zabbix stack runs on a Linux VM using Docker Compose.

Core components:

- Zabbix Server
- Zabbix Web UI
- PostgreSQL database
- Zabbix Agent 2
- Linux host agent
- Windows host agent
- ICMP network checks
- TCP service checks
- Docker monitoring
- SNMP monitoring
- Self-healing recovery scripts

High-level flow:

```text
Linux / Windows / Network / Docker / SNMP Targets
        ↓
Zabbix Agent 2 / ICMP / TCP / SNMP
        ↓
Zabbix Server
        ↓
PostgreSQL Database
        ↓
Zabbix Web UI
        ↓
Dashboards / Problems / Alerts / Recovery Actions
```

---

## Monitoring Scope

| Area | Tooling |
|---|---|
| Linux host metrics | Zabbix Agent 2 |
| Windows host metrics | Zabbix Agent 2 |
| Network reachability | ICMP Ping template |
| Service availability | TCP simple checks |
| Docker containers | Zabbix Agent 2 Docker monitoring |
| SNMP targets | SNMP templates |
| Alerting | Zabbix trigger actions |
| Self-healing | Zabbix remote command + recovery scripts |

---

## Project Structure

Recommended structure:

```text
homelab/
└── zabbix/
    └── linux-vm/
        ├── docker-compose.yml
        ├── zabbix-agent2.sh
        ├── update-zabbix.sh
        ├── recovery/
        │   └── restart-zabbix-web.sh
        └── docs/
            ├── README.md
            ├── architecture.md
            ├── setup-guide.md
            ├── monitored-assets.md
            ├── dashboards.md
            ├── alerting-policy.md
            ├── service-monitoring.md
            ├── docker-monitoring.md
            ├── snmp-monitoring.md
            ├── self-healing.md
            └── runbooks/
                ├── zabbix-agent-unavailable.md
                ├── host-unreachable.md
                ├── high-packet-loss.md
                ├── zabbix-web-down.md
                ├── docker-container-down.md
                └── disk-space-high.md
```

---

## Implementation Phases

### Phase 1 — Deploy Zabbix Server with Docker Compose

The Zabbix stack was deployed using Docker Compose.

Main services:

- `postgres`
- `zabbix-server`
- `zabbix-web`
- `zabbix-agent2`

The Zabbix Web UI was exposed on a non-conflicting host port after port `8080` was already in use.

Example:

```yaml
ports:
  - "8081:8080"
```

Access:

```text
http://<zabbix-server-ip>:8081
```

Default login:

```text
Username: Admin
Password: zabbix
```

---

### Phase 2 — Add Linux VM Monitoring with Zabbix Agent 2

Zabbix Agent 2 was installed directly on the Linux host to monitor the real VM, not only the container.

Installation script used:

```bash
#!/bin/bash

# Exit immediately if any command fails
set -e

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script with sudo."
  exit 1
fi

# Install Zabbix repository
wget -q https://repo.zabbix.com/zabbix/7.4/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.4+debian13_all.deb
dpkg -i zabbix-release_latest_7.4+debian13_all.deb
rm zabbix-release_latest_7.4+debian13_all.deb
apt-get update

# Install Zabbix agent 2 and plugins
apt-get install -y zabbix-agent2 \
  zabbix-agent2-plugin-mongodb \
  zabbix-agent2-plugin-mssql \
  zabbix-agent2-plugin-postgresql

# Enable and start Zabbix agent 2
systemctl enable --now zabbix-agent2
```

Agent update/configuration script used:

```bash
#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "Please run this script with sudo."
  exit 1
fi

CONF_FILE="/etc/zabbix/zabbix_agent2.conf"

if [ ! -f "$CONF_FILE" ]; then
  echo "Error: $CONF_FILE not found."
  exit 1
fi

# Backup original config
cp "$CONF_FILE" "${CONF_FILE}.bak.$(date +%F-%H%M%S)"

# Update passive check server list
if grep -q "^Server=" "$CONF_FILE"; then
  sed -i 's|^Server=.*|Server=127.0.0.1,172.18.0.0/16,192.168.0.58|' "$CONF_FILE"
else
  echo "Server=127.0.0.1,172.18.0.0/16,192.168.0.58" >> "$CONF_FILE"
fi

# Update active check server
if grep -q "^ServerActive=" "$CONF_FILE"; then
  sed -i 's|^ServerActive=.*|ServerActive=192.168.0.58|' "$CONF_FILE"
else
  echo "ServerActive=192.168.0.58" >> "$CONF_FILE"
fi

# Update hostname
if grep -q "^Hostname=" "$CONF_FILE"; then
  sed -i 's|^Hostname=.*|Hostname=linux-vm|' "$CONF_FILE"
else
  echo "Hostname=linux-vm" >> "$CONF_FILE"
fi

systemctl restart zabbix-agent2
systemctl enable zabbix-agent2

echo "Zabbix Agent 2 configuration updated successfully."
echo
echo "Current important config:"
grep -E '^(Server|ServerActive|Hostname)=' "$CONF_FILE"
```

Important final Linux agent configuration:

```ini
Server=127.0.0.1,172.18.0.0/16,192.168.0.58
ServerActive=192.168.0.58
Hostname=linux-vm
```

Validation commands:

```bash
systemctl status zabbix-agent2
sudo ss -lntp | grep 10050
docker exec -it zabbix-server sh -c "nc -zv 192.168.0.58 10050"
```

---

### Phase 3 — Add Windows VM Monitoring with Zabbix Agent 2

A Windows VM was added with Zabbix Agent 2.

Example host details:

```text
Host name: windows-vm
IP address: 192.168.0.56
Port: 10050
Template: Windows by Zabbix agent
```

Windows firewall rule:

```powershell
New-NetFirewallRule `
  -DisplayName "Allow Zabbix Agent 2 Inbound" `
  -Direction Inbound `
  -Protocol TCP `
  -LocalPort 10050 `
  -Action Allow
```

Useful validation:

```powershell
Get-Service *zabbix*
netstat -ano | findstr :10050
```

From Linux:

```bash
nc -zv 192.168.0.56 10050
docker exec -it zabbix-server sh -c "nc -zv 192.168.0.56 10050"
```

---

### Phase 4 — Add Gateway and Network ICMP Monitoring

ICMP monitoring was added for network visibility.

Example targets:

| Target | IP | Purpose |
|---|---:|---|
| Gateway / Router | `192.168.0.1` | LAN gateway reachability |
| Windows VM - Main Adapter | `192.168.0.56` | Main Windows network path |
| Windows VM - Secondary Adapter | `192.168.30.193` | Secondary network path |
| Internet - Google DNS | `8.8.8.8` | Internet reachability |
| Internet - Cloudflare DNS | `1.1.1.1` | Internet reachability |

Template used:

```text
ICMP Ping
```

Metrics collected:

- ICMP ping status
- ICMP response time
- ICMP packet loss

---

### Phase 5 — Build Homelab Infrastructure Dashboard

A Zabbix dashboard was created to give a single operational view.

Dashboard name:

```text
Homelab Infrastructure Overview
```

Recommended sections:

```text
1. Current Problems
2. Host Availability
3. Network Reachability
4. Latency and Packet Loss
5. Linux Server Health
6. Windows Server Health
7. Service Availability
8. Docker / Container Health
9. SNMP / Network Device Health
```

Example widgets:

- Current Problems
- Host Availability
- ICMP Ping Status
- Gateway Latency
- Internet Latency
- Packet Loss
- Linux CPU Utilization
- Linux Memory Usage
- Linux Disk Usage
- Windows CPU Utilization
- Windows Memory Usage
- Windows Disk Usage
- Docker Container Status

---

### Phase 6 — Configure Alerts and Notifications

Alerting was configured so Zabbix can notify when actionable problems occur.

Recommended alert conditions:

| Alert | Severity |
|---|---|
| Zabbix agent unavailable | Average |
| Host unreachable by ICMP | High |
| ICMP packet loss high | Warning |
| Disk usage above 85% | Warning |
| Disk usage above 95% | High |
| CPU above 90% for 5 minutes | Warning |
| Memory above 90% | Warning |
| Zabbix Web UI unavailable | High |

Alert flow:

```text
Trigger fires
    ↓
Problem created
    ↓
Notification sent
    ↓
Recovery notification sent when resolved
```

---

### Phase 7 — Add Service and Port Monitoring

Service-level checks were added using Zabbix simple checks.

Examples:

| Service | Host | Port |
|---|---|---:|
| SSH | Linux VM | 22 |
| Zabbix Agent | Linux VM | 10050 |
| Zabbix Agent | Windows VM | 10050 |
| RDP | Windows VM | 3389 |
| Zabbix Server | Linux VM | 10051 |
| Zabbix Web | Linux VM | 8081 |

Example item key:

```text
net.tcp.service[tcp,,22]
```

Return values:

```text
1 = service reachable
0 = service unavailable
```

Example trigger:

```text
last(/linux-vm/net.tcp.service[tcp,,8081])=0
```

---

### Phase 8 — Docker Container Monitoring

Docker monitoring was added using Zabbix Agent 2 on the Linux Docker host.

Important steps:

```bash
ls -l /var/run/docker.sock
id zabbix
sudo usermod -aG docker zabbix
sudo systemctl restart zabbix-agent2
sudo -u zabbix docker ps
zabbix_agent2 -t docker.ping
```

Expected:

```text
docker.ping [s|1]
```

Important monitored containers:

| Container | Purpose |
|---|---|
| zabbix-postgres | Zabbix database |
| zabbix-server | Zabbix backend |
| zabbix-web | Zabbix web UI |
| zabbix-agent2 | Container test agent |

---

### Phase 9 — SNMP Monitoring

SNMP monitoring was introduced for network-style device visibility.

Initial router test:

```bash
sudo apt update
sudo apt install -y snmp snmp-mibs-downloader
snmpwalk -v2c -c public 192.168.0.1 system
```

If the router does not support SNMP, a Linux SNMP lab target can be used.

Example SNMP daemon setup:

```bash
sudo apt update
sudo apt install -y snmpd snmp
sudo nano /etc/snmp/snmpd.conf
```

Example config:

```conf
agentAddress udp:161,udp6:[::1]:161

rocommunity public 127.0.0.1
rocommunity public 192.168.0.0/24

sysLocation Homelab
sysContact Anselem
```

Restart:

```bash
sudo systemctl restart snmpd
sudo systemctl enable snmpd
```

Validate:

```bash
snmpwalk -v2c -c public localhost system
snmpwalk -v2c -c public 192.168.0.58 system
```

---

### Phase 10 — Self-Healing Automation

A controlled self-healing workflow was implemented.

Use case:

```text
If Zabbix Web UI becomes unavailable, restart the zabbix-web container.
```

Recovery flow:

```text
Zabbix detects port 8081 unavailable
    ↓
Trigger creates problem
    ↓
Zabbix action executes remote command
    ↓
Linux host runs recovery script
    ↓
Docker starts zabbix-web container
    ↓
Zabbix Web becomes reachable
    ↓
Problem resolves
```

Recovery script path:

```text
/opt/zabbix-recovery/restart-zabbix-web.sh
```

Sudoers rule:

```text
zabbix ALL=(root) NOPASSWD: /opt/zabbix-recovery/restart-zabbix-web.sh
```

Agent config requirement:

```ini
AllowKey=system.run[*]
```

Manual test:

```bash
docker stop zabbix-web
sudo tail -n 50 /var/log/zabbix-recovery.log
docker ps | grep zabbix-web
```

---

## Documentation Index

Recommended documentation files:

- [Architecture](architecture.md)
- [Setup Guide](setup-guide.md)
- [Monitored Assets](monitored-assets.md)
- [Dashboards](dashboards.md)
- [Alerting Policy](alerting-policy.md)
- [Service Monitoring](service-monitoring.md)
- [Docker Monitoring](docker-monitoring.md)
- [SNMP Monitoring](snmp-monitoring.md)
- [Self-Healing Automation](self-healing.md)

Recommended runbooks:

- [Zabbix Agent Unavailable](runbooks/zabbix-agent-unavailable.md)
- [Host Unreachable](runbooks/host-unreachable.md)
- [High Packet Loss](runbooks/high-packet-loss.md)
- [Zabbix Web Down](runbooks/zabbix-web-down.md)
- [Docker Container Down](runbooks/docker-container-down.md)
- [Disk Space High](runbooks/disk-space-high.md)

---

## Operational Model

This project follows the operational model:

```text
Detect → Alert → Investigate → Recover → Verify → Document
```

This is the core idea behind production-style monitoring.

---

## Troubleshooting Commands

### Zabbix Stack

```bash
docker compose ps
docker logs zabbix-server --tail=100
docker logs zabbix-web --tail=100
docker logs zabbix-postgres --tail=100
```

### Agent Connectivity

```bash
sudo systemctl status zabbix-agent2
sudo ss -lntp | grep 10050
grep -E '^(Server|ServerActive|Hostname)=' /etc/zabbix/zabbix_agent2.conf
docker exec -it zabbix-server sh -c "nc -zv <host-ip> 10050"
```

### Network Checks

```bash
ping -c 4 <host-ip>
ip route get <host-ip>
ip neigh | grep <host-ip>
nc -zv <host-ip> <port>
traceroute <host-ip>
sudo tcpdump -i <interface> host <host-ip>
```

### Docker Checks

```bash
docker ps -a
docker inspect <container-name>
docker logs <container-name> --tail=100
docker compose ps
```

### SNMP Checks

```bash
snmpwalk -v2c -c public <host-ip> system
sudo systemctl status snmpd
sudo ss -lunp | grep 161
```

---

## Success Criteria

This project is complete when:

- Linux host metrics are visible
- Windows host metrics are visible
- ICMP network checks are visible
- Service port checks are visible
- Docker container checks are visible
- SNMP metrics are visible
- Dashboard shows infrastructure status
- Alerts are configured
- Self-healing action works for Zabbix Web
- Runbooks exist for common failures

---

## Professional Value

This project demonstrates:

- Infrastructure monitoring
- Linux and Windows observability
- Network reachability monitoring
- Service availability checks
- Docker runtime monitoring
- SNMP-based network monitoring
- Alerting and incident lifecycle
- Controlled self-healing automation
- Operational documentation and runbooks

It is suitable for demonstrating practical skills in:

- DevOps Engineering
- Site Reliability Engineering
- Platform Engineering
- Infrastructure Operations
- Systems Administration
- Monitoring and Observability
