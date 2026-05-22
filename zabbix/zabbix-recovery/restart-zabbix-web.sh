#!/bin/bash
set -euo pipefail

LOG_FILE="/var/log/zabbix-recovery.log"
CONTAINER_NAME="zabbix-web"

echo "$(date '+%F %T') - Recovery started for ${CONTAINER_NAME}" | sudo tee -a "$LOG_FILE" >/dev/null

if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "$(date '+%F %T') - ${CONTAINER_NAME} is already running. No action needed." | sudo tee -a "$LOG_FILE" >/dev/null
  exit 0
fi

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  docker start "$CONTAINER_NAME"
  echo "$(date '+%F %T') - ${CONTAINER_NAME} started successfully." | sudo tee -a "$LOG_FILE" >/dev/null
  exit 0
fi

echo "$(date '+%F %T') - ERROR: ${CONTAINER_NAME} does not exist." | sudo tee -a "$LOG_FILE" >/dev/null
exit 1
