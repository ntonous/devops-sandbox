#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENVS_DIR="$ROOT_DIR/envs"

# Guard: never run against infrastructure containers
PROTECTED_CONTAINERS=("sandbox-nginx" "sandbox-daemon" "sandbox-api" "sandbox-prometheus" "sandbox-grafana")

is_protected() {
  local name="$1"
  for protected in "${PROTECTED_CONTAINERS[@]}"; do
    if [[ "$name" == "$protected" ]]; then
      return 0
    fi
  done
  return 1
}

# Parse flags
ENV_ID=""
MODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_ID="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

if [[ -z "$ENV_ID" || -z "$MODE" ]]; then
  echo "Usage: $0 --env <env-id> --mode <crash|pause|network|recover|stress>"
  exit 1
fi

STATE_FILE="$ENVS_DIR/$ENV_ID.json"
if [[ ! -f "$STATE_FILE" ]]; then
  echo "[-] No state file for $ENV_ID"
  exit 1
fi

CONTAINER=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('container',''))")
NETWORK=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('network',''))")

# Guard check
if is_protected "$CONTAINER"; then
  echo "[!] ABORT: Cannot simulate outage on protected container: $CONTAINER"
  exit 1
fi

echo "[+] Outage simulation: env=$ENV_ID, mode=$MODE, container=$CONTAINER"

update_status() {
  local new_status="$1"
  python3 - <<PYEOF
import json
f = "$STATE_FILE"
d = json.load(open(f))
d['status'] = '$new_status'
import tempfile, os
tmp = f + '.tmp'
json.dump(d, open(tmp, 'w'), indent=2)
os.replace(tmp, f)
PYEOF
}

case "$MODE" in
  crash)
    docker kill "$CONTAINER"
    update_status "crashed"
    echo "[!] Container killed. Health monitor will detect within 90s."
    ;;
  pause)
    docker pause "$CONTAINER"
    update_status "paused"
    echo "[!] Container paused. Use --mode recover to unpause."
    ;;
  network)
    docker network disconnect "$NETWORK" "$CONTAINER"
    update_status "network-isolated"
    echo "[!] Container disconnected from network $NETWORK."
    ;;
  recover)
    STATUS=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('status','unknown'))")
    case "$STATUS" in
      crashed)
        docker start "$CONTAINER"
        echo "[+] Container restarted"
        ;;
      paused)
        docker unpause "$CONTAINER"
        echo "[+] Container unpaused"
        ;;
      network-isolated)
        docker network connect "$NETWORK" "$CONTAINER"
        echo "[+] Container reconnected to network"
        ;;
      *)
        # Try all recovery actions
        docker start "$CONTAINER" 2>/dev/null || true
        docker unpause "$CONTAINER" 2>/dev/null || true
        docker network connect "$NETWORK" "$CONTAINER" 2>/dev/null || true
        echo "[+] Recovery attempted for status: $STATUS"
        ;;
    esac
    update_status "running"
    echo "[✓] Recovery complete"
    ;;
  stress)
    if docker exec "$CONTAINER" which stress-ng >/dev/null 2>&1; then
      docker exec -d "$CONTAINER" stress-ng --cpu 2 --timeout 60s
      echo "[!] CPU stress started for 60s inside container"
    else
      echo "[!] stress-ng not available in container. Simulating with yes loop..."
      docker exec -d "$CONTAINER" sh -c 'yes > /dev/null & yes > /dev/null & sleep 60; kill %1 %2 2>/dev/null'
      echo "[!] CPU stress started (60s duration)"
    fi
    update_status "stressed"
    ;;
  *)
    echo "Unknown mode: $MODE. Valid: crash|pause|network|recover|stress"
    exit 1
    ;;
esac

echo "[✓] Simulation complete"
