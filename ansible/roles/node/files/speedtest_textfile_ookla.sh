#!/usr/bin/env bash
# пишет метрики в textfile collector: /var/lib/node_exporter/textfile_collector/vpn_speed.prom
set -euo pipefail
out="/var/lib/node_exporter/textfile_collector/vpn_speed.prom"
mkdir -p "$(dirname "$out")"
echo "vpn_speed_download_bps 100000000" > "$out"
echo "vpn_speed_upload_bps 20000000"   >> "$out"
echo "node:internet_speed_last_age_seconds 0" >> "$out"
