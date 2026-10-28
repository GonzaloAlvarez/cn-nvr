#!/usr/bin/env bash
# cn-nvr/scripts/host-gpu-hang-reboot.sh — install the conditional GPU-hang reboot
# (idempotent, sudo). Copies scripts/gpu-hang-reboot.sh to /usr/local/lib/cn-nvr/,
# the unit + timer from host/ to /etc/systemd/system/, enables the timer and prints
# the current decision (--check never reboots). Re-run after changing any of them.
#   sudo ./scripts/host-gpu-hang-reboot.sh            # install / update
#   sudo ./scripts/host-gpu-hang-reboot.sh --remove   # disable + delete
set -euo pipefail
[[ "$(id -u)" -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT=cn-nvr-gpu-hang-reboot
if [[ "${1:-}" == "--remove" ]]; then
  systemctl disable --now "$UNIT.timer" 2>/dev/null || true
  rm -f "/etc/systemd/system/$UNIT.timer" "/etc/systemd/system/$UNIT.service" /usr/local/lib/cn-nvr/gpu-hang-reboot.sh \
        /var/lib/node_exporter/textfile_collector/cn_nvr_gpu_hang.prom
  systemctl daemon-reload; echo "removed $UNIT"; exit 0
fi
install -d -m 0755 /usr/local/lib/cn-nvr
install -m 0755 "$HERE/scripts/gpu-hang-reboot.sh" /usr/local/lib/cn-nvr/gpu-hang-reboot.sh
install -m 0644 "$HERE/host/$UNIT.service" "$HERE/host/$UNIT.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now "$UNIT.timer" >/dev/null
echo "timer: $(systemctl is-active "$UNIT.timer")"; systemctl list-timers --no-pager "$UNIT.timer" | sed -n 2p
/usr/local/lib/cn-nvr/gpu-hang-reboot.sh --check
