# DevOps Sandbox Platform

A self-service platform for spinning up isolated temporary environments, deploying apps, simulating outages, monitoring health, and auto-destroying everything. Think miniature internal Heroku with a chaos engineering toggle.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Linux VM / Host                           │
│                                                                  │
│  ┌──────────┐    ┌──────────────┐    ┌──────────────────────┐   │
│  │  Client  │───▶│    Nginx     │───▶│  Env Containers      │   │
│  │ (curl /  │    │  (port 80)   │    │  app-env-abc123      │   │
│  │  browser)│    │  reverse     │    │  app-env-def456      │   │
│  └──────────┘    │  proxy       │    │  app-env-ghi789      │   │
│                  │  per-env     │    └──────────────────────┘   │
│  ┌──────────┐    │  conf.d/     │                                │
│  │  API     │    └──────────────┘                                │
│  │ (port    │          │                                         │
│  │  5000)   │    ┌─────▼────────┐                               │
│  │ FastAPI  │    │  Docker      │    ┌──────────────────────┐   │
│  └────┬─────┘    │  Networks    │    │  Cleanup Daemon      │   │
│       │          │  net-env-*   │    │  (60s loop, nohup)   │   │
│       │          └──────────────┘    │  checks TTL expiry   │   │
│       │                              └──────────────────────┘   │
│       ▼                                                          │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                  platform/                               │    │
│  │  create_env.sh   destroy_env.sh   simulate_outage.sh    │    │
│  │  cleanup_daemon.sh                                       │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────┐   │
│  │  envs/       │    │  logs/       │    │  Health Monitor  │   │
│  │  *.json      │    │  <env-id>/   │    │  (30s poll loop) │   │
│  │  state files │    │  app.log     │    │  /health check   │   │
│  └──────────────┘    │  health.log  │    └──────────────────┘   │
│                      └──────────────┘                            │
└─────────────────────────────────────────────────────────────────┘
```

**Key design decisions:**
- Nginx runs as a Docker container on `sandbox-nginx-net`; each env container is also connected to this network so Nginx can reach it by name.
- Every env gets a dedicated Docker network (`net-env-<id>`) for isolation between envs.
- State is stored as JSON files in `envs/`; all scripts write atomically via temp-file + mv.
- The cleanup daemon runs with `nohup` outside Docker to avoid being affected by `docker compose down`.

---

## Prerequisites

- Linux VM (Ubuntu 20.04+ recommended)
- Docker Engine 24+
- Docker Compose v2 (`docker compose`)
- Python 3.10+
- `make`
- Ports 80 and 5000 available

```bash
# Install Docker (if needed)
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER && newgrp docker

# Install Python deps (for local script use)
pip3 install -r requirements.txt
```

---

## Quick Start (zero to first running env in 4 commands)

```bash
git clone https://github.com/ntonous/devops-sandbox.git
cd devops-sandbox
make build-demo          # Build the demo app image
make up                  # Start Nginx + API + monitor
make create              # Follow prompts: name=myapp, TTL=300
```

Your environment is live. Visit `http://localhost` with the `Host: env-<id>.localhost` header, or hit the API at `http://localhost:5000/envs`.

---

## Full Demo Walkthrough

### 1. Start the platform
```bash
make up
```

### 2. Create an environment
```bash
make create
# → name: demo-app
# → TTL: 300   (5 minutes)

# Or via API:
curl -s -X POST http://localhost:5000/envs \
  -H "Content-Type: application/json" \
  -d '{"name":"demo-app","ttl":300}' | python3 -m json.tool
```

Note the `id` in the output, e.g. `env-demo-app-123456`.

### 3. Check environment health
```bash
make health

# Or via API:
curl http://localhost:5000/envs/env-demo-app-123456/health
```

### 4. Simulate an outage
```bash
make simulate ENV=env-demo-app-123456 MODE=crash

# Observe health monitor detect failure within 90s:
tail -f logs/env-demo-app-123456/health.log
```

### 5. Recover
```bash
make simulate ENV=env-demo-app-123456 MODE=recover
```

### 6. Watch auto-destroy (when TTL expires)
```bash
tail -f logs/cleanup.log
# After TTL expires, cleanup daemon calls destroy_env.sh automatically
```

### 7. Manual destroy
```bash
make destroy ENV=env-demo-app-123456
```

---

## API Reference

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/envs` | Create environment (`{"name":"x","ttl":1800}`) |
| `GET` | `/envs` | List all active envs with TTL remaining |
| `DELETE` | `/envs/:id` | Destroy environment |
| `GET` | `/envs/:id/logs` | Last 100 lines of app.log (`?lines=N`) |
| `GET` | `/envs/:id/health` | Last 10 health check results |
| `POST` | `/envs/:id/outage` | Trigger simulation (`{"mode":"crash"}`) |
| `GET` | `/health` | API health check |

Interactive docs: `http://20.121.185.0:5000/docs`

---

## Makefile Targets

```
make up                      # Start Nginx + daemon + API
make down                    # Stop everything, destroy all envs
make create                  # Create new env (prompts for name + TTL)
make destroy ENV=…           # Destroy specific env
make logs ENV=…              # Tail env logs
make health                  # Show all env health statuses
make simulate ENV=… MODE=…   # Run outage simulation
make clean                   # Wipe all state, logs, archives
make build-demo              # Build demo app Docker image
```

---

## Outage Simulation Modes

| Mode | What it does | Recovery |
|------|-------------|---------|
| `crash` | `docker kill` the container | `MODE=recover` |
| `pause` | `docker pause` — freezes all processes | `MODE=recover` |
| `network` | Disconnects container from its network | `MODE=recover` |
| `recover` | Auto-detects and reverses any of the above | — |
| `stress` | Spikes CPU with stress-ng (60s) | Auto-expires |

> **Guard:** `simulate_outage.sh` refuses to run against `sandbox-nginx`, `sandbox-daemon`, `sandbox-api`, or any infrastructure container.

---

## Log Shipping

Uses **Approach A** (simple): `docker logs -f $CONTAINER_ID >> logs/$ENV_ID/app.log &`. The PID is stored in the state file and killed on `destroy_env.sh`. Logs are archived to `logs/archived/$ENV_ID/` on destroy.

Query logs:
```bash
make logs ENV=env-abc123
# Or:
curl http://localhost:5000/envs/env-abc123/logs
```

---

## Nginx Dynamic Routing

Each `create_env.sh` writes `nginx/conf.d/$ENV_ID.conf` with an upstream + server block routing `$ENV_ID.$HOST` to the container. Then runs `docker exec sandbox-nginx nginx -s reload`.

On destroy, the conf is deleted and Nginx reloaded again. The main `nginx.conf` uses `include /etc/nginx/conf.d/*.conf;`.

**Network approach:** All app containers are attached to both their dedicated isolation network (`net-env-<id>`) and the shared `sandbox-nginx-net`. Nginx resolves containers by Docker DNS name within that shared network.

---

## Known Limitations

- **Single-host only** — no multi-node or Swarm/Kubernetes support.
- **Port conflicts** — ports are randomly assigned from 8100–9000; unlikely but possible collision.
- **No authentication** — the API has no auth. Add an API key middleware before exposing publicly.
- **Log shipping PID** — if the host reboots, PIDs in state files become stale. The zombie check on destroy handles this gracefully but old logs may be lost.
- **Nginx DNS** — uses container names for upstream; requires all env containers to be on `sandbox-nginx-net`. If a container fails to join that network, Nginx routing breaks for that env.
- **No persistent volumes** — demo app is stateless. Add volume mounts to `create_env.sh` if needed.
- **Cleanup daemon is a shell loop** — adequate for this scale; for production, replace with a proper scheduler (systemd timer, Celery beat, etc).

---

## Repo Structure

```
devops-sandbox/
├── platform/
│   ├── create_env.sh
│   ├── destroy_env.sh
│   ├── cleanup_daemon.sh
│   ├── simulate_outage.sh
│   └── api.py
├── nginx/
│   ├── nginx.conf
│   └── conf.d/          # auto-generated per-env, gitignored
├── monitor/
│   └── health_monitor.py
├── demo-app/
│   ├── Dockerfile
│   └── app.py
├── logs/                # gitignored
├── envs/                # gitignored
├── docker-compose.yml
├── Dockerfile.api
├── Makefile
├── requirements.txt
├── .env.example
├── .gitignore
└── README.md
```
