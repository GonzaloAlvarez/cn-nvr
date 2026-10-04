#!/usr/bin/env bash
# cn-nvr — idempotent bring-up on cerberus.lan.
#
# The .env is Kauket-managed (cerberus.cn_nvr_env); this script never
# generates secrets, never mints keys and never touches UFW
# (scripts/host-firewall.sh does that). It:
#   1. checks the host owns CERBERUS_IP (traefik-lan binds it)
#   2. fetches the step-ca root once
#   3. renders traefik-lan/dynamic.yml, promtail/promtail.yml and
#      mosquitto/passwd from .env
#   4. renders config/config.yml from config/config.yml.tmpl when it is
#      missing (or with --render; refuses if un-pulled UI edits would be lost
#      unless --force)
#   5. prepares /srv/frigate (marker + media tree) and brings the stack up
#
#   kauket get cerberus.cn_nvr_env      # installs .env (0600)
#   sudo ./scripts/host-firewall.sh
#   ./setup.sh [--render [--force]]
#   amun docker                         # resiliency units (first time)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

RENDER=0; FORCE=0
while (( $# )); do case "$1" in
  --render) RENDER=1; shift ;;
  --force)  FORCE=1; shift ;;
  -h|--help) sed -n '/^#!/d; /^[^#]/q; s/^# \{0,1\}//p' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac; done

log() { printf '\n\033[1;36m[setup]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
env_get() { grep -E "^${1}=" .env 2>/dev/null | head -1 | cut -d= -f2- || true; }

[[ -f .env ]] || die ".env not found. Run: kauket get cerberus.cn_nvr_env"
for k in CERBERUS_IP HA_IP NVR_LAN_HOST GRAFANA_LAN_HOST INFRA_VPS_TAILNET_IP NVR_AUTHKEY ADMIN_EMAIL \
         FRIGATE_MQTT_PASSWORD HA_MQTT_PASSWORD NVR_PLATE_GONZALO GF_ADMIN_PASSWORD; do
  [[ -n "$(env_get "$k")" ]] || die "$k is empty in .env"
done
CERBERUS_IP="$(env_get CERBERUS_IP)"
ip -4 -o addr show | grep -q " ${CERBERUS_IP}/" \
  || die "this host does not own ${CERBERUS_IP} (pfSense static mapping + lease renewal first)"

# ── step-ca root CA ─────────────────────────────────────────────────────────
mkdir -p certs
PKI="$(env_get PKI_IP)"; PKI="${PKI:-pki.lan}"
if [[ ! -f certs/root_ca.crt ]]; then
  log "fetching step-ca root CA from http://${PKI}/cert/ca.crt"
  curl -sSf "http://${PKI}/cert/ca.crt" -o certs/root_ca.crt || die "could not fetch root CA"
fi

# ── render templates ────────────────────────────────────────────────────────
log "rendering traefik-lan/dynamic.yml and promtail/promtail.yml"
NVR_LAN_HOST="$(env_get NVR_LAN_HOST)" GRAFANA_LAN_HOST="$(env_get GRAFANA_LAN_HOST)" HA_IP="$(env_get HA_IP)" \
  envsubst '${NVR_LAN_HOST} ${GRAFANA_LAN_HOST} ${HA_IP}' < traefik-lan/dynamic.yml.tmpl > traefik-lan/dynamic.yml
INFRA_VPS_TAILNET_IP="$(env_get INFRA_VPS_TAILNET_IP)" \
  envsubst '${INFRA_VPS_TAILNET_IP}' < promtail/promtail.yml.tmpl > promtail/promtail.yml

# Mosquitto password file: plaintext written with umask 077 to a temp file,
# hashed in place by mosquitto_passwd inside the image (no secrets on a
# command line), then installed root:1883 0640 — Mosquitto insists the file
# be root-owned (warns today, refuses in future versions) and reads it as
# the mosquitto user (gid 1883); the host user reads it only via sudo.
log "rendering mosquitto/passwd"
PASSWD_BEFORE="$(sudo sha256sum mosquitto/passwd 2>/dev/null | cut -d' ' -f1 || true)"
tmp_pw="$(mktemp mosquitto/.passwd.XXXXXX)"
( umask 077; printf 'frigate:%s\nhomeassistant:%s\n' "$(env_get FRIGATE_MQTT_PASSWORD)" "$(env_get HA_MQTT_PASSWORD)" > "$tmp_pw" )
docker run --rm -v "$PWD/mosquitto:/work" eclipse-mosquitto:2 mosquitto_passwd -U "/work/$(basename "$tmp_pw")" >/dev/null 2>&1 \
  || { sudo rm -f "$tmp_pw"; die "mosquitto_passwd failed"; }
sudo install -o root -g 1883 -m 0640 "$tmp_pw" mosquitto/passwd
sudo rm -f "$tmp_pw"
PASSWD_AFTER="$(sudo sha256sum mosquitto/passwd | cut -d' ' -f1)"

# ── Frigate config: template -> rendered (plate only) ───────────────────────
render_config() {
  NVR_PLATE_GONZALO="$(env_get NVR_PLATE_GONZALO)" NVR_ADMIN_EMAIL="$(env_get ADMIN_EMAIL)" \
    envsubst '${NVR_PLATE_GONZALO} ${NVR_ADMIN_EMAIL}' < config/config.yml.tmpl
}
mkdir -p config
if [[ ! -f config/config.yml ]]; then
  log "rendering config/config.yml from the template (first run)"
  render_config > config/config.yml
elif (( RENDER )); then
  if ! diff -q <(render_config) config/config.yml >/dev/null && (( ! FORCE )); then
    die "config/config.yml differs from the rendered template (UI edits not pulled?). Run scripts/config-pull.sh first, or --render --force to discard them."
  fi
  log "re-rendering config/config.yml from the template"
  render_config > config/config.yml
else
  if diff -q <(render_config) config/config.yml >/dev/null; then
    log "config/config.yml matches the template"
  else
    log "NOTE: config/config.yml has edits not in the template (UI changes) — run scripts/config-pull.sh to commit them; setup.sh leaves the live file alone"
  fi
fi

# ── storage ─────────────────────────────────────────────────────────────────
mountpoint -q /srv || die "/srv is not a mountpoint (ext-data LVM volume missing)"
log "preparing /srv/frigate (marker + media tree)"
sudo install -d -m 0755 /srv/frigate/media/recordings /srv/frigate/media/clips /srv/frigate/media/exports
sudo touch /srv/frigate/.cn-nvr-volume

# ── bring the stack up ──────────────────────────────────────────────────────
log "docker compose config --quiet"
docker compose config --quiet
log "docker compose up -d --remove-orphans"
docker compose up -d --remove-orphans
if [[ -n "$PASSWD_BEFORE" && "$PASSWD_BEFORE" != "$PASSWD_AFTER" ]]; then
  log "mosquitto passwd changed — recreating mosquitto"
  docker compose up -d --force-recreate --no-deps mosquitto
fi

log "waiting for Frigate (http://127.0.0.1:15000/api/version) and Grafana (http://127.0.0.1:13000/api/health)"
for _ in $(seq 1 36); do
  if curl -sf http://127.0.0.1:15000/api/version >/dev/null 2>&1; then break; fi; sleep 5
done
curl -sf http://127.0.0.1:15000/api/version >/dev/null && echo "  frigate: $(curl -sf http://127.0.0.1:15000/api/version)" || echo "  frigate: not answering yet (docker compose logs frigate)"
curl -sf http://127.0.0.1:13000/api/health >/dev/null && echo "  grafana: ok" || echo "  grafana: not answering yet (docker compose logs grafana)"
sudo ufw status 2>/dev/null | grep -q '443' || echo "  WARNING: UFW has no 443 rule — run: sudo ./scripts/host-firewall.sh"

cat <<SUMMARY

cn-nvr is up.
  LAN:     https://$(env_get NVR_LAN_HOST)   (Authentik: cameras / infra-admins)
           https://$(env_get GRAFANA_LAN_HOST) (Authentik: observability)
  Tailnet: https://nvr.$(env_get LAB_DOMAIN)
  Break-glass (host only): http://127.0.0.1:15000  (Frigate internal API, admin)
Next: amun docker (first time) · draw zones in the UI · scripts/config-pull.sh · HA wiring (README).
SUMMARY
