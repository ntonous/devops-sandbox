#!/usr/bin/env python3
"""Demo sandbox app — serves as the target inside each environment."""

import os
import time
from flask import Flask, jsonify

app = Flask(__name__)
START_TIME = time.time()
ENV_ID = os.getenv("ENV_ID", "unknown")
ENV_NAME = os.getenv("ENV_NAME", "unknown")


@app.route("/")
def index():
    return jsonify({
        "message": f"Hello from sandbox environment!",
        "env_id": ENV_ID,
        "env_name": ENV_NAME,
        "uptime_seconds": round(time.time() - START_TIME, 2),
    })


@app.route("/health")
def health():
    return jsonify({
        "status": "ok",
        "env_id": ENV_ID,
        "uptime": round(time.time() - START_TIME, 2),
        "timestamp": int(time.time()),
    })


@app.route("/info")
def info():
    return jsonify({
        "env_id": ENV_ID,
        "env_name": ENV_NAME,
        "pid": os.getpid(),
        "uptime": round(time.time() - START_TIME, 2),
    })


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
