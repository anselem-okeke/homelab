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

