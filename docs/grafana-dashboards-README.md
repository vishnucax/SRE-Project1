# Grafana Dashboards

JSON export of the custom **Notes API — Service Health** dashboard, satisfying the
requirement to provide *"Grafana dashboards (JSON exports), and instructions on
importing."*

## Files
- `dashboard.json` — the custom service-health dashboard (8 panels)
  *(located in `helm/notes-app/dashboards/dashboard.json`)*

## Panels
| # | Panel | Data source | Query |
|---|---|---|---|
| 1 | Request Rate by Status | Prometheus | `sum(rate(flask_http_request_total[5m])) by (status)` |
| 2 | Request Latency p95 by Path | Prometheus | `histogram_quantile(0.95, sum(rate(flask_http_request_duration_seconds_bucket[5m])) by (le, path))` |
| 3 | Total Notes Created (counter) | Prometheus | `notes_created_total` |
| 4 | App Replicas Up | Prometheus | `count(up{job="notes-api"} == 1)` |
| 5 | App Memory per Pod | Prometheus | `sum(container_memory_working_set_bytes{namespace="default", pod=~"notes-api.*"}) by (pod)` |
| 6 | Total Notes in DB (gauge) | Prometheus | `max(notes_in_db)` |
| 7 | Application Logs | Loki | `{namespace="default"}` |
| 8 | Application Errors & Warnings | Loki | `{namespace="default"} \|= "ERROR"` |

## Prerequisites
The dashboard expects two Grafana data sources:
- **Prometheus** — installed automatically by the kube-prometheus-stack chart.
- **Loki** — add it in Grafana: `Connections → Data sources → Add data source → Loki`,
  URL `http://loki:3100` (or `http://loki.monitoring.svc.cluster.local:3100`).

## How to import

1. Open Grafana → http://13.126.63.217:30080 (login `admin` / `admin123`)
2. Left sidebar → **Dashboards** → **New** → **Import**
3. **Upload dashboard JSON file** → select `dashboard.json`
   *(or paste the file contents into the JSON text box)*
4. When prompted, select the **Prometheus** and **Loki** data sources
5. Click **Import**

The dashboard appears under Dashboards with live service-health metrics and logs.

## Setting it as the default (optional)
To make this the dashboard reviewers see on login:
`Administration → Default preferences → Home Dashboard → Notes API — Service Health → Save`.

## Cluster / infrastructure dashboards
The "cluster metrics" side of the observability requirement is covered by the
**pre-built dashboards** bundled with the kube-prometheus-stack chart (e.g.
*Node Exporter / Nodes*, *Kubernetes / Compute Resources / Cluster*). These are
installed automatically and need no manual import. A snapshot is included at
`docs/evidence/cluster-metrics-dashboard.png`.
