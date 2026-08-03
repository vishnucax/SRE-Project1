# SRE Hands-On Evaluation — Notes API on k3s

A production-style deployment of a small microservice on a single-node **k3s**
cluster, with fully automated **CI/CD**, complete **observability**
(Prometheus / Grafana / Loki), documented **failure simulations**, and
**incident-response artifacts** (RCAs + runbook).

**Author:** Vishnu K
**Live app:** http://13.126.63.217
**Grafana:** http://13.126.63.217:30080 (`admin` / `admin123`)
**Prometheus:** http://13.126.63.217:30090

---

## 1. What this is

A Flask "Notes API" microservice backed by PostgreSQL, serving its own HTML
frontend. The application is intentionally simple — it is a **vehicle** for
demonstrating SRE practices: provisioning, containerization, orchestration,
CI/CD, monitoring, alerting, logging, resilience engineering, and incident
response.

The app exposes hooks that make each SRE capability demonstrable:
- `/health` — Kubernetes liveness/readiness probes
- `/metrics` — Prometheus metrics (request rate, latency, custom counters/gauges)
- `/api/notes` — reads/writes PostgreSQL (enables the DB-failure scenario)
- `/api/stress` — CPU busy-loop (enables the high-CPU scenario)

---

## 2. Architecture

```
                              ┌─────────────────────────┐
        git push (main)       │      GitHub              │
   ────────────────────────►  │  ┌───────────────────┐  │
                              │  │  GitHub Actions    │  │
                              │  │  build → Trivy     │  │
                              │  │  scan → push image │  │
                              │  └─────────┬─────────┘  │
                              │            │  push       │
                              │            ▼             │
                              │   ghcr.io/vishnucax/     │
                              │      sre-project1        │
                              └────────────┬────────────┘
                                           │ SSH deploy (helm upgrade)
                                           │ (non-root, scoped kubeconfig)
                                           ▼
 ┌──────────────────────────────────────────────────────────────────────┐
 │  AWS EC2 VM (Ubuntu 24.04, t3.xlarge)  —  Elastic IP 13.126.63.217     │
 │                                                                        │
 │   ┌──────────────────────  k3s cluster  ───────────────────────────┐  │
 │   │                                                                 │  │
 │   │   Traefik Ingress (:80)                                         │  │
 │   │        │                                                        │  │
 │   │        ▼                                                        │  │
 │   │   ┌─────────────┐   round-robin    namespace: default          │  │
 │   │   │ notes-api    │◄── 2 replicas ──┐                            │  │
 │   │   │ (Flask +     │                 │                            │  │
 │   │   │  gunicorn)   │──► PostgreSQL ◄─┘  (ClusterIP, PVC-backed)   │  │
 │   │   └──────┬───────┘   notes-api-postgres                         │  │
 │   │          │ /metrics, stdout logs                                │  │
 │   │          │                                                      │  │
 │   │   namespace: monitoring                                         │  │
 │   │   ┌──────▼────────────────────────────────────────────────┐    │  │
 │   │   │ Prometheus ── scrapes /metrics (ServiceMonitor)         │   │  │
 │   │   │     │         evaluates PrometheusRule alerts           │   │  │
 │   │   │     ▼                                                    │   │  │
 │   │   │ Alertmanager                                             │   │  │
 │   │   │ Grafana ── dashboards (metrics) + Loki (logs)            │   │  │
 │   │   │ Loki ◄── Promtail ships pod stdout logs                  │   │  │
 │   │   └──────────────────────────────────────────────────────┘    │  │
 │   └─────────────────────────────────────────────────────────────┘  │
 └──────────────────────────────────────────────────────────────────────┘
                     ▲
                     │ browser
                   Reviewer  (app :80, Grafana :30080, Prometheus :30090)
```

**Flow:** push to `main` → GitHub Actions builds + scans + pushes the image →
deploys to k3s via Helm over SSH → Prometheus scrapes the app → Grafana visualizes
metrics + logs → alerts fire on failures.

---

## 3. Tech stack

| Layer | Choice | Why |
|---|---|---|
| Cloud / VM | AWS EC2, Ubuntu 24.04, t3.xlarge | Per assignment; RAM raised for the monitoring stack |
| Orchestration | **k3s** | Lightweight Kubernetes; Traefik ingress built in |
| App | Python **Flask** + **gunicorn** | Small, easy to instrument; production WSGI server |
| Database | **PostgreSQL** (in-cluster, PVC) | Assignment-recommended; enables DB-failure scenario |
| Packaging | **Helm** | Templated, reproducible Kubernetes manifests |
| Registry | **ghcr.io** | Free, integrates with GitHub Actions via `GITHUB_TOKEN` |
| CI/CD | **GitHub Actions** | Build → Trivy scan → push → deploy |
| Metrics | **Prometheus** + node-exporter + kube-state-metrics | Cluster + app metrics |
| Dashboards | **Grafana** | Service-health + cluster dashboards |
| Logs | **Loki** + **Promtail** | Log aggregation from pod stdout |
| Alerting | **Prometheus rules** + Alertmanager | 5 alert rules covering the failure scenarios |

---

## 4. Repository layout

```
.
├── app/                      # Flask app, Dockerfile, HTML frontend
│   ├── app.py
│   ├── requirements.txt
│   ├── Dockerfile
│   └── templates/index.html
├── helm/notes-app/           # Helm chart
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/            # deployment, service, configmap, secret,
│                             # ingress, postgres, pvc, serviceaccount,
│                             # networkpolicy, servicemonitor, prometheusrule
├── .github/workflows/
│   └── build-deploy.yml      # CI/CD pipeline
├── tests/                    # failure-simulation scripts
│   ├── simulate-pod-crashloop.sh
│   ├── simulate-db-outage.sh
│   └── simulate-high-cpu.sh
└── docs/
    ├── rca-01-pod-crashloop.md
    ├── rca-02-database-outage.md
    ├── rca-03-high-cpu.md
    ├── runbook.md
    ├── security.md
    ├── design-notes.md
    ├── grafana-dashboards/   # dashboard JSON exports
    └── evidence/             # failure-simulation screenshots
```

---

## 5. Viewing instructions (for reviewers)

The environment is **live** — no setup needed to view it:

| What | URL | Notes |
|---|---|---|
| Application | http://13.126.63.217 | Add notes, ping health, run CPU stress |
| Grafana | http://13.126.63.217:30080 | Login `admin` / `admin123` → dashboard "Notes API — Service Health" |
| Prometheus | http://13.126.63.217:30090 | `/alerts` shows alert rules; `/targets` shows scrape health |
| Logs (Loki) | Grafana → Explore → Loki | Query `{namespace="default"}` |

**CI/CD:** see the **Actions** tab of this GitHub repo for pipeline runs (build → scan → deploy).

---

## 6. Setup (reproduce from scratch)

> Full command reference: `docs/ALL-COMMANDS.txt`

**Prerequisites:** an Ubuntu VM, a GitHub account, and the repo cloned.

```bash
# 1. Install k3s
curl -sfL https://get.k3s.io | sudo sh -

# 2. Install Helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# 3. Deploy the app (image built + pushed by CI/CD, or built locally for first run)
cd ~/SRE-Project1
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm upgrade --install notes-app ./helm/notes-app --wait

# 4. Install the observability stack
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl create namespace monitoring

helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.adminPassword='admin123' \
  --set grafana.service.type=NodePort --set grafana.service.nodePort=30080 \
  --set prometheus.service.type=NodePort --set prometheus.service.nodePort=30090 \
  --set prometheus.prometheusSpec.retention=6h \
  --wait --timeout 10m

helm install loki grafana/loki-stack \
  --namespace monitoring \
  --set grafana.enabled=false --set prometheus.enabled=false \
  --wait --timeout 5m
```

**CI/CD:** pushing to `main` automatically builds, scans, pushes, and deploys.
Requires GitHub Secrets: `VM_HOST`, `VM_USER`, `VM_SSH_KEY`.

---

## 7. Teardown

```bash
# Remove the app
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm uninstall notes-app

# Remove the monitoring stack
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm uninstall monitoring -n monitoring
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm uninstall loki -n monitoring
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl delete namespace monitoring

# (Full teardown) uninstall k3s
/usr/local/bin/k3s-uninstall.sh

# (AWS) stop or terminate the EC2 instance; release the Elastic IP when done
```

---

## 8. Failure simulations & incident response

Three failure scenarios were simulated, documented, and recovered. Each has a
script in `tests/` and a full RCA in `docs/`.

| # | Scenario | Script | Alert fired | Time-to-detection | RCA |
|---|---|---|---|---|---|
| 1 | Pod Crash Loop | `simulate-pod-crashloop.sh` | `NotesApiPodCrashLooping` | ~2m 28s | `docs/rca-01-pod-crashloop.md` |
| 2 | DB Connectivity Loss | `simulate-db-outage.sh` | `NotesApiHighErrorRate` | ~2m 12s | `docs/rca-02-database-outage.md` |
| 3 | High CPU Exhaustion | `simulate-high-cpu.sh` | `NotesApiHighCPU` | ~2m 38s | `docs/rca-03-high-cpu.md` |

**Runbook** for common remediation: `docs/runbook.md`.
**Alert rules** (5 total): `helm/notes-app/templates/prometheusrule.yaml`.

To run a simulation:
```bash
cd ~/SRE-Project1
./tests/simulate-pod-crashloop.sh          # inject
./tests/simulate-pod-crashloop.sh --recover # restore
```

---

## 9. Security

Summary (full details in `docs/security.md`):
- **No secrets in the repo** — ConfigMap (non-secret) + Secret (DB password) +
  GitHub Secrets for CI. Config read from env vars (12-factor).
- **RBAC least privilege** — dedicated ServiceAccount with the API token disabled.
- **CI/CD deploys as non-root** with a scoped kubeconfig (not host root).
- **Non-root container** on a minimal `python:3.12-slim` base.
- **Image scanning** — Trivy scans every image in CI (CRITICAL/HIGH).
- **Network segmentation** — NetworkPolicy declared; **note:** default k3s Flannel
  does not enforce NetworkPolicies (would require Calico in production) — documented
  honestly rather than overstated.

---

## 10. Assumptions & deviations

- **Ubuntu 24.04 instead of 22.04** — Ubuntu 22.04 was not available in the AWS
  Mumbai Quick Start AMIs at launch; 24.04 is an equivalent LTS release satisfying
  "Ubuntu 22.04 or similar."
- **VM RAM raised to 16 GB** (from the 4 GB minimum) to comfortably run k3s plus the
  Prometheus/Grafana/Loki stack — the assignment permits "adjust if running heavier
  services."
- **NetworkPolicy is declared but not enforced** on default k3s (Flannel) —
  documented in `docs/security.md`.
- **Email/Alertmanager notification routing was scoped out** — the assignment
  requires alert *rules* (implemented, 5 of them); notification delivery (email/Slack)
  is a documented design choice deferred to protect time for incident-response
  documentation. Alertmanager is deployed and ready to be configured.
- **Single-node cluster** — the node and the in-cluster PostgreSQL are single points
  of failure; production would use a multi-node cluster and HA/managed PostgreSQL.

---

## 11. Delivery

- **Estimated delivery:** on or before **Aug 4, 2026, 12:00 PM IST**.
- **Deliverables:** this repository (app, Helm chart, CI/CD, observability configs,
  failure scripts, RCAs, runbook, security notes, design notes), a live environment
  at the Elastic IP above, and a short demo video.
- **Blockers:** none.
