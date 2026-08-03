# SRE Hands-On Evaluation — Notes API on k3s

> A production-style deployment of a Flask microservice on a single-node **k3s** cluster —
> with fully automated **CI/CD**, complete **observability** (Prometheus / Grafana / Loki),
> three documented **failure simulations**, and full **incident-response artifacts**
> (RCAs + runbook).

<p align="left">
  <b>Author:</b> Vishnu K &nbsp;•&nbsp;
  <b>Delivery:</b> Aug 4, 2026
</p>

| Resource | URL | Access |
|---|---|---|
| 🌐 **Application** | http://13.126.63.217 | public |
| 📊 **Grafana** | http://13.126.63.217:30080 | `admin` / `admin123` — opens on **"Notes API — Service Health"** |
| 🔔 **Prometheus** | http://13.126.63.217:30090 | public (`/alerts`, `/targets`, `Status → Rules`) |
| ⚙️ **CI/CD** | GitHub → **Actions** tab | build → scan → deploy |

---

## Table of contents
1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Tech stack & decisions](#3-tech-stack--decisions)
4. [Repository layout](#4-repository-layout)
5. [Viewing instructions](#5-viewing-instructions-for-reviewers)
6. [Setup](#6-setup-reproduce-from-scratch)
7. [Teardown](#7-teardown)
8. [Failure simulations & incident response](#8-failure-simulations--incident-response)
9. [Security](#9-security)
10. [Assumptions & deviations](#10-assumptions--deviations)
11. [Delivery](#11-delivery)

---

## 1. Overview

A Flask **"Notes API"** microservice backed by PostgreSQL, serving its own HTML frontend.
The application is intentionally simple — it is a **vehicle** for demonstrating SRE
practices end to end: provisioning, containerization, orchestration, CI/CD, monitoring,
alerting, logging, resilience engineering, and incident response.

The app exposes hooks that make each SRE capability demonstrable:

| Endpoint | Purpose |
|---|---|
| `/` | HTML frontend (add/list notes) |
| `/health` | Kubernetes liveness/readiness probes |
| `/metrics` | Prometheus metrics (request rate, latency, custom counter + DB-backed gauge) |
| `/api/notes` | GET/POST notes to PostgreSQL — enables the **DB-failure** scenario |
| `/api/stress` | CPU busy-loop — enables the **high-CPU** scenario |

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
 │   │   │     │         evaluates alert + recording rules         │   │  │
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

## 3. Tech stack & decisions

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
| Alerting | **Prometheus rules** + Alertmanager | 5 alert rules + 3 recording rules |

> Full reasoning and trade-offs for every choice are documented in
> [`docs/design-notes.md`](docs/design-notes.md).

---

## 4. Repository layout

```
.
├── README.md                          # this file
├── app/                               # Flask app + container
│   ├── app.py
│   ├── requirements.txt
│   ├── Dockerfile                     # non-root, python:3.12-slim, gunicorn
│   └── templates/index.html
├── helm/notes-app/                    # Helm chart
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── dashboards/
│   │   └── dashboard.json             # Grafana dashboard JSON export
│   └── templates/                     # 13 templates:
│       ├── app-deployment.yaml        #   app (2 replicas, probes, limits)
│       ├── app-service.yaml
│       ├── configmap.yaml             #   non-secret config
│       ├── secret.yaml                #   DB password
│       ├── serviceaccount.yaml        #   RBAC, token disabled
│       ├── ingress.yaml               #   Traefik
│       ├── networkpolicy.yaml
│       ├── postgres-deployment.yaml
│       ├── postgres-service.yaml
│       ├── postgres-pvc.yaml
│       ├── servicemonitor.yaml        #   Prometheus scrape config
│       └── prometheusrule.yaml        #   5 alerts + 3 recording rules
├── .github/workflows/
│   └── build-deploy.yml               # CI/CD: build → Trivy → push → deploy
├── tests/                             # failure-simulation scripts
│   ├── simulate-pod-crashloop.sh
│   ├── simulate-db-outage.sh
│   └── simulate-high-cpu.sh
└── docs/
    ├── rca-01-pod-crashloop.md        # RCA / postmortem (5-whys + timeline)
    ├── rca-02-database-outage.md
    ├── rca-03-high-cpu.md
    ├── runbook.md                     # on-call remediation playbook
    ├── security.md                    # secrets, RBAC, network, scanning
    ├── design-notes.md                # key decisions & trade-offs
    ├── prometheus-config-notes.md     # scrape / alerting / recording rules
    ├── loki-stack-values.yaml         # Loki + Promtail config
    ├── grafana-dashboards-README.md   # dashboard import instructions
    ├── ALL-COMMANDS.txt               # full command reference
    └── evidence/                      # failure-simulation screenshots
```

---

## 5. Viewing instructions (for reviewers)

The environment is **live** — no setup needed to view it:

| What | URL | Notes |
|---|---|---|
| Application | http://13.126.63.217 | Add notes, ping health, run CPU stress |
| Grafana | http://13.126.63.217:30080 | `admin` / `admin123` — opens on **"Notes API — Service Health"** by default |
| Prometheus alerts | http://13.126.63.217:30090/alerts | the 5 alert rules |
| Prometheus rules | http://13.126.63.217:30090 → Status → Rules | recording rules |
| Prometheus targets | http://13.126.63.217:30090/targets | scrape health (`notes-api` job) |
| Logs (Loki) | Grafana → Explore → Loki | query `{namespace="default"}` |
| CI/CD | GitHub → **Actions** tab | pipeline runs |

---

## 6. Setup (reproduce from scratch)

> Full command reference: [`docs/ALL-COMMANDS.txt`](docs/ALL-COMMANDS.txt)

**Prerequisites:** an Ubuntu VM, a GitHub account, and the repo cloned.

```bash
# 1. Install k3s
curl -sfL https://get.k3s.io | sudo sh -

# 2. Install Helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# 3. Deploy the app (image built + pushed by CI/CD; built locally for the first run)
cd ~/SRE-Project1
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
  helm upgrade --install notes-app ./helm/notes-app --wait

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
  -f docs/loki-stack-values.yaml \
  --wait --timeout 5m
```

**CI/CD:** pushing to `main` automatically builds, scans, pushes, and deploys.
Requires GitHub Secrets: `VM_HOST`, `VM_USER`, `VM_SSH_KEY`.

**Dashboard import:** see [`docs/grafana-dashboards-README.md`](docs/grafana-dashboards-README.md).

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

Three failure scenarios — spanning **config**, **dependency**, and **resource**
failure classes — were simulated, detected, documented, and recovered. Each has a
script in `tests/` and a full RCA in `docs/` with embedded evidence screenshots.

| # | Scenario | Class | Script | Alert fired | Time-to-detection | RCA |
|---|---|---|---|---|---|---|
| 1 | Pod Crash Loop | config | `simulate-pod-crashloop.sh` | `NotesApiPodCrashLooping` | ~2m 28s | [rca-01](docs/rca-01-pod-crashloop.md) |
| 2 | DB Connectivity Loss | dependency | `simulate-db-outage.sh` | `NotesApiHighErrorRate` | ~2m 12s | [rca-02](docs/rca-02-database-outage.md) |
| 3 | High CPU Exhaustion | resource | `simulate-high-cpu.sh` | `NotesApiHighCPU` | ~2m 38s | [rca-03](docs/rca-03-high-cpu.md) |

- **Runbook** (restart, scale, rollback, DB recovery): [`docs/runbook.md`](docs/runbook.md)
- **Alert + recording rules:** `helm/notes-app/templates/prometheusrule.yaml`
  (documented in [`docs/prometheus-config-notes.md`](docs/prometheus-config-notes.md))

```bash
# Run a simulation
cd ~/SRE-Project1
./tests/simulate-pod-crashloop.sh            # inject
./tests/simulate-pod-crashloop.sh --recover  # restore
```

---

## 9. Security

Full details in [`docs/security.md`](docs/security.md). Summary:

| Control | Status |
|---|---|
| No secrets in repo (ConfigMap/Secret + GitHub Secrets, 12-factor) | ✅ |
| RBAC least privilege (dedicated SA, API token disabled) | ✅ |
| CI/CD deploys as non-root (scoped kubeconfig, not host root) | ✅ |
| Non-root container, minimal `python:3.12-slim` base | ✅ |
| Image vulnerability scanning (Trivy, CRITICAL/HIGH) | ✅ |
| Network segmentation (NetworkPolicy declared) | ⚠️ declared, not enforced on k3s Flannel — needs Calico (documented) |

---

## 10. Assumptions & deviations

- **Ubuntu 24.04 instead of 22.04** — 22.04 was not available in the AWS Mumbai
  Quick Start AMIs at launch; 24.04 is an equivalent LTS satisfying "Ubuntu 22.04
  or similar."
- **VM RAM raised to 16 GB** (from the 4 GB minimum) to comfortably run k3s plus the
  Prometheus/Grafana/Loki stack — the assignment permits "adjust if running heavier
  services."
- **NetworkPolicy declared but not enforced** on default k3s (Flannel) — see
  `docs/security.md` and `docs/design-notes.md`.
- **Email/Alertmanager notification routing scoped out** — the assignment requires
  alert *rules* (5 implemented); notification delivery is a documented design choice
  deferred to protect time for incident-response documentation. Alertmanager is
  deployed and ready to be configured.
- **Single-node cluster** — the node and the in-cluster PostgreSQL are single points
  of failure; production would use a multi-node cluster and HA/managed PostgreSQL.
- **k3s control-plane alerts** (`KubeControllerManagerDown`, etc.) fire as false
  positives because k3s bundles those components differently — see `docs/design-notes.md`.

---

## 11. Delivery

- **Estimated delivery:** on or before **Aug 4, 2026, 12:00 PM IST**.
- **Deliverables:** this repository (app, Helm chart, CI/CD, observability configs,
  failure scripts, RCAs, runbook, security notes, design notes), a live environment
  at the Elastic IP above, and a short demo video.
- **Blockers:** none.