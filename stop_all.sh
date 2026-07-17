#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
#  stop_all.sh  —  Cleanly kill everything started by start_all.sh
#
#  Usage:
#    ./stop_all.sh
# ═══════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/.pids"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'; BOLD='\033[1m'

echo -e "${YELLOW}${BOLD}Stopping all MLOps/AIOps services...${RESET}"

# Terminate all WSL port-forwards
echo -e "  ${RED}↓ Stopping all kubectl port-forwards${RESET}"
pkill -f "kubectl port-forward" 2>/dev/null || true

# Clean up completed workflows and pods in kubeflow namespace
echo -e "  ${RED}↓ Cleaning up completed workflows and pods in kubeflow namespace${RESET}"
kubectl delete workflow -n kubeflow --all 2>/dev/null || true


# Terminate any running AIOps Ensemble engines
echo -e "  ${RED}↓ Stopping all AIOps Ensemble engines${RESET}"
pkill -f "Ensemble_engine.py" 2>/dev/null || true

if [ ! -f "$PID_FILE" ]; then
  echo -e "${YELLOW}No .pids file found — nothing else to stop.${RESET}"
  exit 0
fi

while IFS=: read -r label pid; do
  if kill -0 "$pid" 2>/dev/null; then
    echo -e "  ${RED}↓ Stopping $label (PID $pid)${RESET}"
    kill "$pid" 2>/dev/null || true
    # Give it a moment, then force-kill if needed
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  else
    echo -e "  ${GREEN}✓ $label (PID $pid) already stopped${RESET}"
  fi
done < "$PID_FILE"

rm -f "$PID_FILE"

echo ""
echo -e "${GREEN}${BOLD}All services stopped.${RESET}"
echo ""
echo "To start again: ./start_all.sh"
echo "To wipe and restart cluster: ./cluster_setup.sh"
