#!/usr/bin/env bash
# cn-nvr/scripts/config-pull.sh — lift Frigate UI edits back into git.
#
# The Frigate UI writes /config/config.yml (the RENDERED, gitignored file).
# This copies it over config/config.yml.tmpl with the known plate re-masked
# as ${NVR_PLATE_GONZALO}, then shows the diff to commit. Guards refuse a
# template that lost the Frigate {FRIGATE_*} placeholders (the UI expanded
# them) or the plate token (plate changed or renamed in the UI: update
# NVR_PLATE_GONZALO in Kauket first, or edit the template by hand).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

[[ -f .env ]] || { echo "no .env (kauket get cerberus.cn_nvr_env)" >&2; exit 1; }
[[ -f config/config.yml ]] || { echo "no config/config.yml to pull" >&2; exit 1; }
PLATE="$(grep -E '^NVR_PLATE_GONZALO=' .env | cut -d= -f2-)"
EMAIL="$(grep -E '^ADMIN_EMAIL=' .env | cut -d= -f2-)"
[[ -n "$PLATE" && -n "$EMAIL" ]] || { echo "NVR_PLATE_GONZALO / ADMIN_EMAIL empty in .env" >&2; exit 1; }

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
# Mask the plate (literal match; plates are letters/digits) and the notification e-mail.
sed -e "s/${PLATE}/\${NVR_PLATE_GONZALO}/g" -e "s/${EMAIL//./\\.}/\${NVR_ADMIN_EMAIL}/g" config/config.yml > "$tmp"

grep -q '{FRIGATE_MQTT_PASSWORD}' "$tmp" \
  || { echo "REFUSING: {FRIGATE_*} placeholders missing from config.yml - the UI expanded credentials; restore from git and edit by hand" >&2; exit 1; }
grep -q '\${NVR_PLATE_GONZALO}' "$tmp" \
  || { echo "REFUSING: plate token not found after masking - plate changed in the UI? update NVR_PLATE_GONZALO in Kauket (.env) first" >&2; exit 1; }
if grep -qiE "password: *[\"']?[^\"'{ ]" "$tmp"; then
  echo "REFUSING: a literal password appears in the pulled config" >&2; exit 1
fi

cp "$tmp" config/config.yml.tmpl
echo "config/config.yml.tmpl updated from the live config (plate masked)."
git --no-pager diff --stat -- config/config.yml.tmpl || true
echo "Review with: git diff config/config.yml.tmpl ; then commit."
