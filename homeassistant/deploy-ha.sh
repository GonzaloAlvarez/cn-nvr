#!/usr/bin/env bash
# cn-nvr/homeassistant/deploy-ha.sh — install the garage package into Home
# Assistant Supervised on homeiot.lan (run from the operator Mac).
#
#   ./deploy-ha.sh [--notify notify.mobile_app_iphone18gon] [--restart] [--host homeiot.lan]
#
# What it does on the HA host (sudo):
#   * copies packages/cn_nvr_garage.yaml (with __NOTIFY_SERVICE__ substituted)
#     to /usr/share/hassio/homeassistant/packages/
#   * adds `packages: !include_dir_named packages` under `homeassistant:` in
#     configuration.yaml if absent, after a timestamped .bak-cn-nvr-<ts> copy
#     (same precedent as amun-kiosk's edits)
#   * runs `ha core check`; restarts HA only with --restart
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

NOTIFY="notify.mobile_app_iphone18gon"; RESTART=0; HOST="homeiot.lan"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/gonzalo_main_private_key.pem}"
while (( $# )); do case "$1" in
  --notify) NOTIFY="$2"; shift 2 ;;
  --restart) RESTART=1; shift ;;
  --host) HOST="$2"; shift 2 ;;
  -h|--help) sed -n '/^#!/d; /^[^#]/q; s/^# \{0,1\}//p' "$0"; exit 0 ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac; done
[[ "$NOTIFY" == notify.* ]] || { echo "--notify must be a notify.* service" >&2; exit 2; }

ssh_ha() { ssh -o BatchMode=yes -l gonzalo -i "$SSH_KEY" "$HOST" "$@"; }

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
sed "s|__NOTIFY_SERVICE__|${NOTIFY}|g" packages/cn_nvr_garage.yaml > "$tmp"
echo "==> copying package (notify service: $NOTIFY)"
scp -q -o BatchMode=yes -i "$SSH_KEY" "$tmp" "gonzalo@${HOST}:/tmp/cn_nvr_garage.yaml"

echo "==> installing on $HOST"
ssh_ha 'sudo -n bash -s' <<'REMOTE'
set -euo pipefail
HA=/usr/share/hassio/homeassistant
install -d -m 0755 "$HA/packages"
install -m 0644 /tmp/cn_nvr_garage.yaml "$HA/packages/cn_nvr_garage.yaml"
rm -f /tmp/cn_nvr_garage.yaml
if ! grep -qE '^\s*packages:' "$HA/configuration.yaml"; then
  ts=$(date +%Y%m%d%H%M%S)
  cp "$HA/configuration.yaml" "$HA/configuration.yaml.bak-cn-nvr-$ts"
  # insert directly under the `homeassistant:` block header (2-space indent)
  awk 'BEGIN{done=0} {print} /^homeassistant:[[:space:]]*$/ && !done {print "  packages: !include_dir_named packages"; done=1}' \
    "$HA/configuration.yaml.bak-cn-nvr-$ts" > "$HA/configuration.yaml"
  grep -qE '^\s*packages: !include_dir_named packages' "$HA/configuration.yaml" || { echo "failed to insert packages: line" >&2; exit 1; }
  echo "configuration.yaml: packages include added (backup configuration.yaml.bak-cn-nvr-$ts)"
else
  echo "configuration.yaml: packages include already present"
fi
echo "==> ha core check"
ha core check
REMOTE

if (( RESTART )); then
  echo "==> ha core restart"
  ssh_ha 'sudo -n ha core restart'
else
  echo "Package installed and config check passed. Apply with: $0 --restart   (or: ssh $HOST sudo ha core restart)"
fi
