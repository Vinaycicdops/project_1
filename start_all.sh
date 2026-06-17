#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
#  start_all.sh  —  Launch the FULL MLOps/AIOps platform in ONE command
#
#  Starts all 6 services in the right order with health checks between each.
#  All logs are tailed live in this terminal. Press Ctrl+C to stop everything.
#
#  Services launched:
#    [1] kubectl port-forward → Prometheus     :9090
#    [2] kubectl port-forward → AlertManager   :9093
#    [3] kubectl port-forward → MinIO          :9000
#    [4] kubectl port-forward → KFP UI         :8080
#    [5] Ensemble_engine.py --mode run          :8000  (AIOps daemon)
#    [6] drift/drift_trigger.py                 :8766  (retrain webhook)
#    [7] drift/drit_server.py                   :8765  (drift exporter)
#
#  Usage:
#    ./start_all.sh
#
#  To stop everything cleanly:
#    ./stop_all.sh
#    — or just press Ctrl+C in this terminal
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; RESET='\033[0m'

# ── config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$SCRIPT_DIR/.venv/bin/python"
LOG_DIR="$SCRIPT_DIR/.logs"
PID_FILE="$SCRIPT_DIR/.pids"

mkdir -p "$LOG_DIR"
> "$PID_FILE"   # clear old PIDs

# ── helper functions ──────────────────────────────────────────────────────────
log()    { echo -e "${CYAN}$(date '+%H:%M:%S')${RESET} ${BOLD}[START_ALL]${RESET} $*"; }
ok()     { echo -e "${GREEN}$(date '+%H:%M:%S') [  UP  ]${RESET} $*"; }
warn()   { echo -e "${YELLOW}$(date '+%H:%M:%S') [ WARN ]${RESET} $*"; }
fail()   { echo -e "${RED}$(date '+%H:%M:%S') [ FAIL ]${RESET} $*"; }
banner() { echo -e "${BOLD}${BLUE}$*${RESET}"; }

# Save PID and label to file for stop_all.sh
save_pid() {
  local label="$1"
  local pid="$2"
  echo "$label:$pid" >> "$PID_FILE"
}

# Wait for a local TCP port to be listening, with timeout
wait_for_port() {
  local name="$1"
  local port="$2"
  local timeout="${3:-30}"
  local elapsed=0

  log "Waiting for $name on port $port..."
  while ! nc -z localhost "$port" 2>/dev/null; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [ $elapsed -ge $timeout ]; then
      warn "$name on :$port not ready after ${timeout}s — continuing anyway"
      return 1
    fi
  done
  ok "$name is UP on :$port"
  return 0
}

# Start a background process, log to file, save PID
start_bg() {
  local label="$1"
  local color="$2"
  local logfile="$LOG_DIR/${label}.log"
  shift 2

  log "Starting: ${BOLD}$label${RESET}"
  # shellcheck disable=SC2068
  $@ >> "$logfile" 2>&1 &
  local pid=$!
  save_pid "$label" "$pid"
  echo -e "  ${color}↳ PID $pid — logs: $logfile${RESET}"
}

# Start a process in a new WSL terminal window, log to file
start_window() {
  local label="$1"
  local cmd="$2"
  local logfile="$LOG_DIR/${label}.log"

  log "Starting in new WSL window: ${BOLD}$label${RESET}"
  # Run the command inside WSL in a new terminal window using cmd.exe /c start wsl.exe.
  # We redirect output to a log file and also display it in the terminal window using tee.
  # Capture the exit status of the first command in pipeline via PIPESTATUS.
  # If it failed (exit code != 0) and was not stopped by user (exit code != 130 or 143), wait for user keypress.
  local wsl_cmd="cd '$SCRIPT_DIR' && $cmd 2>&1 | tee '$logfile'; status=\${PIPESTATUS[0]}; [ \$status -eq 0 ] || [ \$status -eq 130 ] || [ \$status -eq 143 ] || { echo 'Process failed with exit code \$status'; read -p 'Press Enter to close...'; }"
  cmd.exe /c start wsl.exe -e bash -c "$wsl_cmd" 2>/dev/null
}

# ── cleanup on exit ───────────────────────────────────────────────────────────
cleanup() {
  echo ""
  echo -e "${YELLOW}${BOLD}Shutting down all services...${RESET}"

  # Terminate all WSL port-forwards
  log "Terminating all kubectl port-forward processes..."
  pkill -f "kubectl port-forward" 2>/dev/null || true

  if [ -f "$PID_FILE" ]; then
    while IFS=: read -r label pid; do
      if kill -0 "$pid" 2>/dev/null; then
        echo -e "  ${RED}↓ Stopping $label (PID $pid)${RESET}"
        kill "$pid" 2>/dev/null || true
      fi
    done < "$PID_FILE"
  fi

  rm -f "$PID_FILE"
  echo -e "${GREEN}All services stopped.${RESET}"
}
trap cleanup EXIT INT TERM

# ─────────────────────────────────────────────────────────────────────────────
echo ""
banner "╔════════════════════════════════════════════════════════════╗"
banner "║   🚀  MLOps / AIOps Platform — Starting All Services      ║"
banner "╚════════════════════════════════════════════════════════════╝"
echo ""

# ── Verify minikube is running ────────────────────────────────────────────────
if ! minikube status | grep -q "Running"; then
  log "Minikube is not running — starting it..."
  minikube start --driver=docker
  ok "Minikube started"
else
  ok "Minikube is running"
fi


check_namespace() {
  kubectl get namespace "$1" >/dev/null 2>&1
}

# Run cluster setup if any required namespace is missing
if ! check_namespace monitoring || ! check_namespace kubeflow; then
  log "Required namespaces ('monitoring' or 'kubeflow') not found."
  log "Running cluster setup script ($SCRIPT_DIR/cluster_setup.sh)..."
  if ! "$SCRIPT_DIR/cluster_setup.sh"; then
    fail "Cluster setup failed. Aborting start_all.sh."
    exit 1
  fi
else
  ok "Required namespaces exist"
fi


# ─────────────────────────────────────────────────────────────────────────────
banner "── [1/7] Prometheus port-forward → :9090"
# ─────────────────────────────────────────────────────────────────────────────
start_window "prometheus-pf" \
  "kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090"
wait_for_port "Prometheus" 9090 45

# ─────────────────────────────────────────────────────────────────────────────
banner "── [2/7] AlertManager port-forward → :9093"
# ─────────────────────────────────────────────────────────────────────────────
start_window "alertmanager-pf" \
  "kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-alertmanager 9093:9093"
wait_for_port "AlertManager" 9093 30

# ─────────────────────────────────────────────────────────────────────────────
banner "── [3/7] MinIO port-forward → :9000"
# ─────────────────────────────────────────────────────────────────────────────
start_window "minio-pf" \
  "kubectl port-forward -n kubeflow svc/minio-service 9000:9000"
wait_for_port "MinIO" 9000 30

# ─────────────────────────────────────────────────────────────────────────────
banner "── [4/7] Kubeflow UI port-forward → :8080"
# ─────────────────────────────────────────────────────────────────────────────
start_window "kfp-ui-pf" \
  "kubectl port-forward -n kubeflow svc/ml-pipeline-ui 8080:80"
wait_for_port "KFP UI" 8080 30

echo ""
log "All infrastructure tunnels are UP. Starting application services..."
echo ""

# ─────────────────────────────────────────────────────────────────────────────
banner "── [5/7] AIOps Ensemble daemon (Ensemble_engine.py --mode run) → :8000"
# ─────────────────────────────────────────────────────────────────────────────
cd "$SCRIPT_DIR"
start_bg "aiops-daemon" "$MAGENTA" \
  "$VENV" Ensemble_engine.py --mode run
wait_for_port "AIOps metrics exporter" 8000 60

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║   ✅  INFRASTRUCTURE & AIOPS ENGINE RUNNING               ║${RESET}"
echo -e "${GREEN}${BOLD}╠════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${GREEN}${BOLD}║  Prometheus      →  http://localhost:9090                 ║${RESET}"
echo -e "${GREEN}${BOLD}║  AlertManager    →  http://localhost:9093                 ║${RESET}"
echo -e "${GREEN}${BOLD}║  MinIO           →  http://localhost:9000                 ║${RESET}"
echo -e "${GREEN}${BOLD}║  Kubeflow UI     →  http://localhost:8080                 ║${RESET}"
echo -e "${GREEN}${BOLD}║  AIOps Metrics   →  http://localhost:8000/metrics         ║${RESET}"
echo -e "${GREEN}${BOLD}╠════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${GREEN}${BOLD}║  Logs →  .logs/   │  Press Ctrl+C to stop all            ║${RESET}"
echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════════════════════╝${RESET}"
echo ""

# ── Tail service logs to this terminal in colour ──────────────────────────────
log "Tailing service logs below (Ctrl+C to stop everything)..."
echo ""

tail -f \
  "$LOG_DIR/prometheus-pf.log" \
  "$LOG_DIR/alertmanager-pf.log" \
  "$LOG_DIR/minio-pf.log" \
  "$LOG_DIR/kfp-ui-pf.log" \
  "$LOG_DIR/aiops-daemon.log" &

TAIL_PID=$!
save_pid "log-tail" "$TAIL_PID"

# Keep the script alive until Ctrl+C
wait
