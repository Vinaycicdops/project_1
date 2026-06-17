#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
#  cluster_setup.sh  —  ONE-TIME cluster bootstrap for the MLOps/AIOps platform
#
#  Prerequisites (already installed on your WSL env):
#    - minikube (started and running before calling this script)
#    - kubectl, helm, docker
#
#  Run this ONCE after a fresh minikube start or after wiping your cluster.
#  It is fully idempotent — safe to re-run if something fails midway.
#
#  Usage:
#    ./cluster_setup.sh
#
#  Steps performed:
#    1.  Verify minikube is running
#    2.  Install Kubeflow Pipelines (KFP 2.14.3)
#    3.  Patch MinIO image to stable version
#    4.  Patch workflow-controller (allow runAsRoot — needed for pipeline steps)
#    5.  Apply service account + S3 secret (infra/svcacc.yaml)
#    6.  Install kube-prometheus-stack via Helm
#    7.  Apply AlertManager config secret
#    8.  Seed MinIO with baseline training data
#    9.  Register the Kubeflow Pipeline definition
#    10. Train AIOps anomaly models (Isolation Forest + LSTM)
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[SETUP]${RESET} $*"; }
ok()   { echo -e "${GREEN}[  OK ]${RESET} $*"; }
warn() { echo -e "${YELLOW}[ WARN]${RESET} $*"; }
fail() { echo -e "${RED}[FAIL ]${RESET} $*"; exit 1; }

header() {
  echo ""
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${CYAN}  $*${RESET}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════${RESET}"
}

# ── config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_VERSION="2.14.3"
MINIO_IMAGE="minio/minio:RELEASE.2023-03-20T20-16-18Z"
VENV="$SCRIPT_DIR/.venv/bin/python"

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 1 — Verify Minikube is running"
# ─────────────────────────────────────────────────────────────────────────────
if ! minikube status | grep -q "Running"; then
  fail "Minikube is not running. Please run 'minikube start' first, then re-run this script."
fi
ok "Minikube is running"
kubectl cluster-info | head -2

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 2 — Install Kubeflow Pipelines v${PIPELINE_VERSION}"
# ─────────────────────────────────────────────────────────────────────────────
if kubectl get namespace kubeflow &>/dev/null; then
  ok "Namespace 'kubeflow' already exists — skipping KFP install"
else
  log "Applying cluster-scoped resources..."
  kubectl apply -k "github.com/kubeflow/pipelines/manifests/kustomize/cluster-scoped-resources?ref=${PIPELINE_VERSION}" || \
    fail "Failed to apply cluster-scoped resources"

  log "Waiting for CRDs to establish..."
  kubectl wait --for=condition=established --timeout=120s crd/applications.app.k8s.io || \
    warn "CRD wait timed out — continuing anyway"

  log "Applying platform-agnostic environment..."
  kubectl apply -k "github.com/kubeflow/pipelines/manifests/kustomize/env/platform-agnostic?ref=${PIPELINE_VERSION}" || \
    fail "Failed to apply platform-agnostic environment"

  ok "Kubeflow Pipelines manifests applied"
fi

log "Waiting for kubeflow pods to be ready (this can take 3-5 min)..."
kubectl wait --for=condition=Ready pod \
  -l app=ml-pipeline \
  -n kubeflow \
  --timeout=300s 2>/dev/null || warn "ml-pipeline pod not ready yet — continuing"

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 3 — Patch MinIO to stable image"
# ─────────────────────────────────────────────────────────────────────────────
CURRENT_MINIO=$(kubectl get deployment minio -n kubeflow \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")

if [ "$CURRENT_MINIO" = "$MINIO_IMAGE" ]; then
  ok "MinIO already pinned to stable image"
else
  log "Pinning MinIO to $MINIO_IMAGE..."
  kubectl set image deployment/minio minio="$MINIO_IMAGE" -n kubeflow
  kubectl rollout status deployment/minio -n kubeflow --timeout=120s
  ok "MinIO image updated"
fi

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 4 — Patch workflow-controller (allow runAsNonRoot: false)"
# ─────────────────────────────────────────────────────────────────────────────
log "Checking workflow-controller-configmap..."

CURRENT_PATCH=$(kubectl get configmap workflow-controller-configmap -n kubeflow \
  -o jsonpath='{.data.workflowDefaults}' 2>/dev/null || echo "")

if echo "$CURRENT_PATCH" | grep -q "runAsNonRoot: false"; then
  ok "workflow-controller already patched"
else
  log "Patching workflow-controller-configmap to allow root execution in pipeline steps..."
  kubectl patch configmap workflow-controller-configmap -n kubeflow --type=merge \
    -p '{
      "data": {
        "workflowDefaults": "spec:\n  securityContext:\n    runAsNonRoot: false\n"
      }
    }'

  log "Restarting workflow-controller to pick up new config..."
  kubectl rollout restart deployment workflow-controller -n kubeflow
  kubectl rollout status deployment workflow-controller -n kubeflow --timeout=120s

  log "Cleaning up any stale workflows..."
  kubectl delete workflow -n kubeflow --all 2>/dev/null || true
  ok "workflow-controller patched and restarted"
fi

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 5 — Apply Service Account + S3 Secret"
# ─────────────────────────────────────────────────────────────────────────────
log "Applying infra/svcacc.yaml..."
kubectl apply -f "$SCRIPT_DIR/infra/svcacc.yaml"
ok "Service account and S3 secret applied"

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 6 — Install kube-prometheus-stack via Helm"
# ─────────────────────────────────────────────────────────────────────────────
if kubectl get namespace monitoring &>/dev/null; then
  ok "Namespace 'monitoring' already exists — checking if Prometheus is installed..."
  if helm status monitoring -n monitoring &>/dev/null; then
    ok "Prometheus stack already installed — skipping"
  else
    warn "Namespace exists but Prometheus not installed — installing now..."
    helm install monitoring prometheus-community/kube-prometheus-stack \
      --namespace monitoring \
      -f "$SCRIPT_DIR/configs/monitoring-values.yml" \
      --timeout 10m
  fi
else
  log "Adding Prometheus Helm repo..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo update

  log "Creating monitoring namespace..."
  kubectl create namespace monitoring

  log "Installing kube-prometheus-stack (this can take 3-5 min)..."
  helm install monitoring prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    -f "$SCRIPT_DIR/configs/monitoring-values.yml" \
    --timeout 10m

  ok "Prometheus stack installed"
fi

log "Waiting for Prometheus pod..."
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=prometheus \
  -n monitoring \
  --timeout=180s 2>/dev/null || warn "Prometheus pod not ready yet — continuing"

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 7 — Apply AlertManager config"
# ─────────────────────────────────────────────────────────────────────────────
log "Applying alertmanager_config.yml..."
kubectl apply -f "$SCRIPT_DIR/alertmanager_config.yml"
ok "AlertManager config applied"

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 8 — Seed MinIO with baseline training data"
# ─────────────────────────────────────────────────────────────────────────────
log "Starting MinIO port-forward in background (9000:9000)..."
kubectl port-forward -n kubeflow svc/minio-service 9000:9000 &
MINIO_PF_PID=$!
sleep 4

cd "$SCRIPT_DIR"
log "Generating training data..."
"$VENV" training/generate_data.py || warn "generate_data.py failed — check output above"

log "Seeding MinIO bucket..."
"$VENV" seed_minio.py || warn "seed_minio.py failed — check output above"

ok "MinIO seeded"

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 9 — Register Kubeflow Pipeline"
# ─────────────────────────────────────────────────────────────────────────────
log "Starting KFP UI port-forward in background (8080:80)..."
kubectl port-forward -n kubeflow svc/ml-pipeline-ui 8080:80 &
KFP_PF_PID=$!
sleep 4

log "Submitting pipeline definition to Kubeflow..."
"$VENV" pipeline.py || warn "pipeline.py failed — check output above"
ok "Pipeline registered"

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 10 — Train AIOps Anomaly Models"
# ─────────────────────────────────────────────────────────────────────────────
log "Starting Prometheus port-forward in background (9090:9090)..."
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090 &
PROM_PF_PID=$!
sleep 4

log "Training Isolation Forest + LSTM models on Prometheus baseline..."
"$VENV" Ensemble_engine.py --mode train || warn "Training failed — check output above"
ok "AIOps models trained and saved to models/"

# ─────────────────────────────────────────────────────────────────────────────
header "CLEANUP — Killing setup port-forwards"
# ─────────────────────────────────────────────────────────────────────────────
kill $MINIO_PF_PID $KFP_PF_PID $PROM_PF_PID 2>/dev/null || true
ok "Setup port-forwards closed"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔═══════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║  ✅  CLUSTER SETUP COMPLETE                           ║${RESET}"
echo -e "${GREEN}${BOLD}║                                                       ║${RESET}"
echo -e "${GREEN}${BOLD}║  Next: run   ./start_all.sh   to launch the platform  ║${RESET}"
echo -e "${GREEN}${BOLD}╚═══════════════════════════════════════════════════════╝${RESET}"
echo ""
