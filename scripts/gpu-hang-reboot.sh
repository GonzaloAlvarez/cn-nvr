#!/usr/bin/env bash
# cn-nvr/scripts/gpu-hang-reboot.sh — reboot cerberus when the iGPU is hung, but
# only inside a nightly window. Installed to /usr/local/lib/cn-nvr/ and run every
# 5 minutes by cn-nvr-gpu-hang-reboot.timer (scripts/host-gpu-hang-reboot.sh).
#
# Why: the HD 530 (Skylake) hangs under OpenVINO every few days — the kernel logs
# `i915 … GPU HANG: ecode 9:0:00000000` + `Resetting rcs0 for stopped heartbeat`
# every 3 s, Frigate's detector sits in i915_request_wait_timeout forever (no
# detection, no plate reads, recordings discarded) while its API stays "healthy".
# Neither Frigate's watchdog nor a container recreate recovers it; a host reboot does.
#
# Every run publishes the state for Prometheus (node-exporter textfile collector).
# A reboot happens only when ALL hold:
#   * a GPU HANG was logged in the last RECENT_MIN minutes of this boot (hung NOW,
#     not a blip that cleared)
#   * the local hour is in [WINDOW_START, WINDOW_END) in TZ_NAME (default 04–06 ET)
#   * uptime ≥ MIN_UPTIME_MIN (a hang right after boot never loops the host)
#   * this script has not rebooted the host yet today (TZ_NAME date) — one shot
# Usage: gpu-hang-reboot.sh [--check]   (--check prints the decision, never reboots)
set -euo pipefail

TZ_NAME="${TZ_NAME:-America/New_York}"
WINDOW_START="${WINDOW_START:-4}"        # inclusive hour
WINDOW_END="${WINDOW_END:-6}"            # exclusive hour
RECENT_MIN="${RECENT_MIN:-15}"
MIN_UPTIME_MIN="${MIN_UPTIME_MIN:-30}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
STATE_DIR="${STATE_DIR:-/var/lib/cn-nvr}"
STATE_FILE="$STATE_DIR/gpu-hang-last-reboot"
PATTERN="GPU HANG"
CHECK=0; [[ "${1:-}" == "--check" ]] && CHECK=1

log() { logger -t cn-nvr-gpu-hang-reboot -- "$*"; echo "[gpu-hang-reboot] $*"; }

hangs_total="$(journalctl -k -b -q 2>/dev/null | grep -c -F "$PATTERN" || true)"
hangs_recent="$(journalctl -k -b -q --since "-${RECENT_MIN}min" 2>/dev/null | grep -c -F "$PATTERN" || true)"
uptime_min="$(awk '{print int($1/60)}' /proc/uptime)"
hour="$(TZ="$TZ_NAME" date +%-H)"
today="$(TZ="$TZ_NAME" date +%F)"
now_epoch="$(date +%s)"
last_date=""; last_epoch=0
if [[ -r "$STATE_FILE" ]]; then read -r last_date last_epoch < "$STATE_FILE" || true; fi

in_window=0; (( hour >= WINDOW_START && hour < WINDOW_END )) && in_window=1
hung_now=0; (( hangs_recent > 0 )) && hung_now=1
reason=""
if (( hung_now )); then
  if   (( ! in_window ));                     then reason="outside ${WINDOW_START}:00-${WINDOW_END}:00 ${TZ_NAME}"
  elif (( uptime_min < MIN_UPTIME_MIN ));     then reason="uptime ${uptime_min} min < ${MIN_UPTIME_MIN}"
  elif [[ "$last_date" == "$today" ]];        then reason="already rebooted today (${last_date})"
  fi
fi
will_reboot=0; (( hung_now )) && [[ -z "$reason" ]] && will_reboot=1
pending=0; (( hung_now && ! will_reboot )) && pending=1

# ── metrics (atomic write) ─────────────────────────────────────────────────
if [[ -d "$TEXTFILE_DIR" ]]; then
  tmp="$(mktemp "$TEXTFILE_DIR/.cn_nvr_gpu_hang.XXXXXX")"
  cat > "$tmp" <<METRICS
# HELP cn_nvr_i915_gpu_hang_boot_total Kernel "GPU HANG" lines since boot (resets on reboot).
# TYPE cn_nvr_i915_gpu_hang_boot_total gauge
cn_nvr_i915_gpu_hang_boot_total{device="0000:00:02.0"} ${hangs_total}
# HELP cn_nvr_i915_gpu_hang_recent Kernel "GPU HANG" lines in the last ${RECENT_MIN} minutes (>0 = hung now).
# TYPE cn_nvr_i915_gpu_hang_recent gauge
cn_nvr_i915_gpu_hang_recent{device="0000:00:02.0"} ${hangs_recent}
# HELP cn_nvr_gpu_hang_reboot_pending 1 when the GPU is hung but the conditional reboot is held back (window/guards).
# TYPE cn_nvr_gpu_hang_reboot_pending gauge
cn_nvr_gpu_hang_reboot_pending ${pending}
# HELP cn_nvr_gpu_hang_reboot_last_timestamp_seconds Epoch of the last reboot issued by this script (0 = never).
# TYPE cn_nvr_gpu_hang_reboot_last_timestamp_seconds gauge
cn_nvr_gpu_hang_reboot_last_timestamp_seconds ${last_epoch}
# HELP cn_nvr_gpu_hang_check_timestamp_seconds Epoch of the last check run.
# TYPE cn_nvr_gpu_hang_check_timestamp_seconds gauge
cn_nvr_gpu_hang_check_timestamp_seconds ${now_epoch}
METRICS
  chmod 0644 "$tmp"; mv -f "$tmp" "$TEXTFILE_DIR/cn_nvr_gpu_hang.prom"
fi

summary="hangs_total=${hangs_total} hangs_recent=${hangs_recent} hour_local=${hour} window=${WINDOW_START}-${WINDOW_END} uptime_min=${uptime_min} last_reboot=${last_date:-never}"
if (( will_reboot )); then
  if (( CHECK )); then echo "[gpu-hang-reboot] --check: WOULD REBOOT now (${summary})"; exit 0; fi
  log "GPU hung (${summary}) — rebooting"
  install -d -m 0755 "$STATE_DIR"
  printf '%s %s\n' "$today" "$now_epoch" > "$STATE_FILE"
  sync
  exec systemctl reboot
elif (( pending )); then
  echo "[gpu-hang-reboot] hung, holding: ${reason} (${summary})"
  (( CHECK )) || log "GPU hung, reboot held: ${reason} (${summary})"
else
  echo "[gpu-hang-reboot] ok: no recent GPU hang (${summary})"
fi
