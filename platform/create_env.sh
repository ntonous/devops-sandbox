#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENVS_DIR="$ROOT_DIR/envs"
NGINX_CONF_DIR="$ROOT_DIR/nginx/conf.d"
LOGS_DIR="$ROOT_DIR/logs"

source "$ROOT_DIR/.env" 2>/dev/null || true

ENV_NAME="${1:-}"
TTL="${2:-1800}"  # default 30 min

if [[ -z "$ENV_NAME" ]]; then
  echo "Usage: $0 <name> [ttl_seconds]"
  exit 1
fi

# Generate unique env ID
ENV_ID="env-$(echo "$ENV_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-*$//')-$(date +%s | tail -c 6)"
NETWORK_NAME="net-$ENV_ID"
CONTAINER_NAME="app-$ENV_ID"
PORT=$(shuf -i 8100-9000 -n 1)
CREATED_AT=$(date -u +%s)
NGINX_PORT="${NGINX_PORT:-80}"
HOST="${PLATFORM_HOST:-localhost}"

echo "[+] Creating environment: $ENV_NAME (ID: $ENV_ID, TTL: ${TTL}s)"

# Create Docker network
docker network create "$NETWORK_NAME" >/dev/null
echo "[+] Network created: $NETWORK_NAME"

# Create log directory
mkdir -p "$LOGS_DIR/$ENV_ID"

# Start the demo app container
docker run -d \
  --name "$CONTAINER_NAME" \
  --network "$NETWORK_NAME" \
  --label "sandbox.env=$ENV_ID" \
  --label "sandbox.name=$ENV_NAME" \
  -p "$PORT:8080" \
  -e ENV_ID="$ENV_ID" \
  -e ENV_NAME="$ENV_NAME" \
  "sandbox-demo-app:latest" >/dev/null 2>&1 || \
docker run -d \
  --name "$CONTAINER_NAME" \
  --network "$NETWORK_NAME" \
  --label "sandbox.env=$ENV_ID" \
  --label "sandbox.name=$ENV_NAME" \
  -p "$PORT:80" \
  -e ENV_ID="$ENV_ID" \
  -e ENV_NAME="$ENV_NAME" \
  "nginx:alpine" >/dev/null

# Connect to nginx network
docker network connect sandbox-nginx-net "$CONTAINER_NAME" 2>/dev/null || true

echo "[+] Container started: $CONTAINER_NAME on port $PORT"

# Write Nginx config
cat > "$NGINX_CONF_DIR/$ENV_ID.conf" <<EOF
upstream $ENV_ID {
    server $CONTAINER_NAME:80;
}

server {
    listen 80;
    server_name $ENV_ID.$HOST;

    location / {
        proxy_pass http://$ENV_ID;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Env-ID $ENV_ID;
    }

    location /health {
        proxy_pass http://$ENV_ID/health;
        proxy_set_header Host \$host;
    }
}
EOF

# Reload Nginx
docker exec sandbox-nginx nginx -s reload 2>/dev/null || true
echo "[+] Nginx configured and reloaded"

# Start log shipping (Approach A)
docker logs -f "$CONTAINER_NAME" >> "$LOGS_DIR/$ENV_ID/app.log" 2>&1 &
LOG_PID=$!
echo "[+] Log shipping started (PID: $LOG_PID)"

# Write state file atomically
EXPIRES_AT=$((CREATED_AT + TTL))
TEMP_STATE=$(mktemp)
cat > "$TEMP_STATE" <<EOF
{
  "id": "$ENV_ID",
  "name": "$ENV_NAME",
  "container": "$CONTAINER_NAME",
  "network": "$NETWORK_NAME",
  "port": $PORT,
  "created_at": $CREATED_AT,
  "ttl": $TTL,
  "expires_at": $EXPIRES_AT,
  "log_pid": $LOG_PID,
  "status": "running"
}
EOF
mv "$TEMP_STATE" "$ENVS_DIR/$ENV_ID.json"
echo "[+] State file written: envs/$ENV_ID.json"

ENV_URL="http://$HOST:$NGINX_PORT ($ENV_ID.$HOST)"
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  Environment Ready!                      ║"
echo "╠══════════════════════════════════════════╣"
echo "║  ID:      $ENV_ID"
echo "║  Name:    $ENV_NAME"
echo "║  URL:     $ENV_URL"
echo "║  Port:    $PORT"
echo "║  TTL:     ${TTL}s (expires $(date -d "@$EXPIRES_AT" '+%H:%M:%S' 2>/dev/null || date -r "$EXPIRES_AT" '+%H:%M:%S' 2>/dev/null || echo "in ${TTL}s"))"
echo "╚══════════════════════════════════════════╝"
