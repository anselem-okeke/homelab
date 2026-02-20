#!/bin/bash

GRAFANA_URL="http://localhost:8000"
GRAFANA_USER="admin"
GRAFANA_PASS="12345"

DASH_UID="k8s-audit-enterprise" 
OUT_DIR="/mnt/data/homelab/grafana/panels"
mkdir -p "$OUT_DIR"
