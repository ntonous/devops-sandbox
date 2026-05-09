#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENVS_DIR="$ROOT_DIR/envs"
LOGS_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOGS_DIR/cleanup.log"

mkdir -p "$LOGS_DIR"

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG_FILE"
}

log "Cleanup daemon started (PID: $$)"

while true; do
  NOW=$(date -u +%s)

  for STATE_FILE in "$ENVS_DIR"/*.json 2>/dev/null; do
    [[ -f "$STATE_FILE" ]] || continue

    ENV_ID=$(basename "$STATE_FILE" .json)
    EXPIRES_AT=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('expires_at', 0))" 2>/dev/null || echo 0)
    STATUS=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('status','unknown'))" 2>/dev/null || echo "unknown")

    if [[ "$EXPIRES_AT" -gt 0 ]] && [[ "$NOW" -gt "$EXPIRES_AT" ]]; then
      log "TTL expired for $ENV_ID (expired at $EXPIRES_AT, now $NOW) — destroying"
      bash "$SCRIPT_DIR/destroy_env.sh" "$ENV_ID" >> "$LOG_FILE" 2>&1 && \
        log "Successfully destroyed $ENV_ID" || \
        log "ERROR: Failed to destroy $ENV_ID"
    else
      REMAINING=$((EXPIRES_AT - NOW))
      log "Env $ENV_ID OK — status=$STATUS, expires in ${REMAINING}s"
    fi
  done

  sleep 60
done
