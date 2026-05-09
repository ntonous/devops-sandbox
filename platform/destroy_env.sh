#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENVS_DIR="$ROOT_DIR/envs"
NGINX_CONF_DIR="$ROOT_DIR/nginx/conf.d"
LOGS_DIR="$ROOT_DIR/logs"

source "$ROOT_DIR/.env" 2>/dev/null || true

ENV_ID="${1:-}"
if [[ -z "$ENV_ID" ]]; then
  echo "Usage: $0 <env-id>"
  exit 1
fi

STATE_FILE="$ENVS_DIR/$ENV_ID.json"
if [[ ! -f "$STATE_FILE" ]]; then
  echo "[-] No state file found for $ENV_ID"
  exit 1
fi

echo "[+] Destroying environment: $ENV_ID"

# Parse state file
CONTAINER=$(python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('container',''))")
NETWORK=$(python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('network',''))")
LOG_PID=$(python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('log_pid',''))")

# Kill log shipping process
if [[ -n "$LOG_PID" ]] && kill -0 "$LOG_PID" 2>/dev/null; then
  kill "$LOG_PID" 2>/dev/null || true
  echo "[+] Log shipping process killed (PID: $LOG_PID)"
fi

# Stop and remove all labeled containers
docker ps -aq --filter "label=sandbox.env=$ENV_ID" | xargs -r docker rm -f 2>/dev/null || true
echo "[+] Containers removed"

# Remove Docker network
if docker network inspect "$NETWORK" >/dev/null 2>&1; then
  docker network rm "$NETWORK" 2>/dev/null || true
  echo "[+] Network removed: $NETWORK"
fi

# Remove Nginx config and reload
NGINX_CONF="$NGINX_CONF_DIR/$ENV_ID.conf"
if [[ -f "$NGINX_CONF" ]]; then
  rm -f "$NGINX_CONF"
  docker exec sandbox-nginx nginx -s reload 2>/dev/null || true
  echo "[+] Nginx config removed and reloaded"
fi

# Archive logs
ARCHIVE_DIR="$LOGS_DIR/archived/$ENV_ID"
mkdir -p "$ARCHIVE_DIR"
if [[ -d "$LOGS_DIR/$ENV_ID" ]]; then
  cp -r "$LOGS_DIR/$ENV_ID/." "$ARCHIVE_DIR/"
  rm -rf "$LOGS_DIR/$ENV_ID"
  echo "[+] Logs archived to logs/archived/$ENV_ID/"
fi

# Delete state file
rm -f "$STATE_FILE"
echo "[+] State file deleted"

echo ""
echo "[✓] Environment $ENV_ID destroyed successfully"
