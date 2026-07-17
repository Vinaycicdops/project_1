# Session Notes — MLOps/AIOps Platform Setup
> Last updated: 2026-07-16 | Conversation ID: 79645a99-431d-4982-b843-52adf435954a

---

## 🎯 What We Are Trying to Do

The project is a **Dual-Engine MLOps & AIOps Platform** running on **minikube inside WSL2** (Ubuntu, user: `crysis`).
The platform implements an automated drift detection, alerting, and retraining loop (self-healing ML pipeline).

---

## 📁 Key File Locations

> ⚠️ The correct WSL path is `\\wsl.localhost\Ubuntu\home\crysis\project_1\`

| File | Purpose |
|---|---|
| `cluster_setup.sh` | One-time bootstrap — run once after `minikube start` |
| `start_all.sh` | Launches all 7 services every session |
| `alertmanager_config.yml` | AlertManager Slack + webhook routing |
| `pipeline.py` | KFP pipeline definition — compiles/uploads template |
| `Ensemble_engine.py` | AIOps orchestrator — train/run/compare modes |
| `drift/drit_server.py` | Drift observability server — port 8765 |
| `drift/drift_trigger.py` | Retrain webhook — port 8766 |
| `drift/drift_config.yaml` | Configuration for drift server and trigger |
| `drift/simulate_drift.py` | Simulates production traffic scenarios (clean/drift/concept) |

---

## 📅 Work Completed Today (July 16, 2026)

Today we solved integration bugs and successfully ran the end-to-end drift-to-retrain loop:

1. **Evidently 0.7.x Compatibility Fixes**
   * Modified [drift/drifft_detector.py](file://wsl.localhost/Ubuntu/home/crysis/project_1/drift/drifft_detector.py) to use Evidently's legacy compatibility layer (`evidently.legacy.report` and `evidently.legacy.metric_preset`). This resolved the `column_mapping` and `stattest` parameter signature incompatibilities.

2. **KFP v2 Template & Client Integration**
   * Updated `pipeline.py` to compile the pipeline into a YAML file and upload/register it to the Kubeflow Templates Registry.
   * Refactored `drift_trigger.py` to use the KFP v2 client APIs (`run_pipeline`), resolve the `Default` experiment, and automatically query and pass the latest `version_id`.

3. **Slack Alert Integration**
   * Configured AlertManager with the live Slack Webhook URL.

4. **Retraining Verification**
   * Lowered retraining threshold from `0.4` to `0.3` in `drift_config.yaml`.
   * Verified that the drift server successfully detected simulated drift, triggered the webhook, and successfully launched a retraining run in Kubeflow.

---

## 🧪 How to Reset/Simulate Drift Status Tomorrow

Because there is no live production traffic in this local environment, the drift log in MinIO (`production_log.parquet`) is persistent. To test the drift server's states:

* **To simulate Clean Traffic (drift resolves)**:
  ```bash
  cd drift
  python simulate_drift.py --scenario clean --no-append
  ```
  *(This will overwrite the production log with clean, non-shifted data. Restarting `drit_server.py` will reset drift back to normal).*

* **To simulate Drift Traffic**:
  ```bash
  cd drift
  python simulate_drift.py --scenario drift --no-append
  ```

---

## 🔮 Future Session Goals (Next Steps)

1. **Ingest Production Log in Retraining**
   * Currently, KFP trains on the static `churn_data.csv`. 
   * Update [pipeline.py](file://wsl.localhost/Ubuntu/home/crysis/project_1/pipeline.py) so the data generation component pulls the accumulated `production_log.parquet` from MinIO, merges it with the training set, and trains the model on the fresh combined data.
   
2. **Implement Staging Shadow Testing (Champion-Challenger Gate)**
   * Deploy the newly retrained candidate model to a shadow router or canary deployment first to receive 10% of traffic before fully promoting it.

3. **Custom Slack Formatting**
   * Enhance AlertManager to format Slack notifications with metrics showing the exact features that drifted.
