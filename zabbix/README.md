# Zabbix Linux Monitoring Setup

This document explains the full step-by-step setup used to deploy **Zabbix Server with Docker Compose**, fix the Zabbix
Web port issue, configure the default Docker-based Zabbix agent, and finally install **Zabbix Agent 2 directly on the
Linux host** so that the real Linux VM is monitored properly.

The final result is:

```text
Zabbix Web UI
  ↓
Zabbix Server container
  ↓
Zabbix Agent 2 installed directly on Linux host
  ↓
Linux CPU, memory, disk, network, uptime, services, and system metrics
```

---

## 1. Target Architecture

```text
Linux VM / Docker Host
├── Docker Engine
├── Docker Compose
├── zabbix-postgres container
├── zabbix-server container
├── zabbix-web container
├── zabbix-agent2 container
└── native zabbix-agent2 service installed on the Linux host
```

The Docker stack provides:

| Component | Purpose |
|---|---|
| `zabbix-postgres` | PostgreSQL database for Zabbix |
| `zabbix-server` | Zabbix backend/server process |
| `zabbix-web` | Zabbix web frontend |
| `zabbix-agent2` | Agent container for basic container-side checks |
| Native `zabbix-agent2` service | Real monitoring of the Linux VM/host |

---

## 2. Create Project Directory

```bash
mkdir -p /mnt/data/homelab/zabbix/linux-vm
cd /mnt/data/homelab/zabbix/linux-vm
```

---

## 3. Docker Compose File

Create the Compose file:

```bash
nano docker-compose.yml
```

Example Compose file:

```yaml
services:
  postgres:
    image: postgres:16-alpine
    container_name: zabbix-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: zabbix
      POSTGRES_PASSWORD: zabbix_pass
      POSTGRES_DB: zabbix
    volumes:
      - zabbix_pg_data:/var/lib/postgresql/data
    networks:
      - zabbix-net

  zabbix-server:
    image: zabbix/zabbix-server-pgsql:alpine-7.0-latest
    container_name: zabbix-server
    restart: unless-stopped
    depends_on:
      - postgres
    environment:
      DB_SERVER_HOST: postgres
      POSTGRES_USER: zabbix
      POSTGRES_PASSWORD: zabbix_pass
      POSTGRES_DB: zabbix
    ports:
      - "10051:10051"
    networks:
      - zabbix-net

  zabbix-web:
    image: zabbix/zabbix-web-nginx-pgsql:alpine-7.0-latest
    container_name: zabbix-web
    restart: unless-stopped
    depends_on:
      - postgres
      - zabbix-server
    environment:
      ZBX_SERVER_HOST: zabbix-server
      DB_SERVER_HOST: postgres
      POSTGRES_USER: zabbix
      POSTGRES_PASSWORD: zabbix_pass
      POSTGRES_DB: zabbix
      PHP_TZ: Europe/Berlin
    ports:
      - "8081:8080"
    networks:
      - zabbix-net

  zabbix-agent2:
    image: zabbix/zabbix-agent2:alpine-7.0-latest
    container_name: zabbix-agent2
    restart: unless-stopped
    privileged: true
    environment:
      ZBX_HOSTNAME: "Zabbix server"
      ZBX_SERVER_HOST: zabbix-server
    networks:
      - zabbix-net

volumes:
  zabbix_pg_data:

networks:
  zabbix-net:
    driver: bridge
```

> Note: Port `8081:8080` is used because port `8080` was already in use on the Linux host.

---

## 4. Start the Zabbix Stack

```bash
docker compose up -d
```

Check running containers:

```bash
docker ps
```

Expected containers:

```text
zabbix-postgres
zabbix-server
zabbix-web
zabbix-agent2
```

---

## 5. Fix Port 8080 Conflict

During setup, this error occurred:

```text
failed to bind host port 0.0.0.0:8080/tcp: address already in use
```

This means another process/container was already using port `8080`.

Check what is using the port:

```bash
sudo ss -lntp | grep ':8080'
```

or:

```bash
sudo lsof -i :8080
```

The fix was to expose Zabbix Web on host port `8081` instead:

```yaml
ports:
  - "8081:8080"
```

Restart the stack:

```bash
docker compose down
docker compose up -d
```

Then open Zabbix Web:

```text
http://<linux-server-ip>:8081
```

Example:

```text
http://192.168.0.58:8081
```

---

## 6. Zabbix Web Login

Default Zabbix UI credentials:

```text
Username: Admin
Password: zabbix
```

Important:

```text
Admin uses capital A.
```

Database credentials from Docker Compose are different and are only used internally by Zabbix:

| Purpose | Username | Password |
|---|---|---|
| Zabbix Web UI | `Admin` | `zabbix` |
| PostgreSQL database | `zabbix` | `zabbix_pass` |

---

## 7. Fix Default Docker Agent Availability

After login, Zabbix showed:

```text
Zabbix agent is not available
Host: Zabbix server
```

The issue was that the default host interface in Zabbix was set to:

```text
IP address: 127.0.0.1
Connect to: IP
Port: 10050
```

Inside Docker, `127.0.0.1` means the `zabbix-server` container itself, not the `zabbix-agent2` container.

The correct Docker DNS name is:

```text
zabbix-agent2
```

### 7.1 Verify Network Connectivity Between Containers

From the Docker host:

```bash
docker exec -it zabbix-server sh
```

Inside the `zabbix-server` container:

```sh
netstat -lntp | grep 10051
nc -zv zabbix-server 10051
nc -zv zabbix-agent2 10050
exit
```

Expected results:

```text
0.0.0.0:10051 LISTEN
zabbix-server:10051 open
zabbix-agent2:10050 open
```

### 7.2 Fix in Zabbix UI

Go to:

```text
Data collection → Hosts → Zabbix server
```

Edit the Agent interface:

```text
IP address: 127.0.0.1
DNS name: zabbix-agent2
Connect to: DNS
Port: 10050
```

The critical setting is:

```text
Connect to: DNS
DNS name: zabbix-agent2
```

After saving, wait 1–3 minutes. The problem should become **Resolved**, and the `ZBX` availability icon should turn green.

---

## 8. Why the Docker Agent Is Not Enough

The `zabbix-agent2` container can be useful, but it does not fully represent the real Linux host.

For proper Linux VM monitoring, install **Zabbix Agent 2 directly on the Linux host**.

This gives better host-level visibility:

```text
CPU
Memory
Disk
Network interfaces
System uptime
Processes
Services
Host-level metrics
```

---

## 9. Install Zabbix Agent 2 on the Linux Host

The following script was used successfully.

Create the script:

```bash
nano zabbix-agent2.sh
```

Paste:

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

Make it executable:

```bash
chmod +x zabbix-agent2.sh
```

Run it:

```bash
sudo ./zabbix-agent2.sh
```

Verify the service:

```bash
sudo systemctl status zabbix-agent2
```

Expected:

```text
active (running)
```

---

## 10. Configure Native Linux Zabbix Agent 2

The following update script was used successfully.

Create the script:

```bash
nano update-zabbix.sh
```

Paste:

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

Make it executable:

```bash
chmod +x update-zabbix.sh
```

Run it:

```bash
sudo ./update-zabbix.sh
```

Expected output:

```text
Zabbix Agent 2 configuration updated successfully.

Current important config:
Server=127.0.0.1,172.18.0.0/16,192.168.0.58
ServerActive=192.168.0.58
Hostname=linux-vm
```

---

## 11. Important Agent Configuration Explained

The final important settings are:

```ini
Server=127.0.0.1,172.18.0.0/16,192.168.0.58
ServerActive=192.168.0.58
Hostname=linux-vm
```

### `Server`

This controls who is allowed to connect to the agent for passive checks.

```ini
Server=127.0.0.1,172.18.0.0/16,192.168.0.58
```

Meaning:

| Entry | Meaning |
|---|---|
| `127.0.0.1` | Allow local checks from the host itself |
| `172.18.0.0/16` | Allow Zabbix server container traffic from Docker network |
| `192.168.0.58` | Allow the Zabbix server host IP |

### `ServerActive`

```ini
ServerActive=192.168.0.58
```

This tells the agent where to send active checks.

Because the Zabbix server container exposes port `10051` on the Docker host, the Linux host can use:

```text
192.168.0.58:10051
```

### `Hostname`

```ini
Hostname=linux-vm
```

This must match the host name created in the Zabbix UI.

---

## 12. Confirm the Native Agent Is Listening

Run:

```bash
sudo ss -lntp | grep 10050
```

Expected:

```text
LISTEN ... 0.0.0.0:10050
```

Check service status:

```bash
sudo systemctl status zabbix-agent2
```

Check logs if needed:

```bash
sudo journalctl -u zabbix-agent2 -n 100 --no-pager
```

---

## 13. Test from the Zabbix Server Container to the Native Linux Agent

From the Docker host:

```bash
docker exec -it zabbix-server sh
```

Inside the container:

```sh
nc -zv 192.168.0.58 10050
exit
```

Expected:

```text
192.168.0.58:10050 open
```

If this fails, check:

```bash
sudo systemctl status zabbix-agent2
sudo ss -lntp | grep 10050
sudo ufw status
```

If firewall is enabled, allow the port:

```bash
sudo ufw allow 10050/tcp
```

---

## 14. Add the Real Linux Host in Zabbix UI

Go to:

```text
Data collection → Hosts → Create host
```

Use:

```text
Host name: linux-vm
Visible name: Linux VM / Docker Host
Host group: Linux servers
```

### Template

Add template:

```text
Linux by Zabbix agent
```

### Agent Interface

Use:

```text
Type: Agent
IP address: 192.168.0.58
DNS name: empty
Connect to: IP
Port: 10050
```

Click:

```text
Add
```

Wait 1–3 minutes.

Expected:

```text
ZBX availability becomes green
```

---

## 15. View Linux Monitoring Data

Go to:

```text
Monitoring → Latest data
```

Filter:

```text
Host: linux-vm
```

You should see metrics such as:

```text
CPU utilization
Available memory
Disk usage
Filesystem usage
Network traffic
System uptime
Load average
Processes
Zabbix agent availability
```

Check these columns:

```text
Last check
Last value
```

If `Last check` is recent, the host is being monitored correctly.

---

## 16. View Graphs

Go to:

```text
Monitoring → Hosts
```

Find:

```text
linux-vm
```

Click:

```text
Graphs
```

Useful graphs:

```text
CPU utilization
Memory utilization
Disk usage
Network traffic
System load
```

---

## 17. Test Problem Detection

To prove Zabbix can detect an agent failure, temporarily stop the native Linux agent:

```bash
sudo systemctl stop zabbix-agent2
```

Wait a few minutes.

In Zabbix UI:

```text
Monitoring → Problems
```

Expected problem:

```text
Zabbix agent is not available
```

Start the agent again:

```bash
sudo systemctl start zabbix-agent2
```

Wait a few minutes.

Expected result:

```text
Problem becomes Resolved
```

---

## 18. Useful Operational Commands

### Docker Stack

Start:

```bash
docker compose up -d
```

Stop:

```bash
docker compose down
```

Restart:

```bash
docker compose down
docker compose up -d
```

View containers:

```bash
docker ps
```

View logs:

```bash
docker logs zabbix-server --tail=100
docker logs zabbix-web --tail=100
docker logs zabbix-postgres --tail=100
docker logs zabbix-agent2 --tail=100
```

Destroy stack including database volume:

```bash
docker compose down -v
```

> Warning: `docker compose down -v` deletes the PostgreSQL data volume.

### Native Linux Agent

Status:

```bash
sudo systemctl status zabbix-agent2
```

Restart:

```bash
sudo systemctl restart zabbix-agent2
```

Enable at boot:

```bash
sudo systemctl enable zabbix-agent2
```

Logs:

```bash
sudo journalctl -u zabbix-agent2 -f
```

Config:

```bash
sudo nano /etc/zabbix/zabbix_agent2.conf
```

Important config lines:

```bash
grep -E '^(Server|ServerActive|Hostname)=' /etc/zabbix/zabbix_agent2.conf
```

---

## 19. Final Success Checklist

The setup is successful when:

```text
Docker Compose stack is running
Zabbix Web is reachable on port 8081
Login works with Admin / zabbix
Default Docker agent host problem is resolved
Zabbix server can reach zabbix-agent2 container on port 10050
Native Zabbix Agent 2 is installed on Linux host
Native Zabbix Agent 2 service is active
Linux host listens on port 10050
Zabbix server container can reach Linux host on 10050
Host linux-vm exists in Zabbix UI
Template Linux by Zabbix agent is attached
ZBX availability is green
Latest data shows real Linux metrics
Graphs show CPU, memory, disk, and network data
Stopping the agent creates a problem
Starting the agent resolves the problem
```

---

[comment]: <> (## 20. What Comes Next)

[comment]: <> (After this phase, the next logical steps are:)

[comment]: <> (```text)

[comment]: <> (Phase 2: Add Windows VM with Zabbix Agent 2)

[comment]: <> (Phase 3: Add gateway/router with ICMP Ping)

[comment]: <> (Phase 4: Add dashboards for Linux, Windows, and network reachability)

[comment]: <> (Phase 5: Add alerting and notifications)

[comment]: <> (Phase 6: Add SNMP if router/switch supports it)

[comment]: <> (Phase 7: Add automation actions or Ansible-based remediation)

[comment]: <> (```)

