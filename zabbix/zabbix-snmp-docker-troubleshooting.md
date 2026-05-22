# Zabbix SNMP Troubleshooting — Linux Host + Docker-Based Zabbix

## Purpose

This note documents the exact troubleshooting path used to add a Linux VM as an SNMP-monitored host in Zabbix when Zabbix itself is running in Docker.

The key lesson:

> SNMP working locally on the Linux host does not automatically mean Zabbix can poll it, especially when Zabbix runs inside a Docker network.

---

## Architecture Context

```text
Zabbix Server Container
        |
        | Docker bridge network
        | Source IP: 172.18.0.5
        |
Docker Host / Linux VM
        |
        | SNMP UDP/161
        |
Linux SNMP Target
IP: 192.168.0.58
```

In this setup, the monitored Linux host is also reachable on the LAN as:

```text
192.168.0.58
```

Zabbix is running inside Docker and sends SNMP requests from a Docker bridge subnet such as:

```text
172.18.0.0/16
```

---

## Mental Model

When Zabbix polls a Linux host using SNMP, this is the flow:

```text
Zabbix item/template
      ↓
Zabbix SNMP poller
      ↓
SNMP request from Docker container
      ↓
Linux host UDP/161
      ↓
snmpd checks community + source IP
      ↓
snmpd replies or silently drops/ignores
```

SNMP v2c authentication is very simple:

```text
community string + allowed source network
```

For example:

```conf
rocommunity public 192.168.0.0/24
```

This means:

```text
Allow read-only SNMP access using community "public"
only from clients in 192.168.0.0/24
```

If Zabbix sends traffic from `172.18.0.5`, then this rule does **not** match:

```conf
rocommunity public 192.168.0.0/24
```

So Zabbix may time out even though SNMP works locally.

---

## Final Working SNMP Configuration

File:

```bash
/etc/snmp/snmpd.conf
```

Recommended lab configuration:

```conf
###########################################################################
# System Information
###########################################################################

sysLocation Homelab
sysContact Anselem
sysServices 72

###########################################################################
# Agent Listening Address
###########################################################################

agentAddress udp:161,udp6:[::1]:161

###########################################################################
# Access Control
###########################################################################

rocommunity public 127.0.0.1
rocommunity public 192.168.0.0/24
rocommunity public 172.18.0.0/16
rocommunity public 10.0.0.0/8

###########################################################################
# AgentX
###########################################################################

master agentx

###########################################################################
# Include extra config files
###########################################################################

includeDir /etc/snmp/snmpd.conf.d
```

### Important Notes

This line allows normal LAN clients:

```conf
rocommunity public 192.168.0.0/24
```

This line allows the Docker-based Zabbix server:

```conf
rocommunity public 172.18.0.0/16
```

This line is useful for lab environments where Docker or internal bridge networks may use private ranges:

```conf
rocommunity public 10.0.0.0/8
```

For a production environment, restrict access to the exact Zabbix server/container subnet or IP.

---

## Restart SNMP

After editing the config:

```bash
sudo systemctl restart snmpd
sudo systemctl enable snmpd
sudo systemctl status snmpd --no-pager
```

Expected:

```text
Active: active (running)
```

---

## Confirm SNMP Is Listening

Run:

```bash
sudo ss -ulnp | grep 161
```

Expected:

```text
0.0.0.0:161
[::1]:161
```

Important:

```text
0.0.0.0:161
```

means SNMP is listening on all IPv4 interfaces.

---

## Local SNMP Test

Run from the Linux host itself:

```bash
snmpwalk -v2c -c public 127.0.0.1 .1.3.6.1.2.1.1
```

Or using the LAN IP:

```bash
snmpwalk -v2c -c public 192.168.0.58 .1.3.6.1.2.1.1
```

Expected output includes:

```text
iso.3.6.1.2.1.1.1.0 = STRING: "Linux server ..."
iso.3.6.1.2.1.1.4.0 = STRING: "Anselem"
iso.3.6.1.2.1.1.5.0 = STRING: "server"
iso.3.6.1.2.1.1.6.0 = STRING: "Homelab"
```

---

## Why Numeric OIDs Were Used

This command may fail:

```bash
snmpwalk -v2c -c public 127.0.0.1 system
```

Possible error:

```text
system: Unknown Object Identifier
```

That does not mean SNMP is broken.

It usually means the local SNMP client cannot resolve human-readable MIB names.

Use the numeric OID instead:

```bash
snmpwalk -v2c -c public 127.0.0.1 .1.3.6.1.2.1.1
```

Equivalent meaning:

```text
.1.3.6.1.2.1.1 = system
```

---

## Test the OID Zabbix Was Failing On

Zabbix showed timeout on:

```text
.1.3.6.1.2.1.25.3.3.1.1
```

Test it manually:

```bash
snmpwalk -v2c -c public 192.168.0.58 .1.3.6.1.2.1.25.3.3.1.1
```

If this works locally, then the SNMP daemon and OID access are fine.

If Zabbix still times out, the problem is network/source-IP related.

---

## Zabbix Host Configuration

In Zabbix:

```text
Data collection → Hosts → Create host
```

Recommended values:

| Field | Value |
|---|---|
| Host name | `Linux VM - SNMP` |
| Interface type | `SNMP` |
| IP address | `192.168.0.58` |
| Port | `161` |
| SNMP version | `SNMPv2` |
| SNMP community | `{$SNMP_COMMUNITY}` |
| Template | `Linux by SNMP` |

---

## Zabbix Macro Configuration

In the host **Macros** tab:

| Macro | Value |
|---|---|
| `{$SNMP_COMMUNITY}` | `public` |

Keep the interface community field as:

```text
{$SNMP_COMMUNITY}
```

Do not replace it directly with `public` unless you intentionally do not want to use macros.

The macro approach is cleaner because many templates expect:

```text
{$SNMP_COMMUNITY}
```

---

## Main Problem Observed

Zabbix showed:

```text
Not available
cannot retrieve OID '.1.3.6.1.2.1.25.3.3.1.1' from [[192.168.0.58]:161]: timed out
```

But local SNMP tests from the Linux host worked.

This means:

```text
SNMP daemon works
OID works
Zabbix host config is probably close
Network/source access must be checked
```

---

## tcpdump Verification

Run this on the Linux SNMP host:

```bash
sudo tcpdump -ni any udp port 161
```

Observed traffic:

```text
IP 172.18.0.5.xxxxx > 192.168.0.58.161: GetBulk ...
```

This proves:

```text
Zabbix traffic reaches the Linux host
Zabbix source IP is 172.18.0.5
```

That source IP is from the Docker bridge network, not from the normal LAN subnet.

---

## Key Finding

The Linux SNMP host originally allowed:

```conf
rocommunity public 192.168.0.0/24
```

But Zabbix was coming from:

```text
172.18.0.5
```

Therefore, SNMP access control did not match the Zabbix source IP.

The fix is to allow the Docker subnet:

```conf
rocommunity public 172.18.0.0/16
```

Then restart SNMP:

```bash
sudo systemctl restart snmpd
```

---

## Test from the Same Docker Network as Zabbix

Start a temporary Alpine container on the Zabbix Docker network:

```bash
docker run --rm -it --network linux-vm_zabbix-net alpine sh
```

Inside the container:

```sh
apk add --no-cache net-snmp-tools
snmpwalk -v2c -c public 192.168.0.58 .1.3.6.1.2.1.1
```

Then test the Zabbix failing OID:

```sh
snmpwalk -v2c -c public 192.168.0.58 .1.3.6.1.2.1.25.3.3.1.1
```

If this works from the temporary Docker container, Zabbix should also work.

---

## Docker Networking Concept

Docker Compose creates bridge networks.

Containers on that network usually get private IP addresses like:

```text
172.18.0.x
```

Even if the Linux host itself is:

```text
192.168.0.58
```

The packet source seen by `snmpd` may be the Docker container IP, for example:

```text
172.18.0.5
```

So SNMP access rules must allow that source.

---

## SNMP Timeout Meaning

With SNMP, a timeout usually means:

```text
No response came back
```

Common reasons:

1. SNMP daemon is not running
2. SNMP is not listening on UDP/161
3. Firewall blocks UDP/161
4. Wrong community string
5. Source IP is not allowed by `snmpd.conf`
6. Docker network source IP is different from what you expected
7. Wrong SNMP version
8. Zabbix SNMP pollers are not running

In this case, the root cause was:

```text
Docker/Zabbix source IP was not allowed by SNMP access rules
```

---

## Troubleshooting Flow Used

### 1. Confirm service state

```bash
sudo systemctl status snmpd --no-pager
```

Goal:

```text
SNMP daemon must be active/running
```

### 2. Confirm listener

```bash
sudo ss -ulnp | grep 161
```

Goal:

```text
snmpd must listen on 0.0.0.0:161
```

### 3. Test locally

```bash
snmpwalk -v2c -c public 127.0.0.1 .1.3.6.1.2.1.1
```

Goal:

```text
Prove SNMP works locally
```

### 4. Test by LAN IP

```bash
snmpwalk -v2c -c public 192.168.0.58 .1.3.6.1.2.1.1
```

Goal:

```text
Prove SNMP works on the network interface
```

### 5. Test deeper OID

```bash
snmpwalk -v2c -c public 192.168.0.58 .1.3.6.1.2.1.25.3.3.1.1
```

Goal:

```text
Prove Zabbix template OIDs are allowed
```

### 6. Observe real packets

```bash
sudo tcpdump -ni any udp port 161
```

Goal:

```text
Find the real source IP of Zabbix SNMP traffic
```

### 7. Allow Docker source subnet

```conf
rocommunity public 172.18.0.0/16
```

Goal:

```text
Allow Zabbix container to query SNMP
```

### 8. Test from Docker network

```bash
docker run --rm -it --network linux-vm_zabbix-net alpine sh
```

Inside:

```sh
apk add --no-cache net-snmp-tools
snmpwalk -v2c -c public 192.168.0.58 .1.3.6.1.2.1.1
```

Goal:

```text
Prove that a container on the same network as Zabbix can poll SNMP
```

---

## Quick Checklist

| Check | Command | Expected |
|---|---|---|
| SNMP service | `systemctl status snmpd` | active/running |
| UDP listener | `ss -ulnp | grep 161` | `0.0.0.0:161` |
| Local SNMP | `snmpwalk -v2c -c public 127.0.0.1 .1.3.6.1.2.1.1` | system info |
| LAN SNMP | `snmpwalk -v2c -c public 192.168.0.58 .1.3.6.1.2.1.1` | system info |
| Zabbix OID | `snmpwalk -v2c -c public 192.168.0.58 .1.3.6.1.2.1.25.3.3.1.1` | data returned |
| Traffic source | `tcpdump -ni any udp port 161` | see Zabbix source IP |
| Docker test | temporary Alpine container | SNMP succeeds |
| Zabbix UI | Monitoring → Hosts | SNMP icon green |

---

## Final Lesson

When Zabbix runs in Docker, always troubleshoot SNMP from three perspectives:

```text
1. From the monitored host itself
2. From the Docker host
3. From inside the Docker network/container path
```

The most important command in this case was:

```bash
sudo tcpdump -ni any udp port 161
```

because it revealed the real source IP:

```text
172.18.0.5
```

Once that source network was allowed in `snmpd.conf`, the Zabbix SNMP timeout could be resolved.
