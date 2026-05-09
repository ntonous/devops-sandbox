#!/usr/bin/env python3
"""Health Monitor — polls each active env's /health endpoint every 30s."""

import json
import os
import sys
import time
from pathlib import Path
import urllib.request
import urllib.error

ROOT_DIR = Path(__file__).parent.parent
ENVS_DIR = ROOT_DIR / "envs"
LOGS_DIR = ROOT_DIR / "logs"

POLL_INTERVAL = 30
FAILURE_THRESHOLD = 3

# Track consecutive failures per env
failure_counts: dict[str, int] = {}


def poll_health(env_id: str, state: dict) -> dict:
    port = state.get("port")
    url = f"http://localhost:{port}/health"
    start = time.time()
    result = {
        "timestamp": int(start),
        "env_id": env_id,
        "url": url,
        "status": None,
        "latency_ms": None,
        "error": None,
    }

    try:
        req = urllib.request.urlopen(url, timeout=5)
        latency = (time.time() - start) * 1000
        result["status"] = req.getcode()
        result["latency_ms"] = round(latency, 2)
    except urllib.error.HTTPError as e:
        result["status"] = e.code
        result["latency_ms"] = round((time.time() - start) * 1000, 2)
    except Exception as e:
        result["error"] = str(e)
        result["status"] = 0

    return result


def write_health_log(env_id: str, result: dict):
    log_dir = LOGS_DIR / env_id
    log_dir.mkdir(parents=True, exist_ok=True)
    health_file = log_dir / "health.log"
    with open(health_file, "a") as f:
        f.write(json.dumps(result) + "\n")


def update_env_status(env_id: str, status: str):
    state_file = ENVS_DIR / f"{env_id}.json"
    if not state_file.exists():
        return
    try:
        with open(state_file) as f:
            data = json.load(f)
        data["status"] = status
        tmp = str(state_file) + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, str(state_file))
    except Exception as e:
        print(f"[!] Failed to update status for {env_id}: {e}")


def log(msg: str):
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(f"[{ts}] {msg}", flush=True)


def main():
    log("Health monitor started")
    while True:
        env_files = list(ENVS_DIR.glob("*.json"))
        if not env_files:
            log("No active environments to monitor")
        else:
            for state_file in env_files:
                env_id = state_file.stem
                try:
                    with open(state_file) as f:
                        state = json.load(f)
                except Exception:
                    continue

                result = poll_health(env_id, state)
                write_health_log(env_id, result)

                is_healthy = result["status"] and 200 <= result["status"] < 400

                if is_healthy:
                    failure_counts[env_id] = 0
                    log(f"[OK] {env_id} — HTTP {result['status']} in {result['latency_ms']}ms")
                else:
                    failure_counts[env_id] = failure_counts.get(env_id, 0) + 1
                    count = failure_counts[env_id]
                    log(f"[FAIL] {env_id} — {result.get('error') or result['status']} (failure {count}/{FAILURE_THRESHOLD})")

                    if count >= FAILURE_THRESHOLD:
                        log(f"[!] WARNING: {env_id} has failed {count} consecutive health checks — marking DEGRADED")
                        update_env_status(env_id, "degraded")

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
