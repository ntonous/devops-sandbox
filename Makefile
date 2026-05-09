.PHONY: up down create destroy logs health simulate clean build-demo help

SHELL := /bin/bash
ROOT_DIR := $(shell pwd)
API_PORT ?= 5000

help:
	@echo ""
	@echo "  DevOps Sandbox Platform"
	@echo "  ─────────────────────────────────────────"
	@echo "  make up                      Start Nginx + daemon + API"
	@echo "  make down                    Stop everything, destroy all envs"
	@echo "  make create                  Create new environment (prompts for name + TTL)"
	@echo "  make destroy ENV=<id>        Destroy specific environment"
	@echo "  make logs ENV=<id>           Tail environment logs"
	@echo "  make health                  Show all environment health statuses"
	@echo "  make simulate ENV=<id> MODE=<mode>  Run outage simulation"
	@echo "  make clean                   Wipe all state, logs, archives"
	@echo "  make build-demo              Build the demo app image"
	@echo ""

up:
	@echo "[+] Starting platform..."
	@cp -n .env.example .env 2>/dev/null || true
	@mkdir -p logs envs nginx/conf.d
	@docker compose up -d --build
	@echo "[+] Starting cleanup daemon in background..."
	@nohup bash platform/cleanup_daemon.sh > logs/cleanup.log 2>&1 & echo $$! > logs/daemon.pid
	@echo "[✓] Platform running!"
	@echo "    API: http://localhost:$(API_PORT)"
	@echo "    Nginx: http://localhost:$${NGINX_PORT:-80}"
	@echo "    Daemon PID: $$(cat logs/daemon.pid)"

down:
	@echo "[+] Stopping platform..."
	@if [ -f logs/daemon.pid ]; then \
		kill $$(cat logs/daemon.pid) 2>/dev/null || true; \
		rm -f logs/daemon.pid; \
		echo "[+] Daemon stopped"; \
	fi
	@for f in envs/*.json; do \
		[ -f "$$f" ] || continue; \
		id=$$(basename $$f .json); \
		echo "[+] Destroying $$id..."; \
		bash platform/destroy_env.sh "$$id" 2>/dev/null || true; \
	done
	@docker compose down
	@echo "[✓] Platform stopped"

create:
	@read -p "Environment name: " name; \
	read -p "TTL in seconds [1800]: " ttl; \
	ttl=$${ttl:-1800}; \
	bash platform/create_env.sh "$$name" "$$ttl"

destroy:
ifndef ENV
	$(error ENV is required. Usage: make destroy ENV=env-abc123)
endif
	@bash platform/destroy_env.sh $(ENV)

logs:
ifndef ENV
	$(error ENV is required. Usage: make logs ENV=env-abc123)
endif
	@LOG_FILE="logs/$(ENV)/app.log"; \
	if [ -f "$$LOG_FILE" ]; then \
		tail -f "$$LOG_FILE"; \
	elif [ -f "logs/archived/$(ENV)/app.log" ]; then \
		echo "[!] Environment destroyed — showing archived logs:"; \
		tail -100 "logs/archived/$(ENV)/app.log"; \
	else \
		echo "No logs found for $(ENV)"; \
	fi

health:
	@echo ""
	@echo "  Environment Health Status"
	@echo "  ─────────────────────────────────────────"
	@NOW=$$(date +%s); \
	COUNT=0; \
	for f in envs/*.json; do \
		[ -f "$$f" ] || continue; \
		COUNT=$$((COUNT+1)); \
		ID=$$(python3 -c "import json; d=json.load(open('$$f')); print(d.get('id','?'))"); \
		NAME=$$(python3 -c "import json; d=json.load(open('$$f')); print(d.get('name','?'))"); \
		STATUS=$$(python3 -c "import json; d=json.load(open('$$f')); print(d.get('status','?'))"); \
		EXPIRES=$$(python3 -c "import json; d=json.load(open('$$f')); print(d.get('expires_at',0))"); \
		REMAINING=$$((EXPIRES - NOW)); \
		echo "  $$ID | $$NAME | status=$$STATUS | TTL remaining=$${REMAINING}s"; \
		HEALTH_FILE="logs/$$ID/health.log"; \
		if [ -f "$$HEALTH_FILE" ]; then \
			LAST=$$(tail -1 "$$HEALTH_FILE"); \
			echo "    Last check: $$LAST"; \
		fi; \
	done; \
	if [ "$$COUNT" -eq 0 ]; then echo "  No active environments"; fi
	@echo ""

simulate:
ifndef ENV
	$(error ENV is required. Usage: make simulate ENV=env-abc123 MODE=crash)
endif
ifndef MODE
	$(error MODE is required. Usage: make simulate ENV=env-abc123 MODE=crash)
endif
	@bash platform/simulate_outage.sh --env $(ENV) --mode $(MODE)

build-demo:
	@echo "[+] Building demo app image..."
	@docker build -t sandbox-demo-app:latest demo-app/
	@echo "[✓] Demo image built: sandbox-demo-app:latest"

clean:
	@echo "[!] This will wipe all state, logs, and archives. Press Ctrl+C to cancel..."
	@sleep 3
	@rm -rf logs/* envs/* nginx/conf.d/*.conf
	@mkdir -p logs envs nginx/conf.d
	@echo "[✓] Cleaned"
