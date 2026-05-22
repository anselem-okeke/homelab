# Zabbix Homelab Monitoring & Alerts Setup

This document describes the monitoring and alerting setup implemented for the Zabbix homelab environment.

## 1. Final Architecture

```text
Windows / Linux / Network Devices
        |
        | Agent / ICMP / HTTP / Port checks
        v
Zabbix Server running in Docker
        |
        +--> PostgreSQL database
        +--> Zabbix Web UI
        +--> Email alerting
        +--> Dashboard widgets
```

## 2. Environment Used

| Component | Value |
|---|---|
| Zabbix Server | Docker container |
| Zabbix Web UI | `http://192.168.0.58:8081` |
| Zabbix Server IP | `192.168.0.58` |
| WIN11 IP | `192.168.0.56` |
| Gateway / Router | `192.168.0.1` |
| Google DNS check | `8.8.8.8` |
| Cloudflare DNS check | `1.1.1.1` |
| Zabbix server port | `10051` |
| Zabbix agent port | `10050` |

Running containers:

```bash
docker ps
```

Expected containers:

```text
zabbix-web
zabbix-server
zabbix-postgres
zabbix-agent2
```

---

# Phase 1 — Verify Zabbix Server and Web UI

## 1.1 Check Zabbix containers

On the Linux/Zabbix server:

```bash
docker ps
```

Expected:

```text
zabbix-server   0.0.0.0:10051->10051/tcp
zabbix-web      0.0.0.0:8081->8080/tcp
zabbix-postgres 5432/tcp
zabbix-agent2   10050/tcp
```

## 1.2 Check Zabbix server port

```bash
sudo ss -tunlp | grep :10051
```

Expected:

```text
LISTEN 0.0.0.0:10051
```

## 1.3 Access Zabbix UI

Open in browser:

```text
http://192.168.0.58:8081
```

Do not open port `10051` in the browser. Port `10051` is for Zabbix agent/proxy communication, not the web UI.

---

# Phase 2 — Add Linux Host Monitoring

The Linux VM / Docker host is monitored using Zabbix Agent.

## 2.1 Confirm Linux agent container

```bash
docker ps | grep zabbix-agent2
```

## 2.2 Add Linux host in Zabbix

Go to:

```text
Data collection → Hosts → Create host
```

Use:

| Field | Value |
|---|---|
| Host name | `Linux VM - Docker Host` |
| Host group | `Linux servers` |
| Interface type | Agent |
| IP address | `192.168.0.58` |
| Port | `10050` |
| Template | `Linux by Zabbix agent` |

Then click **Add**.

## 2.3 Verify host availability

Go to:

```text
Data collection → Hosts
```

Expected:

```text
ZBX = green
```

---

# Phase 3 — Add Windows Host Monitoring

WIN11 and ANSELEM-SERVER are monitored using Zabbix Agent 2.

## 3.1 Install Zabbix Agent 2 on Windows

During installation, use:

| Field | Value |
|---|---|
| Host name | `WIN11` |
| Zabbix server IP/DNS | `192.168.0.58` |
| Agent listen port | `10050` |
| Server or Proxy for active checks | `192.168.0.58` |
| Enable PSK | unchecked for lab |
| Add agent location to PATH | checked |

## 3.2 Confirm Windows agent service

Run PowerShell as Administrator:

```powershell
Get-Service "Zabbix Agent 2"
```

Start and enable if needed:

```powershell
Start-Service "Zabbix Agent 2"
Set-Service "Zabbix Agent 2" -StartupType Automatic
```

## 3.3 Open Windows firewall

```powershell
New-NetFirewallRule `
  -Name "Zabbix Agent 2" `
  -DisplayName "Zabbix Agent 2" `
  -Enabled True `
  -Direction Inbound `
  -Protocol TCP `
  -Action Allow `
  -LocalPort 10050
```

## 3.4 Add WIN11 in Zabbix

Go to:

```text
Data collection → Hosts → Create host
```

Use:

| Field | Value |
|---|---|
| Host name | `WIN11` |
| Visible name | `WIN11` |
| Host group | `window servers` |
| Interface type | Agent |
| IP address | `192.168.0.56` |
| Port | `10050` |
| Template | `Windows by Zabbix agent` |

Then click **Add**.

## 3.5 Confirm Windows data

Go to:

```text
Monitoring → Latest data
```

Filter:

```text
Host: WIN11
```

Expected values:

```text
Zabbix agent ping: Up (1)
Zabbix agent availability: available (1)
CPU data
Memory data
Disk data
Service data
```

---

# Phase 4 — Add ICMP Network Monitoring

ICMP hosts are used to monitor reachability of network devices and internet targets.

## 4.1 Create or use host group

Use existing group:

```text
Network Devices
```

If missing, create it from the host group selector.

## 4.2 Add Gateway / Router

Go to:

```text
Data collection → Hosts → Create host
```

Use:

| Field | Value |
|---|---|
| Host name | `gateway-router` |
| Visible name | `Gateway / Router` |
| Host group | `Network Devices` |
| Template | `ICMP Ping` |
| Interface type | Agent |
| IP address | `192.168.0.1` |
| Port | `10050` |

The port is not used by ICMP, but Zabbix requires an interface field.

## 4.3 Add Windows main adapter ICMP check

| Field | Value |
|---|---|
| Host name | `windows-vm-icmp-main` |
| Visible name | `Windows VM - Main Adapter` |
| Host group | `Network Devices` |
| Template | `ICMP Ping` |
| IP address | `192.168.0.56` |
| Port | `10050` |

## 4.4 Add internet reachability checks

Google DNS:

| Field | Value |
|---|---|
| Host name | `internet-google-dns` |
| Visible name | `Internet Reachability - Google DNS` |
| Host group | `Network Devices` |
| Template | `ICMP Ping` |
| IP address | `8.8.8.8` |

Cloudflare DNS:

| Field | Value |
|---|---|
| Host name | `internet-cloudflare-dns` |
| Visible name | `Internet Reachability - Cloudflare DNS` |
| Host group | `Network Devices` |
| Template | `ICMP Ping` |
| IP address | `1.1.1.1` |

## 4.5 Verify ICMP data

Go to:

```text
Monitoring → Latest data
```

Filter:

```text
Host group: Network Devices
```

Expected items:

```text
ICMP ping
ICMP loss
ICMP response time
```

Good values:

```text
ICMP ping: Up (1)
ICMP loss: 0 %
ICMP response time: low ms value
```

---

# Phase 5 — Build Homelab Infrastructure Dashboard

The dashboard was built to show infrastructure health, reachability, active problems, and core system metrics.

## 5.1 Current Problems widget

Add widget:

| Field | Value |
|---|---|
| Type | `Problems` |
| Name | `Current Problems` |
| Show | Recent problems or Problems |
| Refresh interval | Default |

Purpose:

```text
Shows active and recent infrastructure problems.
```

## 5.2 Host Availability widget

Add widget:

| Field | Value |
|---|---|
| Type | `Host availability` |
| Name | `Host Availability` |
| Host groups | `Linux servers`, `window servers`, `Zabbix servers` |
| Interface type | Zabbix agent active + passive checks |
| Layout | Horizontal |

Expected final status:

```text
Available: 4
Not available: 0
Unknown: 0
Total: 4
```

## 5.3 Network Reachability widget

Add widget:

| Field | Value |
|---|---|
| Type | `Data overview` |
| Name | `Network Reachability` |
| Host group | `Network Devices` |
| Item tags | `component contains network` |

This shows ICMP-related values such as:

```text
ICMP ping
ICMP loss
ICMP response time
```

## 5.4 Gateway latency graph

Add widget:

| Field | Value |
|---|---|
| Type | `Graph` |
| Name | `Gateway Latency` |
| Host pattern | `Gateway / Router` |
| Item pattern | `ICMP response time` |

## 5.5 Internet latency graph

Add widget:

| Field | Value |
|---|---|
| Type | `Graph` |
| Name | `Internet Latency` |
| Host pattern | `Internet Reachability - Google DNS` |
| Item pattern | `ICMP response time` |

## 5.6 Linux CPU widget

| Field | Value |
|---|---|
| Type | `Graph` |
| Name | `Linux CPU Utilization` |
| Host pattern | `Linux VM - Docker Host` |
| Item pattern | `CPU utilization` |

## 5.7 Linux memory widget

| Field | Value |
|---|---|
| Type | `Graph` |
| Name | `Linux Memory Usage` |
| Host pattern | `Linux VM - Docker Host` |
| Item pattern | `Memory utilization` |

## 5.8 Linux disk widget

Use this item discovered from Latest data:

```text
FS [/]: Space: Used, in %
```

Widget:

| Field | Value |
|---|---|
| Type | `Graph` |
| Name | `Linux Disk Usage` |
| Host pattern | `Linux VM - Docker Host` |
| Item pattern | `FS [/]: Space: Used, in %` |

## 5.9 Windows CPU / Memory / Disk widgets

Create separate graph widgets:

```text
Windows CPU Utilization
Windows Memory Usage
Windows Disk Usage
```

Use host patterns:

```text
WIN11
ANSELEM-SERVER
```

Use item patterns:

```text
CPU utilization
Memory utilization
Space: Used, in %
```

## 5.10 WIN11 Reachability widget

Use a compact Top hosts widget.

| Field | Value |
|---|---|
| Type | `Top hosts` |
| Name | `WIN11 Reachability` |
| Hosts | `WIN11`, `Windows VM - Main Adapter` |

Columns:

| Column | Item |
|---|---|
| Agent | `Zabbix agent ping` |
| ICMP | `ICMP ping` |

Expected:

```text
Agent: Up (1.00)
ICMP: Up (1.00)
```

---

# Phase 6 — Configure Email Alerting

## 6.1 Fix CA certificates inside Zabbix container

The initial SMTP error was:

```text
SSL certificate OpenSSL verify result: unable to get local issuer certificate (20)
```

Fix by entering the Zabbix server container as root:

```bash
docker exec -u 0 -it zabbix-server sh
```

Inside container:

```sh
apk update
apk add --no-cache ca-certificates openssl
update-ca-certificates
exit
```

Restart Zabbix server:

```bash
docker restart zabbix-server
```

Verify TLS:

```bash
docker exec -u 0 -it zabbix-server sh
```

Inside container:

```sh
openssl s_client -connect smtp.gmail.com:587 -starttls smtp -servername smtp.gmail.com
```

Expected:

```text
Verify return code: 0 (ok)
```

## 6.2 Configure email media type

Go to:

```text
Alerts → Media types → Create media type
```

Use:

| Field | Value |
|---|---|
| Name | `Zabbix alert` |
| Type | `Email` |
| Email provider | `Generic SMTP` |
| SMTP server | `smtp.gmail.com` |
| SMTP server port | `587` |
| Email | your Gmail address |
| SMTP helo | `gmail.com` |
| Connection security | `STARTTLS` |
| SSL verify peer | unchecked for lab |
| SSL verify host | unchecked for lab |
| Authentication | `Username and password` |
| Username | your full Gmail address |
| Password | Gmail app password |
| Message format | Plain text or HTML |

Test the media type.

Expected:

```text
Media type test successful
```

---

# Phase 7 — Add Message Templates

If Zabbix says:

```text
No message defined for media type
```

then message templates are missing.

Go to:

```text
Alerts → Media types → Zabbix alert → Message templates
```

## 7.1 Problem template

| Field | Value |
|---|---|
| Message type | `Problem` |
| Subject | `Problem: {EVENT.NAME}` |

Message:

```text
Problem started at {EVENT.TIME} on {EVENT.DATE}

Problem: {EVENT.NAME}
Host: {HOST.NAME}
Severity: {EVENT.SEVERITY}
Operational data: {EVENT.OPDATA}

Original problem ID: {EVENT.ID}
```

## 7.2 Problem recovery template

| Field | Value |
|---|---|
| Message type | `Problem recovery` |
| Subject | `Resolved: {EVENT.NAME}` |

Message:

```text
Problem resolved at {EVENT.RECOVERY.TIME} on {EVENT.RECOVERY.DATE}

Problem: {EVENT.NAME}
Host: {HOST.NAME}
Severity: {EVENT.SEVERITY}
Duration: {EVENT.DURATION}

Original problem ID: {EVENT.ID}
```

## 7.3 Problem update template

| Field | Value |
|---|---|
| Message type | `Problem update` |
| Subject | `Updated: {EVENT.NAME}` |

Message:

```text
Problem updated at {EVENT.UPDATE.TIME} on {EVENT.UPDATE.DATE}

Problem: {EVENT.NAME}
Host: {HOST.NAME}
Severity: {EVENT.SEVERITY}

Update message:
{EVENT.UPDATE.MESSAGE}

Updated by: {USER.FULLNAME}
```

Save the media type.

---

# Phase 8 — Assign Email Media to Admin User

Go to:

```text
Users → Users → Admin → Media
```

Add media:

| Field | Value |
|---|---|
| Type | `Zabbix alert` |
| Send to | your email address |
| When active | `1-7,00:00-24:00` |
| Use if severity | select all for testing |
| Enabled | checked |

Select all severities during testing:

```text
Not classified
Information
Warning
Average
High
Disaster
```

This is important because many discovered Windows service problems are `Average` severity.

---

# Phase 9 — Create Trigger Action

Go to:

```text
Alerts → Actions → Trigger actions → Create action
```

## 9.1 Action tab

| Field | Value |
|---|---|
| Name | `Notify Admin on Infrastructure Problems` |
| Enabled | checked |

Condition:

```text
Trigger severity is greater than or equals Warning
```

Keep conditions simple at first. Do not add host group filters until alerting is confirmed.

## 9.2 Operations tab

Set:

```text
Default operation step duration: 1h
```

Add operation:

| Field | Value |
|---|---|
| Operation | Send message |
| Steps | `1 - 1` |
| Step duration | `0` |
| Send to users | `Admin (Zabbix Administrator)` |
| Send to media type | `Zabbix alert` |
| Conditions | none |

Important:

Do not add this condition for normal alerts:

```text
Event is acknowledged
```

That condition would delay or block normal alert delivery.

## 9.3 Recovery operations

Add recovery operation:

| Field | Value |
|---|---|
| Send to users | `Admin (Zabbix Administrator)` |
| Send to media type | `Zabbix alert` |

## 9.4 Update operations

Optional but useful:

| Field | Value |
|---|---|
| Send to users | `Admin (Zabbix Administrator)` |
| Send to media type | `Zabbix alert` |

Save the action.

---

# Phase 10 — Test Alerting

## 10.1 Safe Linux agent test

Because Linux agent runs as Docker container, use:

```bash
docker stop zabbix-agent2
```

Wait 3–5 minutes.

Go to:

```text
Monitoring → Problems
```

Expected:

```text
Linux: Zabbix agent is not available
```

Check email inbox.

Then recover:

```bash
docker start zabbix-agent2
```

Expected:

```text
Recovery email received
```

## 10.2 Safe Windows agent test

On WIN11 PowerShell as Administrator:

```powershell
Stop-Service "Zabbix Agent 2"
```

Wait 3–5 minutes.

Expected problem:

```text
WIN11: Zabbix agent is not available
```

Recover:

```powershell
Start-Service "Zabbix Agent 2"
```

Expected:

```text
Recovery email received
```

---

# Phase 11 — Troubleshooting Alert Delivery

## 11.1 Check Action log

Go to:

```text
Reports → Action log
```

or:

```text
Alerts → Action log
```

Interpretation:

| Status | Meaning |
|---|---|
| Sent | Zabbix sent the email successfully |
| Failed | Delivery/media/user configuration problem |
| No entry | Action condition did not match |
| In progress | Zabbix is retrying |

## 11.2 Common fixes

| Problem | Fix |
|---|---|
| Media test works but action fails | Use the same media type in action operations |
| `No message defined for media type` | Add Problem / Recovery / Update message templates |
| No action log entry | Simplify action condition to severity >= Warning |
| Failed delivery | Click red info icon in Action log |
| No email for existing problem | Create a new problem event after action is created |
| Severity mismatch | Select all severities in Admin media |
| Wrong Linux test command | Use `docker stop zabbix-agent2`, not `systemctl` |

---

# Phase 12 — Current Working Status

The final setup includes:

```text
✅ Zabbix Server running in Docker
✅ Zabbix Web UI available
✅ PostgreSQL backend running
✅ Linux VM / Docker host monitored
✅ WIN11 monitored
✅ ANSELEM-SERVER monitored
✅ Gateway ICMP check
✅ Google DNS ICMP check
✅ Cloudflare DNS ICMP check
✅ Host availability dashboard
✅ Current problems dashboard
✅ WIN11 reachability widget
✅ Linux CPU / memory / disk widgets
✅ Windows CPU / memory / disk widgets
✅ Email media type working
✅ Trigger action working
✅ Problem and recovery notifications configured
```

---

# Next Phases

Recommended next improvements:

```text
Phase 6 — Add service/port monitoring: SSH, RDP, HTTP, Docker, Zabbix ports
Phase 7 — Add SNMP monitoring for router/switch if supported
Phase 8 — Add Docker container monitoring
Phase 9 — Add automation/self-healing actions
Phase 10 — Add HTTP application latency checks using web scenarios
```

