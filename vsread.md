# Dual-Engine MLOps & AIOps Platform — VS Code / WSL Quick Reference

> **Environment**: WSL2 (Ubuntu) | User: `crysis` | Project Root: `\\wsl.localhost\Ubuntu\home\crysis\project_1`

---

## Table of Contents

- [WSL Path Reference](#wsl-path-reference)
- [Environment Setup](#environment-setup)
- [Running the AIOps Engine](#running-the-aiops-engine)
- [Running the MLOps Drift Stack](#running-the-mlops-drift-stack)
- [Kubernetes Port Forwards](#kubernetes-port-forwards)
- [Project Structure](#project-structure)
- [Key Config Files](#key-config-files)

---

## WSL Path Reference

| Context | Path |
|---|---|
| Windows Explorer / VS Code UNC | `\\wsl.localhost\Ubuntu\home\crysis\project_1` |
| Linux shell inside WSL | `/home/crysis/project_1` |
| VS Code workspace URI | `vscode-remote://wsl+ubuntu/home/crysis/project_1` |

> **Tip**: In VS Code, use `Ctrl+Shift+P` → `WSL: Open Folder in WSL` to open this project natively inside WSL for best performance.

---

## Environment Setup

```bash
# Activate virtual environment (from WSL terminal)
cd /home/crysis/project_1
source .venv/bin/activate

# Install / sync dependencies
pip install -r requirements.txt
```

---

## Running the AIOps Engine

All commands run from the project root inside WSL.

### Train Anomaly Models
```bash
python Ensemble_engine.py --mode train
```
Pulls baseline metrics from Prometheus, trains Isolation Forest + LSTM Autoencoder, and saves models to `models/`.

### Live Comparison Demo
```bash
python Ensemble_engine.py --mode compare
```
Simulates normal vs. anomaly scenarios side-by-side.

### Production Daemon (Live Polling)
```bash
python Ensemble_engine.py --mode run
```
Polls Prometheus every 30 seconds, exposes gauges on `:8000`, fires alerts to AlertManager on `:9093`.

---

## Running the MLOps Drift Stack

### 1. Seed MinIO & Register Kubeflow Pipeline
```bash
python seed_minio.py
python pipeline.py
```

### 2. Start the Drift Trigger Webhook (port 8766)
```bash
cd drift
uvicorn drift_trigger:app --port 8766
```

### 3. Start the Drift Observability Server (port 8765)
```bash
cd drift
python drit_server.py
```

### 4. Simulate Drift Traffic
```bash
# Clean / no drift
python drift/simulate_drift.py --mode clean --requests 150

# Data drift
python drift/simulate_drift.py --mode data_drift --requests 150

# Concept drift
python drift/simulate_drift.py --mode concept_drift --requests 150
```

---

## Kubernetes Port Forwards

Run these in separate WSL terminals before starting any component:

```bash
# Prometheus
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090

# MinIO
kubectl port-forward -n kubeflow svc/minio-service 9000:9000

# Kubeflow Pipelines UI
kubectl port-forward -n kubeflow svc/ml-pipeline-ui 8080:8080
```

---

## Project Structure

```
project_1/
├── Ensemble_engine.py       # AIOps orchestrator (train / run / compare modes)
├── iforest_detector.py      # Isolation Forest anomaly detector
├── lstm_detecter.py         # LSTM Autoencoder sequence detector
├── drift_detector.py        # PSI + KS-test statistical drift engine
├── prom_client.py           # Prometheus HTTP client
├── metric_registry.py       # Metrics config loader
├── metrics_config.yaml      # Declarative metric definitions
├── pipeline.py              # Kubeflow Pipeline (KFP v2) definition
├── train_component.py       # KFP training component wrapper
├── seed_minio.py            # MinIO bootstrap script
├── k8s_crew.py              # CrewAI K8s analyst (OLLAMA-powered)
├── drift/                   # MLOps drift microservices
│   ├── drifft_detector.py   # Evidently AI drift logic
│   ├── drit_server.py       # FastAPI drift server (:8765)
│   ├── drift_trigger.py     # FastAPI retrain webhook (:8766)
│   ├── simulate_drift.py    # Drift traffic simulator
│   ├── drift_config.yaml    # Evidently + MinIO config
│   └── drift_k8.yaml        # Kubernetes manifests
├── models/                  # Saved ML model artifacts
├── monitoring/              # AlertManager + ServiceMonitor configs
├── k8s/                     # Kubernetes manifests
├── infra/                   # Infrastructure configs
├── pipeline/                # Pipeline components
├── configs/                 # General configs
├── .env                     # Environment variables (secrets)
├── requirements.txt         # Python dependencies
├── Dockerfile               # Container build file
└── vsread.md                # This file
```

---

## Key Config Files

| File | Purpose |
|---|---|
| `metrics_config.yaml` | Add new Prometheus metrics to monitor (no Python changes needed) |
| `drift/drift_config.yaml` | Tune Evidently thresholds, window sizes, MinIO paths |
| `alertmanager_config.yml` | AlertManager routing and webhook targets |
| `promRules.yml` | Prometheus alerting rules |
| `.env` | Environment variables (MinIO creds, Kubeflow endpoint, etc.) |
| `mcp_config.json` | MCP server configuration |

---

*Generated for project_1 — WSL2/Ubuntu environment, user: crysis*
