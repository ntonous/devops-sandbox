#!/usr/bin/env python3
"""DevOps Sandbox Platform — Control API"""

import json
import os
import subprocess
import time
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException, Body
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

ROOT_DIR = Path(__file__).parent.parent
ENVS_DIR = ROOT_DIR / "envs"
LOGS_DIR = ROOT_DIR / "logs"
PLATFORM_DIR = ROOT_DIR / "platform"

app = FastAPI(title="DevOps Sandbox API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


class CreateEnvRequest(BaseModel):
    name: str
    ttl: Optional[int] = 1800


class OutageRequest(BaseModel):
    mode: str  # crash | pause | network | recover | stress


def load_state(env_id: str) -> dict:
    state_file = ENVS_DIR / f"{env_id}.json"
    if not state_file.exists():
        raise HTTPException(status_code=404, detail=f"Environment {env_id} not found")
    with open(state_file) as f:
        return json.load(f)


def list_envs() -> list[dict]:
    envs = []
    now = int(time.time())
    for f in ENVS_DIR.glob("*.json"):
        try:
            with open(f) as fp:
                data = json.load(fp)
            data["ttl_remaining"] = max(0, data.get("expires_at", 0) - now)
            envs.append(data)
        except Exception:
            pass
    return envs


def run_script(script: str, *args) -> tuple[int, str, str]:
    script_path = PLATFORM_DIR / script
    result = subprocess.run(
        ["bash", str(script_path), *args],
        capture_output=True,
        text=True,
        timeout=60,
    )
    return result.returncode, result.stdout, result.stderr


@app.post("/envs", status_code=201)
def create_env(req: CreateEnvRequest):
    """Create a new sandbox environment."""
    code, stdout, stderr = run_script("create_env.sh", req.name, str(req.ttl))
    if code != 0:
        raise HTTPException(status_code=500, detail=stderr or stdout)

    # Find the newly created env
    envs = list_envs()
    for env in sorted(envs, key=lambda e: e.get("created_at", 0), reverse=True):
        if env.get("name") == req.name:
            return {"env": env, "output": stdout}

    return {"output": stdout}


@app.get("/envs")
def get_envs():
    """List all active environments with TTL remaining."""
    return {"envs": list_envs(), "count": len(list_envs())}


@app.delete("/envs/{env_id}")
def delete_env(env_id: str):
    """Destroy a specific environment."""
    load_state(env_id)  # Validate exists
    code, stdout, stderr = run_script("destroy_env.sh", env_id)
    if code != 0:
        raise HTTPException(status_code=500, detail=stderr or stdout)
    return {"message": f"Environment {env_id} destroyed", "output": stdout}


@app.get("/envs/{env_id}/logs")
def get_logs(env_id: str, lines: int = 100):
    """Get last N lines of app.log for an environment."""
    load_state(env_id)  # Validate exists

    log_file = LOGS_DIR / env_id / "app.log"
    archived_log = LOGS_DIR / "archived" / env_id / "app.log"

    target = log_file if log_file.exists() else archived_log
    if not target.exists():
        return {"env_id": env_id, "logs": [], "message": "No logs yet"}

    result = subprocess.run(
        ["tail", f"-{lines}", str(target)], capture_output=True, text=True
    )
    log_lines = result.stdout.splitlines()
    return {"env_id": env_id, "lines": len(log_lines), "logs": log_lines}


@app.get("/envs/{env_id}/health")
def get_health(env_id: str, results: int = 10):
    """Get last N health check results for an environment."""
    load_state(env_id)  # Validate exists

    health_file = LOGS_DIR / env_id / "health.log"
    if not health_file.exists():
        return {"env_id": env_id, "health": [], "message": "No health data yet"}

    with open(health_file) as f:
        lines = f.readlines()

    entries = []
    for line in lines[-results:]:
        try:
            entries.append(json.loads(line.strip()))
        except Exception:
            entries.append({"raw": line.strip()})

    return {"env_id": env_id, "results": len(entries), "health": entries}


@app.post("/envs/{env_id}/outage")
def trigger_outage(env_id: str, req: OutageRequest = Body(...)):
    """Trigger an outage simulation."""
    load_state(env_id)  # Validate exists

    valid_modes = {"crash", "pause", "network", "recover", "stress"}
    if req.mode not in valid_modes:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid mode '{req.mode}'. Valid: {', '.join(valid_modes)}",
        )

    code, stdout, stderr = run_script(
        "simulate_outage.sh", "--env", env_id, "--mode", req.mode
    )
    if code != 0:
        raise HTTPException(status_code=500, detail=stderr or stdout)

    return {"env_id": env_id, "mode": req.mode, "output": stdout}


@app.get("/health")
def api_health():
    """API health check."""
    return {"status": "ok", "envs": len(list_envs()), "timestamp": int(time.time())}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("API_PORT", "5000")))
