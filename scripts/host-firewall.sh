#!/usr/bin/env bash
# cn-nvr/scripts/host-firewall.sh — UFW rules for cerberus (idempotent, sudo).
#
# Only traefik-lan (network_mode: host) listens on LAN addresses, so UFW is the
# host-level gate; every Docker-published port in this stack is loopback-only.
#   80,443  from the LAN prefixes: Frigate/Grafana LAN ingress + step-ca HTTP-01
#           (pki validates on :80 through pfSense).
#   1883,5000,8554 from HA only: MQTT, Frigate internal API, RTSP restream.
set -euo pipefail
[[ "$(id -u)" -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HA_IP="${HA_IP:-$(grep -E '^HA_IP=' "$HERE/.env" 2>/dev/null | cut -d= -f2- || true)}"
HA_IP="${HA_IP:-10.1.1.134}"

ufw allow proto tcp from 10.0.0.0/8 to any port 80,443 comment 'cn-nvr traefik-lan: LAN ingress + step-ca HTTP-01'
ufw allow proto tcp from "$HA_IP" to any port 1883,5000,8554 comment 'cn-nvr HA-only: mqtt, frigate api, rtsp'
echo
ufw status numbered | grep -E 'cn-nvr' || true
