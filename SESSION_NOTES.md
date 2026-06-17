# Session Notes — MLOps/AIOps Platform Setup
> Last updated: 2026-06-14 | Conversation ID: 973efcd9-80a3-46fc-ac8e-81d498a82127

---

## 🎯 What We Are Trying to Do

The project is a **Dual-Engine MLOps & AIOps Platform** running on **minikube inside WSL2** (Ubuntu, user: `crysis`).

The goal of these sessions is:
1. **Automate the painful one-time cluster setup** into a single script (`cluster_setup.sh`)
2. **Automate the "boring parallel running"** of 7 services every session into a single script (`start_all.sh`)
3. **Test both scripts work end-to-end** on a fresh minikube cluster

---

## 📁 Key File Locations

> ⚠️ The correct WSL path is `\\wsl.localhost\Ubuntu\home\crysis\project_1\`
> NOT `/Ubuntu/home/crysis/project_1` — this was a recurring mistake in early sessions.

| File | Purpose |
|---|---|
| `cluster_setup.sh` | One-time bootstrap — run once after `minikube start` |
| `start_all.sh` | Launches all 7 services every session |
| `stop_all.sh` | Kills all services cleanly (reads `.pids` file) |
| `vsread.md` | VS Code / WSL quick-reference for the project |
| `pipeline.py` | KFP pipeline definition — lives at **project root** (NOT inside `pipeline/`) |
| `Ensemble_engine.py` | AIOps orchestrator — train/run/compare modes |
| `drift/drit_server.py` | Drift observability server — port 8765 |
| `drift/drift_trigger.py` | Retrain webhook — port 8766 |
| `training/generate_data.py` | Generates synthetic churn training data |
| `seed_minio.py` | Seeds MinIO bucket with baseline data |
| `configs/monitoring-values.yml` | Helm values for kube-prometheus-stack |
| `infra/svcacc.yaml` | Service account + S3 secret for MinIO |
| `alertmanager_config.yml` | AlertManager Slack + webhook routing |

---

## 🛠️ Scripts Built This Session

### `cluster_setup.sh` — Steps 1–10

| Step | What it does | Automated? |
|---|---|---|
| 1 | Verify minikube is running (fails fast if not) | ✅ |
| 2 | Install Kubeflow Pipelines v2.14.3 (idempotent) | ✅ |
| 3 | Patch MinIO to stable image | ✅ |
| 4 | Patch workflow-controller-configmap (runAsNonRoot: false) | ✅ Previously manual |
| 5 | Apply infra/svcacc.yaml (service account + S3 secret) | ✅ |
| 6 | Install kube-prometheus-stack via Helm | ✅ |
| 7 | Apply AlertManager config secret | ✅ |
| 8 | Seed MinIO (generate_data.py + seed_minio.py) | ✅ |
| 9 | Register Kubeflow Pipeline (pipeline.py) | ✅ |
| 10 | Train AIOps anomaly models (Ensemble_engine.py --mode train) | ✅ |

### `start_all.sh` — 7 Services in Order

| # | Service | Port |
|---|---------|------|
| 1 | Prometheus port-forward | 9090 |
| 2 | AlertManager port-forward | 9093 |
| 3 | MinIO port-forward | 9000 |
| 4 | Kubeflow UI port-forward | 8080 |
| 5 | AIOps Ensemble daemon (`Ensemble_engine.py --mode run`) | 8000 |
| 6 | Drift Trigger webhook (`drift_trigger.py`) | 8766 |
| 7 | Drift Observability server (`drit_server.py`) | 8765 |

> Logs written to `.logs/` directory. Ctrl+C stops everything.

---

## ⚠️ Known Bugs Still To Fix (Before Next Test)

### `start_all.sh` — 2 bugs not yet fixed

1. **`drift/drift_trigger.py` must run from inside `drift/` directory**
   - It opens `drift_config.yaml` relative to CWD
   - Current command: `"$VENV" -m uvicorn drift.drift_trigger:app --host 0.0.0.0 --port 8766`
   - Fix needed: `cd "$SCRIPT_DIR/drift" && uvicorn drift_trigger:app --port 8766`

2. **`drift/drit_server.py` must also run from inside `drift/` directory**
   - Same reason — opens `drift_config.yaml` via relative path
   - Current command: `"$VENV" drift/drit_server.py`
   - Fix needed: `cd "$SCRIPT_DIR/drift" && python drit_server.py`

> ✅ These bugs were identified but user said "fix later" — apply before running `start_all.sh`

---

## 🧪 What Needs Testing Next Session

### Phase 1 — Test `cluster_setup.sh`
```bash
# In WSL terminal
minikube start
cd /home/crysis/project_1
./cluster_setup.sh
```
Watch for any step failures and report back.

### Phase 2 — Fix `start_all.sh` bugs (drift/ CWD issue)
Apply the two bug fixes above before running.

### Phase 3 — Test `start_all.sh`
```bash
./start_all.sh
```
Verify all 7 services come up by checking:
```bash
curl http://localhost:9090/-/healthy     # Prometheus
curl http://localhost:8000/metrics       # AIOps exporter
curl http://localhost:8765/health        # Drift server
curl http://localhost:8766/health        # Drift trigger
```

### Phase 4 — Simulate drift and verify auto-retrain
```bash
python drift/simulate_drift.py --scenario drift --n 200
# Watch drift_trigger log for KFP run being created
```

---

## 🏗️ Architecture Reminder

```
minikube (WSL2)
├── kubeflow namespace
│   ├── MinIO          :9000  (S3 storage for data + models)
│   └── KFP UI         :8080  (pipeline orchestration)
└── monitoring namespace
    ├── Prometheus     :9090  (metrics store)
    └── AlertManager   :9093  (alert routing → Slack)

Local Python processes (started by start_all.sh)
├── Ensemble_engine.py :8000  (AIOps — pulls from Prometheus, detects anomalies)
├── drift_trigger.py   :8766  (webhook — triggers KFP retraining on drift)
└── drit_server.py     :8765  (drift exporter — Evidently AI → Prometheus metrics)
```

---

## 💡 Notes & Decisions Made

- **minikube is pre-installed** in WSL — `cluster_setup.sh` does NOT install it or manage addons
- **`cluster_setup.sh` fails fast** if minikube isn't running (user must `minikube start` manually first)
- **`pipeline.py` lives at project root** — NOT inside `pipeline/` (that folder is now empty)
- **`pipeline/pipeline.py`** was deleted by user mid-session
- **Docker image**: `crysis307/churn-train:v13` (latest, defined in `Dockerfile`)
