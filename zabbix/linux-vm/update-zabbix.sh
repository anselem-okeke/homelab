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
