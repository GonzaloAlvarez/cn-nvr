# cn-nvr — Frigate NVR on cerberus.lan

Frigate 0.18 (recording, live view, object detection, license-plate recognition) with Mosquitto, a host-local Prometheus/Grafana, the host's Traefik and Watchtower, and the Home Assistant contract that lets a recognised plate open the garage. Dedicated-host stack in the homelab model (see `homelab/architecture.md`: "Dedicated hosts").

| Surface | URL | Who |
|---|---|---|
| Frigate, LAN | `https://nvr.cerberus.lan` (step-ca) | Authentik forward-auth: `cameras` → viewer, `infra-admins` → admin |
| Frigate, tailnet | `https://nvr.lab.gn.al` (LE) | same groups via `outpost-lab`; this is the name to install the PWA from on phones |
| Grafana (host-local) | `https://grafana.cerberus.lan` (step-ca) | Authentik OIDC, `observability` group (shared `grafana` provider) |
| HA contract (homeiot only) | `10.0.0.230:5000` Frigate API · `:1883` MQTT · `:8554` RTSP restream | Traefik `ClientIP`/`ipAllowList` + UFW, source `10.1.1.134` |
| Break-glass | `http://127.0.0.1:15000` on the host (Frigate internal API, admin, no auth) · Grafana local admin (`GF_ADMIN_PASSWORD`) | operator on the host |

## Health checks

```sh
docker compose -p cn-nvr ps                              # everything Up/healthy, mount-precheck Exited (0)
curl -sf http://127.0.0.1:15000/api/version              # Frigate answers
curl -s  http://127.0.0.1:15000/api/stats | jq '.detectors, .cameras | keys'
docker exec cn-nvr-ts-nvr-1 tailscale status | head -3   # node `nvr` online
docker compose -p cn-nvr logs --tail=50 frigate | grep -iE "openvino|vaapi|error" # detector on GPU, no decode errors
curl -skI https://nvr.cerberus.lan/api/version | head -1 # 200 through traefik-lan (ungated probe)
curl -skI https://nvr.cerberus.lan/ | grep -i location   # 302 to auth.neptune.lan (gate works)
curl -sf http://127.0.0.1:13000/api/health               # Grafana
```

Dashboards: `grafana.cerberus.lan` → *cerberus.lan overview*, *Frigate NVR*; the VPS Grafana (`grafana.lab.gn.al`) has the same *Frigate NVR* dashboard plus logs, and owns the alerts (`FrigateDown`, `FrigateCameraStalled`, `FrigateDetectorSlow`, `FrigateStorageLow`, `NvrNodeDown`).

## Layout

```
ts-nvr (tag:svc, node nvr, bridge 172.30.5.10)   netns shared by: frigate, mosquitto, node-exporter, promtail, consul-register
  publishes 127.0.0.1 only: 18971→8971 (UI/API), 15000→5000 (internal API), 11883→1883 (MQTT), 18554→8554 (RTSP)
traefik-lan (host network, step-ca)              nvr.cerberus.lan (+authentik-lan), /api/version ungated, grafana.cerberus.lan,
                                                 10.0.0.230:5000/1883/8554 for Home Assistant only
bridge                                            prometheus (scrapes 172.30.5.10:5000 /api/metrics and :9100), grafana, backup (offen), watchdog, mount-precheck
host                                              /srv/frigate/media (1.8 TB LVM) = recordings/clips/exports; ./config = config.yml + frigate.db + model_cache (SSD)
```

Trust model: ports 8971/5000/1883/8554/9100 are open on the sidecar's tailnet interface to `tag:infra` (traefik-lab, Prometheus) and the operator identity only; the Headscale ACL already confines `tag:svc:*` that way, and family/untagged users never reach them. On the LAN the only listeners are Traefik's. Frigate trusts the `X-authentik-*` headers from Traefik (no `proxy.auth_secret`); Traefik strips and re-sets those headers on every request. Phase-2 hardening, if ever wanted: an iptables rule in the `ts-nvr` entrypoint restricting `tailscale0` ingress to `100.64.0.1` (cn-bittorrent kill-switch precedent).

## First install

Prerequisites done elsewhere: pfSense static mapping `10.0.0.230` + Host Overrides (`cn-home` `LAN_HOSTS`/`LAN_STATIC_MAPPINGS`), Technitium records (`cn-dnsdhcpd/dns/records.tsv`), Authentik providers (`cn-authentik/setup-nvr-proxy-sso.sh`, `setup-grafana-oidc.sh`), neptune's Traefik trusting `10.0.0.0/24`, Headscale `tag:svc` key, Kauket secret `cerberus.cn_nvr_env`.

```sh
# on cerberus
git clone https://github.com/GonzaloAlvarez/cn-nvr.git ~/cn-nvr && cd ~/cn-nvr
git config user.name "Gonzalo Alvarez" && git config user.email gonzaloab@gmail.com
kauket request cerberus        # first time only (device flow); then `kauket approve` on the Mac
kauket get cerberus.cn_nvr_env # installs .env (0600)
sudo ./scripts/host-firewall.sh
./setup.sh
amun docker                    # installs docker-compose@cn-nvr boot unit + reconcile cron
```

`setup.sh` fetches the step-ca root, renders `traefik-lan/dynamic.yml`, `promtail/promtail.yml`, `mosquitto/passwd` and (first run only) `config/config.yml`, prepares `/srv/frigate`, and brings the stack up. It never generates secrets or touches UFW.

## Deploy a change

```sh
cd ~/cn-nvr && git pull && docker compose up -d --force-recreate --no-deps <service>
```
Single-file binds (`traefik-lan/dynamic.yml`, `promtail/promtail.yml`, `mosquitto/*`, `prometheus/prometheus.yml`) keep the old inode after a pull — recreate, never reload. Re-run `./setup.sh` when a template changed. Whole stack: `sudo systemctl restart docker-compose@cn-nvr`.

## Frigate configuration: template → rendered → pull back

The public repo tracks `config/config.yml.tmpl`; the live `/config/config.yml` is rendered by `setup.sh` (only `${NVR_PLATE_GONZALO}` and `${NVR_ADMIN_EMAIL}` are substituted; Frigate itself substitutes `{FRIGATE_*}` credentials from the container environment) and is gitignored. The Frigate UI (zones, masks, cameras, known plates) writes the live file.

1. Edit in the UI → *Save*.
2. `scripts/config-pull.sh` → copies the live file over the template with the plate and e-mail re-masked, refuses if credentials were expanded or the plate token vanished (plate changed? update `NVR_PLATE_GONZALO` in Kauket first).
3. `git diff config/config.yml.tmpl`, commit, push (from the Mac after `scp`/`git pull`, or from the host with push rights).

`./setup.sh --render` re-renders from the template and refuses if the live file changed since the last render (`--force` discards those changes). Note that Frigate itself writes to `config.yml` at runtime (detect/record toggles flipped from the UI or MQTT, `camera_groups`), so after any such change run `scripts/config-pull.sh` before a render. After the first UI save, confirm `grep -c '{FRIGATE_' config/config.yml` is unchanged.

Cameras: `driveway` = AXIS P1465-LE-3 (10.1.1.123), `ptz` = AXIS P5655-E (10.1.1.151, ONVIF :80), `doorbell` = UniFi Protect doorbell (`rtspx://10.1.1.90:7441/<token>` from `FRIGATE_DOORBELL_STREAM`; Protect's RTSPS without SRTP, single stream for record + detect). Streams are pulled once by go2rtc (1080p15 record, 720p5 detect) and restreamed on `rtsp://127.0.0.1:8554/<name>`. Camera credentials are `.env` → `{FRIGATE_AXIS_*}` / `{FRIGATE_AXISPTZ_*}` (RTSP) and `{FRIGATE_AXISPTZ_ONVIF_*}` (PTZ); passwords are embedded in RTSP URLs, so keep them URL-safe. Axis keeps ONVIF accounts separate from device accounts (System → ONVIF → Accounts); a missing ONVIF account **or a camera clock that is off** (the P5655-E was ~7 h ahead) shows up as `Onvif connection failed … Sender not authorized` and no PTZ controls in the UI; `onvif.ignore_time_mismatch: true` lets Frigate compensate for the clock offset, but fix the camera's NTP too (System → Date and time). Check with `curl -s http://127.0.0.1:15000/api/ptz/ptz/info` (features list) and the unauthenticated ONVIF `GetSystemDateAndTime` against `date -u`.

## Home Assistant

HA talks to Frigate over the LAN, never through the browser gate (forward-auth is browser-only):

| What | Value |
|---|---|
| MQTT integration | broker `10.0.0.230`, port 1883, user `homeassistant`, password `HA_MQTT_PASSWORD` (Kauket `cerberus.cn_nvr_env`) |
| Frigate integration (HACS, `blakeblackshear/frigate-hass-integration`) | URL `http://10.0.0.230:5000`, no username/password; camera entities stream `rtsp://10.0.0.230:8554/<camera>` |
| Package | `homeassistant/packages/cn_nvr_garage.yaml` via `homeassistant/deploy-ha.sh [--notify notify.<device>] [--restart]` |

The package is **armed** since 2026-10-04 (one real shadow-mode arrival verified the trigger path first); `input_boolean.nvr_garage_auto_open_armed` is the kill switch and survives restarts — off means shadow mode (notifications only). `automation.nvr_known_plate_arrival` fires on `frigate/tracked_object_update` (`type: lpr`, `name: gonzalo_car`, score ≥ `input_number.nvr_lpr_min_score`, camera in `driveway`/`ptz`), records `input_text.nvr_last_plate_event`, pushes a notification that says *opening the garage* or *not opening: <reason>*, and calls `script.nvr_garage_safe_open` only when every guard passes:

| Guard | Why |
|---|---|
| armed switch on | kill switch / shadow mode |
| `input_boolean.nvr_garage_opened_by_ha` off | HA already opened the door and it has not closed since |
| door `closed` for ≥ 180 s | departure guard: a late read of your own plate as you drive away must not reopen the house |
| Frigate object `id` ≠ `input_text.nvr_last_plate_object_id` | the same sighting never opens the door twice |
| opener not running, not run in the last 2 min | cooldown |

The opener **blocks the controller for the whole HA-driven open**: it latches `nvr_garage_opened_by_ha`, engages the ratgdo *Lock remotes* and waits for the opener to confirm (~0.2 s measured on the real device; aborts with a persistent notification after 5 s and never moves the door), sends `cover.open_cover`, keeps the remotes locked until the door reports `open` (≤ 30 s, so a visor-remote press cannot stop or reverse it mid-travel), then releases them. The latch clears when the door reports `closed` (`automation.nvr_garage_opened_by_ha_clear`); `automation.nvr_remote_lock_safety_reset` releases the remotes if anything leaves them locked for a minute. The pre-existing 23:00 "Close Garage Door" automation is untouched; the ratgdo wall button is outside the lock's reach by design. Known limitation until a second factor exists: any *new* Frigate tracked object carrying the plate opens the door, including a parked car the tracker re-acquires in view of the driveway cameras.

Tests that do not move the door — publish a synthetic event through HA itself (REST `POST /api/services/mqtt/publish`, token `homeiot.ha_api_token`) while a guard is known to block, e.g. with `input_boolean.nvr_garage_opened_by_ha` switched on by hand:

```json
{"topic": "frigate/tracked_object_update",
 "payload": "{\"type\":\"lpr\",\"name\":\"gonzalo_car\",\"plate\":\"SYNTHETIC\",\"score\":0.99,\"id\":\"synthetic-1\",\"camera\":\"driveway\",\"timestamp\":0}"}
```

The push and `input_text.nvr_last_plate_event` must read `not opening: HA already opened the door` and `script.nvr_garage_safe_open` must not have run; switch the latch off afterwards. To exercise the opener itself, run the script from Developer tools with the door closed and watch `lock.ratgdo32_9a2c58_lock_remotes` go `locked` → door `open` → `unlocked`. Later second factors: a zone-occupancy condition (`binary_sensor.<camera>_<zone>_car_occupancy`, once the `driveway_approach` zone exists) and a Frigate custom vehicle-identity classifier (train on the car, not the plate).

## State, backup, restore

| State | Where | Backup |
|---|---|---|
| `config/config.yml`, `frigate.db` (events, review items, plates), `model_cache` | `./config` (SSD) | weekly offen → S3 `cloudnet-lab-storage/nvr/` + raidnas WebDAV `/nvr/`; `frigate` runs an `archive-pre` SQLite online-backup to `frigate.db.snapshot`, the live WAL db and `model_cache` are excluded |
| recordings, clips, exports | `/srv/frigate/media` (1.8 TB LVM, retention-bound: continuous 7 d, motion 14 d, alerts 30 d, detections 14 d) | **none, deliberately** |
| Mosquitto persistence, Traefik ACME, Prometheus TSDB, Grafana | named volumes | none — rebuilt from provisioning / re-issued |

Manual run: `docker exec cn-nvr-backup-1 /usr/bin/backup`; check the object in S3 and `http://raidnas.lan:5005/cloudlabbackup/nvr/`. Restore: `kauket get cerberus.cn_nvr_env`, clone, unpack the archive's `config/` into `./config` (rename `frigate.db.snapshot` → `frigate.db`), `./setup.sh`.

## Pins

| Image | Pin | Why / unpin condition |
|---|---|---|
| `ghcr.io/blakeblackshear/frigate:0.18.0` | explicit, Watchtower-excluded | Frigate migrates its DB on boot and 0.x minors rename config keys. Upgrade by hand: release notes → back up `./config` → bump → `up -d frigate` → re-check `config.yml.tmpl`. Never auto-updated by design. |
| `grafana/grafana:11.2.0`, `prom/prometheus:v2.55.0` | same as kaiser's cn-observability, Watchtower-excluded | dashboard JSON is schemaVersion 39; bump together with cn-observability |
| `traefik:v3.6.9`, `eclipse-mosquitto:2`, `tailscale/tailscale:latest`, exporters | Watchtower (host-wide, 04:00) | — |

## Resiliency

`resiliency.yml` → `docker-compose@cn-nvr` boot unit + 5-minute reconcile (`amun docker`). `/srv` is a local LVM volume, which amun-docker cannot gate, so `mount-precheck` asserts the volume size and the `/srv/frigate/.cn-nvr-volume` marker before `ts-nvr`/`frigate` start. `ts-nvr-watchdog` recreates netns dependents after ~30 s of drift when the sidecar container is **recreated** (new container id). A plain `docker restart cn-nvr-ts-nvr-1` keeps the id, so the watchdog sees no drift while the dependents sit in the dead namespace (Frigate unreachable, Consul deregisters after 2 min); the 5-minute amun-docker reconcile detects that case by namespace and force-recreates them — verified 2026-10-03. To restart the sidecar deliberately, recreate it instead: `docker compose up -d --force-recreate ts-nvr`. Verify: `~/dev/amun-docker/verify --host cerberus.lan`; `sudo systemctl restart docker-compose@cn-nvr`; `docker restart cn-nvr-ts-nvr-1` → dependents recreated.

## Troubleshooting

- **Detector crash-loop / Frigate restarting / HA shows 500-502 from :5000** — `docker logs cn-nvr-frigate-1 | grep -A3 'Process frigate.detector'`; a `could not broadcast input array` ValueError means the `model.input_tensor` layout is wrong for the model (the bundled OpenVINO SSDLite is `nhwc`). Frigate's watchdog restarts the detector forever and the API flaps.
- **Detector slow / CPU pegged** — `docker compose logs frigate | grep -i openvino`; if the GPU plugin failed, set `detectors.ov.device: CPU` in the template, `./setup.sh --render`, recreate frigate. `FrigateDetectorSlow` (>100 ms) is the alert.
- **Camera 0 fps** — RTSP/credentials: `docker exec cn-nvr-frigate-1 ffprobe rtsp://127.0.0.1:8554/driveway`; the go2rtc page is `http://127.0.0.1:15000` → *System* → go2rtc.
- **`TRAEFIK DEFAULT CERT`** — HTTP-01 failed: the name must exist in Technitium and as a pfSense Host Override, UFW must allow 80 from pki, `pki.lan` is pinned in `extra_hosts`.
- **LAN login loops / 404 from Authentik** — neptune's Traefik must trust forwarded headers from `10.0.0.0/24` (cn-authentik `forwardedHeaders.trustedIPs`).
- **Grafana "Client ID Error"** — `AUTHENTIK_GRAFANA_CLIENT_*` drifted from the provider record on neptune; compare against the record, not another host's `.env`.
- **HA integration cannot connect** — from homeiot `nc -vz 10.0.0.230 5000 1883 8554`; UFW rule present (`scripts/host-firewall.sh`), traefik-lan running, HA's IP still `10.1.1.134`.
- **Recordings volume filling** — `frigate_storage_*` in Grafana; lower `record.continuous.days` or the Axis bitrate; Frigate deletes the oldest segments itself when space runs out.
- **shm** — three or more cameras, or detect above 720p: recompute `shm_size` ((w×h×1.5×20+270480)/1048576 MB per camera + 40).
