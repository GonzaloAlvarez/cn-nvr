#!/usr/bin/env python3
"""Generate the cn-nvr Grafana dashboards.

Outputs (committed):
  grafana/provisioning/dashboards/cerberus-overview.json  host overview for the
      local Grafana (grafana.cerberus.lan), adapted from kaiser-overview.json
  grafana/provisioning/dashboards/frigate.json            Frigate dashboard, local
      variant (no Loki datasource on cerberus)
  grafana/dist/frigate.json                               Frigate dashboard, VPS
      variant (adds Loki panels) -> copy into
      cn-root-docker/tailnet/grafana/provisioning/dashboards/frigate.json

Re-run after editing; keep uids stable (cerberus-overview, frigate).
"""
import copy, json, pathlib

ROOT = pathlib.Path(__file__).resolve().parent
PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}


def q(expr, legend=None, ref="A", instant=False):
    t = {"datasource": PROM, "expr": expr, "refId": ref}
    if legend:
        t["legendFormat"] = legend
    if instant:
        t["instant"] = True
    return t


def row(pid, title, y):
    return {"id": pid, "type": "row", "title": title, "collapsed": False,
            "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []}


def stat(pid, title, targets, x, y, w, h, unit=None, thresholds=None, decimals=None, mappings=None, color_mode="value"):
    steps = thresholds or [{"color": "green", "value": None}]
    fc = {"unit": unit} if unit else {}
    if decimals is not None:
        fc["decimals"] = decimals
    fc["thresholds"] = {"mode": "absolute", "steps": steps}
    if mappings:
        fc["mappings"] = mappings
    return {"id": pid, "type": "stat", "title": title, "datasource": PROM, "targets": targets,
            "gridPos": {"x": x, "y": y, "w": w, "h": h},
            "fieldConfig": {"defaults": fc, "overrides": []},
            "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                        "colorMode": color_mode, "graphMode": "none", "textMode": "auto", "orientation": "auto"}}


def ts(pid, title, targets, x, y, w, h, unit=None, min_=None, max_=None, stack=False, thresholds=None):
    fc = {"custom": {"lineWidth": 1, "fillOpacity": 10, "showPoints": "never"}}
    if stack:
        fc["custom"]["stacking"] = {"mode": "normal", "group": "A"}
    if unit:
        fc["unit"] = unit
    if min_ is not None:
        fc["min"] = min_
    if max_ is not None:
        fc["max"] = max_
    if thresholds:
        fc["thresholds"] = {"mode": "absolute", "steps": thresholds}
        fc["custom"]["thresholdsStyle"] = {"mode": "line"}
    return {"id": pid, "type": "timeseries", "title": title, "datasource": PROM, "targets": targets,
            "gridPos": {"x": x, "y": y, "w": w, "h": h},
            "fieldConfig": {"defaults": fc, "overrides": []},
            "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
                        "tooltip": {"mode": "multi", "sort": "desc"}}}


def gauge(pid, title, targets, x, y, w, h, unit="percent", thresholds=None):
    steps = thresholds or [{"color": "green", "value": None}, {"color": "orange", "value": 75}, {"color": "red", "value": 90}]
    return {"id": pid, "type": "gauge", "title": title, "datasource": PROM, "targets": targets,
            "gridPos": {"x": x, "y": y, "w": w, "h": h},
            "fieldConfig": {"defaults": {"unit": unit, "min": 0, "max": 100,
                                          "thresholds": {"mode": "absolute", "steps": steps}}, "overrides": []},
            "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                        "showThresholdLabels": False, "showThresholdMarkers": True}}


def logs(pid, title, expr, x, y, w, h):
    return {"id": pid, "type": "logs", "title": title, "datasource": LOKI,
            "targets": [{"datasource": LOKI, "expr": expr, "refId": "A"}],
            "gridPos": {"x": x, "y": y, "w": w, "h": h},
            "options": {"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending",
                        "dedupStrategy": "none", "enableLogDetails": True, "prettifyLogMessage": False}}


def dashboard(uid, title, tags, panels, templating=None):
    return {
        "annotations": {"list": []},
        "editable": True,
        "graphTooltip": 1,
        "links": [],
        "panels": panels,
        "refresh": "30s",
        "schemaVersion": 39,
        "tags": tags,
        "templating": {"list": templating or []},
        "time": {"from": "now-3h", "to": "now"},
        "timezone": "browser",
        "title": title,
        "uid": uid,
        "version": 1,
    }


# ── Frigate dashboard (shared by both planes through the $host variable) ──
def frigate_dashboard(with_loki: bool):
    H = 'host="$host"'
    R = 'storage=~"/media/frigate/recordings"'
    tmpl = [{
        "name": "host", "label": "host", "type": "query", "datasource": PROM,
        "definition": "label_values(frigate_camera_fps, host)",
        "query": {"query": "label_values(frigate_camera_fps, host)", "refId": "StandardVariableQuery"},
        "refresh": 1, "sort": 1, "includeAll": False, "multi": False, "hide": 0,
        "current": {}, "options": [],
    }]
    p = []
    y = 0
    p.append(row(1, "At a glance", y)); y += 1
    p.append(stat(2, "Frigate up", [q(f'up{{job="frigate",{H}}}')], 0, y, 4, 4,
                  thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}],
                  mappings=[{"type": "value", "options": {"0": {"text": "DOWN"}, "1": {"text": "UP"}}}], color_mode="background"))
    p.append(stat(3, "Uptime", [q(f'frigate_service_uptime_seconds{{{H}}}')], 4, y, 4, 4, unit="s", decimals=0))
    p.append(stat(4, "Cameras live", [q(f'count(frigate_camera_fps{{{H}}} > 0)')], 8, y, 4, 4,
                  thresholds=[{"color": "red", "value": None}, {"color": "orange", "value": 1}, {"color": "green", "value": 2}]))
    p.append(stat(5, "Detector inference", [q(f'frigate_detector_inference_speed_seconds{{{H}}} * 1000', "{{name}}")], 12, y, 4, 4,
                  unit="ms", decimals=1, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 50}, {"color": "red", "value": 100}]))
    p.append(stat(6, "Recordings free", [q(f'frigate_storage_free_bytes{{{H},{R}}} / frigate_storage_total_bytes{{{H},{R}}} * 100')], 16, y, 4, 4,
                  unit="percent", decimals=0, thresholds=[{"color": "red", "value": None}, {"color": "orange", "value": 10}, {"color": "green", "value": 25}]))
    p.append(stat(7, "Frigate CPU (all processes)", [q(f'sum(frigate_cpu_usage_percent{{{H}}})')], 20, y, 4, 4,
                  unit="percent", decimals=0, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 300}, {"color": "red", "value": 600}]))
    y += 4
    p.append(row(10, "Cameras", y)); y += 1
    p.append(ts(11, "Camera fps (stream)", [q(f'frigate_camera_fps{{{H}}}', "{{camera_name}}")], 0, y, 12, 7, unit="short", min_=0))
    p.append(ts(12, "Process fps (frames analysed)", [q(f'frigate_process_fps{{{H}}}', "{{camera_name}}")], 12, y, 12, 7, unit="short", min_=0))
    y += 7
    p.append(ts(13, "Detection fps", [q(f'frigate_detection_fps{{{H}}}', "{{camera_name}}")], 0, y, 12, 7, unit="short", min_=0))
    p.append(ts(14, "Skipped fps (detector saturated)", [q(f'frigate_skipped_fps{{{H}}}', "{{camera_name}}")], 12, y, 12, 7, unit="short", min_=0,
                thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}]))
    y += 7
    p.append(row(20, "Detector and resources", y)); y += 1
    p.append(ts(21, "Detector inference (ms)", [q(f'frigate_detector_inference_speed_seconds{{{H}}} * 1000', "{{name}}")], 0, y, 8, 7, unit="ms", min_=0,
                thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 100}]))
    p.append(ts(22, "Total detection fps", [q(f'frigate_detection_total_fps{{{H}}}', "total")], 8, y, 8, 7, unit="short", min_=0))
    p.append(ts(23, "GPU usage", [q(f'frigate_gpu_usage_percent{{{H}}}', "{{gpu_name}}"), q(f'frigate_gpu_mem_usage_percent{{{H}}}', "mem {{gpu_name}}", ref="B")], 16, y, 8, 7, unit="percent", min_=0, max_=100))
    y += 7
    p.append(ts(24, "CPU by process", [q(f'sum by (process) (frigate_cpu_usage_percent{{{H}}})', "{{process}}")], 0, y, 12, 8, unit="percent", min_=0, stack=True))
    p.append(ts(25, "Memory by process", [q(f'sum by (process) (frigate_mem_usage_percent{{{H}}})', "{{process}}")], 12, y, 12, 8, unit="percent", min_=0, stack=True))
    y += 8
    p.append(row(30, "Storage and events", y)); y += 1
    p.append(ts(31, "Frigate storage used", [q(f'frigate_storage_used_bytes{{{H}}}', "{{storage}}")], 0, y, 8, 8, unit="bytes", min_=0))
    p.append(gauge(32, "Recordings volume used", [q(f'frigate_storage_used_bytes{{{H},{R}}} / frigate_storage_total_bytes{{{H},{R}}} * 100')], 8, y, 4, 8))
    p.append(ts(33, "Events per hour (camera / label)", [q(f'sum by (camera, label) (increase(frigate_camera_events{{{H}}}[1h]))', "{{camera}} {{label}}")], 12, y, 12, 8, unit="short", min_=0))
    y += 8
    p.append(row(40, "Host", y)); y += 1
    p.append(gauge(41, "CPU", [q(f'(1 - avg(rate(node_cpu_seconds_total{{{H},mode="idle"}}[5m]))) * 100')], 0, y, 4, 6))
    p.append(gauge(42, "Memory", [q(f'(1 - node_memory_MemAvailable_bytes{{{H}}} / node_memory_MemTotal_bytes{{{H}}}) * 100')], 4, y, 4, 6))
    p.append(gauge(43, "Disk /", [q(f'(1 - node_filesystem_avail_bytes{{{H},mountpoint="/"}} / node_filesystem_size_bytes{{{H},mountpoint="/"}}) * 100')], 8, y, 4, 6))
    p.append(gauge(44, "Disk /srv", [q(f'(1 - node_filesystem_avail_bytes{{{H},mountpoint="/srv"}} / node_filesystem_size_bytes{{{H},mountpoint="/srv"}}) * 100')], 12, y, 4, 6))
    p.append(ts(45, "Network (physical interfaces)", [
        q(f'rate(node_network_receive_bytes_total{{{H},device!~"lo|docker.*|br-.*|veth.*|tailscale.*"}}[5m]) * 8', "rx {{device}}"),
        q(f'rate(node_network_transmit_bytes_total{{{H},device!~"lo|docker.*|br-.*|veth.*|tailscale.*"}}[5m]) * 8', "tx {{device}}", ref="B")], 16, y, 8, 6, unit="bps", min_=0))
    y += 6
    if with_loki:
        p.append(row(50, "Logs (VPS Loki)", y)); y += 1
        p.append(logs(51, "cn-nvr logs", '{stack="cn-nvr"}', 0, y, 24, 10)); y += 10
        p.append(logs(52, "Errors / warnings", '{stack="cn-nvr"} |~ "(?i)(error|fatal|warn|exception)"', 0, y, 24, 8)); y += 8
    return dashboard("frigate", "Frigate NVR", ["nvr", "homelab", "cn-nvr", "frigate"], p, tmpl)


# ── cerberus host overview: adapted from kaiser-overview.json (same panel set) ──
def cerberus_overview():
    H = 'host="cerberus"'
    p = []
    p.append(row(1, "At a glance", 0))
    red = [{"color": "green", "value": None}, {"color": "orange", "value": 75}, {"color": "red", "value": 90}]
    p.append(stat(2, "CPU usage", [q(f'(1 - avg(rate(node_cpu_seconds_total{{{H},mode="idle"}}[5m]))) * 100', "cpu %")], 0, 1, 6, 5, unit="percent", decimals=0, thresholds=red))
    p.append(stat(3, "Memory used", [q(f'(1 - node_memory_MemAvailable_bytes{{{H}}} / node_memory_MemTotal_bytes{{{H}}}) * 100', "mem %")], 6, 1, 6, 5, unit="percent", decimals=0, thresholds=red))
    p.append(stat(4, "Disk used (/)", [q(f'(1 - node_filesystem_avail_bytes{{{H},mountpoint="/"}} / node_filesystem_size_bytes{{{H},mountpoint="/"}}) * 100', "disk %")], 12, 1, 6, 5, unit="percent", decimals=0, thresholds=red))
    p.append(stat(12, "Disk used (/srv recordings)", [q(f'(1 - node_filesystem_avail_bytes{{{H},mountpoint="/srv"}} / node_filesystem_size_bytes{{{H},mountpoint="/srv"}}) * 100', "srv %")], 18, 1, 6, 5, unit="percent", decimals=0, thresholds=red))
    p.append(row(5, "Trends", 6))
    p.append(ts(6, "CPU usage by mode", [q(f'avg by (mode) (rate(node_cpu_seconds_total{{{H}}}[5m])) * 100', "{{mode}}")], 0, 7, 12, 8, unit="percent", min_=0, stack=True))
    p.append(ts(7, "Memory", [q(f'node_memory_MemTotal_bytes{{{H}}}', "total"),
                              q(f'node_memory_MemAvailable_bytes{{{H}}}', "available", ref="B"),
                              q(f'node_memory_MemTotal_bytes{{{H}}} - node_memory_MemAvailable_bytes{{{H}}}', "used", ref="C")], 12, 7, 12, 8, unit="bytes", min_=0))
    p.append(ts(8, "Network throughput (per interface)", [
        q(f'rate(node_network_receive_bytes_total{{{H},device!~"lo|docker.*|br-.*|veth.*|tailscale.*"}}[5m]) * 8', "rx {{device}}"),
        q(f'rate(node_network_transmit_bytes_total{{{H},device!~"lo|docker.*|br-.*|veth.*|tailscale.*"}}[5m]) * 8', "tx {{device}}", ref="B")], 0, 15, 12, 8, unit="bps", min_=0))
    p.append(ts(9, "Disk I/O", [q(f'rate(node_disk_read_bytes_total{{{H},device!~"loop.*|dm-.*"}}[5m])', "read {{device}}"),
                                q(f'rate(node_disk_written_bytes_total{{{H},device!~"loop.*|dm-.*"}}[5m])', "write {{device}}", ref="B")], 12, 15, 12, 8, unit="Bps", min_=0))
    p.append(ts(13, "Filesystem usage (/ and /srv)", [
        q(f'(1 - node_filesystem_avail_bytes{{{H},mountpoint="/"}} / node_filesystem_size_bytes{{{H},mountpoint="/"}}) * 100', "/"),
        q(f'(1 - node_filesystem_avail_bytes{{{H},mountpoint="/srv"}} / node_filesystem_size_bytes{{{H},mountpoint="/srv"}}) * 100', "/srv", ref="B")], 0, 23, 12, 7, unit="percent", min_=0, max_=100,
        thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 90}]))
    p.append(ts(14, "Load average", [q(f'node_load1{{{H}}}', "1m"), q(f'node_load5{{{H}}}', "5m", ref="B"), q(f'node_load15{{{H}}}', "15m", ref="C")], 12, 23, 12, 7, unit="short", min_=0))
    return dashboard("cerberus-overview", "cerberus.lan overview", ["cerberus", "homelab", "node-exporter"], p)


def write(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2, sort_keys=False) + "\n")
    print("wrote", path.relative_to(ROOT.parent), f"({len(obj['panels'])} panels)")


if __name__ == "__main__":
    write(ROOT / "provisioning/dashboards/cerberus-overview.json", cerberus_overview())
    write(ROOT / "provisioning/dashboards/frigate.json", frigate_dashboard(with_loki=False))
    write(ROOT / "dist/frigate.json", frigate_dashboard(with_loki=True))
