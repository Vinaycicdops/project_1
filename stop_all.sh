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

if [ ! -f "$PID_FILE" ]; then
  echo -e "${YELLOW}No .pids file found — nothing to stop (maybe nothing is running).${RESET}"
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
